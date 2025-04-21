{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Server where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import qualified Data.IntSet as IS
import Data.List (intercalate, partition, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.IORef (atomicSwapIORef)
import GHC.Stats (getRTSStats)
import Network.Socket (ServiceName, Socket, socketToHandle)
import Simplex.Messaging.Client (ProtocolClientError (..), SMPClientError, ServerTransmission (..))
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Control
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS (PushNotification (..), PushProviderError (..))
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store (NtfSTMStore, TokenNtfMessageRecord (..), stmStoreTokenLastNtf)
import Simplex.Messaging.Notifications.Server.Store.Postgres
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (EntityId (..), ErrorType (..), ProtocolServer (host), SMPServer, SignedTransmission, Transmission, pattern NoEntity, pattern SMPServer, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Control (CPClientRole (..))
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.QueueStore (getSystemDate)
import Simplex.Messaging.Server.Stats (PeriodStats (..), PeriodStatCounts (..), periodStatCounts, updatePeriodStats)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), THandleAuth (..), THandleParams (..), TProxy, Transport (..), TransportPeer (..), defaultSupportedParams)
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server (AddHTTP, runTransportServer, runLocalTCPServer)
import Simplex.Messaging.Util
import System.Exit (exitFailure, exitSuccess)
import System.IO (BufferMode (..), hClose, hPrint, hPutStrLn, hSetBuffering, hSetNewlineMode, universalNewlineMode)
import System.Mem.Weak (deRefWeak)
import UnliftIO (IOMode (..), UnliftIO, askUnliftIO, async, uninterruptibleCancel, unliftIO, withFile)
import UnliftIO.Concurrent (forkIO, killThread, mkWeakThreadId)
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.STM
#if MIN_VERSION_base(4,18,0)
import GHC.Conc (listThreads)
#endif

import qualified Data.ByteString.Base64 as B64

runNtfServer :: NtfServerConfig -> IO ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: TMVar Bool -> NtfServerConfig -> IO ()
runNtfServerBlocking started cfg = runReaderT (ntfServer cfg started) =<< newNtfServerEnv cfg

type M a = ReaderT NtfEnv IO a

ntfServer :: NtfServerConfig -> TMVar Bool -> M ()
ntfServer cfg@NtfServerConfig {transports, transportConfig = tCfg, startOptions} started = do
  restoreServerStats
  s <- asks subscriber
  ps <- asks pushServer
  when (maintenance startOptions) $ do
    liftIO $ putStrLn "Server started in 'maintenance' mode, exiting"
    stopServer
    liftIO $ exitSuccess
  resubscribe s
  raceAny_ (ntfSubscriber s : ntfPush ps : map runServer transports <> serverStatsThread_ cfg <> controlPortThread_ cfg) `finally` stopServer
  where
    runServer :: (ServiceName, ATransport, AddHTTP) -> M ()
    runServer (tcpPort, ATransport t, _addHTTP) = do
      srvCreds <- asks tlsServerCreds
      serverSignKey <- either fail pure $ fromTLSCredentials srvCreds
      env <- ask
      liftIO $ runTransportServer started tcpPort defaultSupportedParams srvCreds (Just supportedNTFHandshakes) tCfg $ \h -> runClient serverSignKey t h `runReaderT` env
    fromTLSCredentials (_, pk) = C.x509ToPrivate (pk, []) >>= C.privKey

    runClient :: Transport c => C.APrivateSignKey -> TProxy c -> c -> M ()
    runClient signKey _ h = do
      kh <- asks serverIdentity
      ks <- atomically . C.generateKeyPair =<< asks random
      NtfServerConfig {ntfServerVRange} <- asks config
      liftIO (runExceptT $ ntfServerHandshake signKey h ks kh ntfServerVRange) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

    stopServer :: M ()
    stopServer = do
      logInfo "Saving server state..."
      saveServer
      NtfSubscriber {smpSubscribers, smpAgent} <- asks subscriber
      liftIO $ readTVarIO smpSubscribers >>= mapM_ (\SMPSubscriber {subThreadId} -> readTVarIO subThreadId >>= mapM_ (deRefWeak >=> mapM_ killThread))
      liftIO $ closeSMPClientAgent smpAgent
      logInfo "Server stopped"

    saveServer :: M ()
    saveServer = asks store >>= liftIO . closeNtfDbStore >> saveServerStats

    serverStatsThread_ :: NtfServerConfig -> [M ()]
    serverStatsThread_ NtfServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      logInfo $ "server stats log enabled: " <> T.pack statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, tknReplaced, subCreated, subDeleted, ntfReceived, ntfDelivered, ntfFailed, ntfCronDelivered, ntfCronFailed, ntfVrfQueued, ntfVrfDelivered, ntfVrfFailed, ntfVrfInvalidTkn, activeTokens, activeSubs} <-
        asks serverStats
      let interval = 1000000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomicSwapIORef fromTime ts
          tknCreated' <- atomicSwapIORef tknCreated 0
          tknVerified' <- atomicSwapIORef tknVerified 0
          tknDeleted' <- atomicSwapIORef tknDeleted 0
          tknReplaced' <- atomicSwapIORef tknReplaced 0
          subCreated' <- atomicSwapIORef subCreated 0
          subDeleted' <- atomicSwapIORef subDeleted 0
          ntfReceived' <- atomicSwapIORef ntfReceived 0
          ntfDelivered' <- atomicSwapIORef ntfDelivered 0
          ntfFailed' <- atomicSwapIORef ntfFailed 0
          ntfCronDelivered' <- atomicSwapIORef ntfCronDelivered 0
          ntfCronFailed' <- atomicSwapIORef ntfCronFailed 0
          ntfVrfQueued' <- atomicSwapIORef ntfVrfQueued 0
          ntfVrfDelivered' <- atomicSwapIORef ntfVrfDelivered 0
          ntfVrfFailed' <- atomicSwapIORef ntfVrfFailed 0
          ntfVrfInvalidTkn' <- atomicSwapIORef ntfVrfInvalidTkn 0
          tkn <- liftIO $ periodStatCounts activeTokens ts
          sub <- liftIO $ periodStatCounts activeSubs ts
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show tknCreated',
                show tknVerified',
                show tknDeleted',
                show subCreated',
                show subDeleted',
                show ntfReceived',
                show ntfDelivered',
                dayCount tkn,
                weekCount tkn,
                monthCount tkn,
                dayCount sub,
                weekCount sub,
                monthCount sub,
                show tknReplaced',
                show ntfFailed',
                show ntfCronDelivered',
                show ntfCronFailed',
                show ntfVrfQueued',
                show ntfVrfDelivered',
                show ntfVrfFailed',
                show ntfVrfInvalidTkn'
              ]
        liftIO $ threadDelay' interval

    controlPortThread_ :: NtfServerConfig -> [M ()]
    controlPortThread_ NtfServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M ()
    runCPServer port = do
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runLocalTCPServer cpStarted port $ runCPClient u
      where
        runCPClient :: UnliftIO (ReaderT NtfEnv IO) -> Socket -> IO ()
        runCPClient u sock = do
          labelMyThread "control port client"
          h <- socketToHandle sock ReadWriteMode
          hSetBuffering h LineBuffering
          hSetNewlineMode h universalNewlineMode
          hPutStrLn h "Ntf server control port\n'help' for supported commands"
          role <- newTVarIO CPRNone
          cpLoop h role
          where
            cpLoop h role = do
              s <- trimCR <$> B.hGetLine h
              case strDecode s of
                Right CPQuit -> hClose h
                Right cmd -> logCmd s cmd >> processCP h role cmd >> cpLoop h role
                Left err -> hPutStrLn h ("error: " <> err) >> cpLoop h role
            logCmd s cmd = when shouldLog $ logWarn $ "ControlPort: " <> tshow s
              where
                shouldLog = case cmd of
                  CPAuth _ -> False
                  CPHelp -> False
                  CPQuit -> False
                  CPSkip -> False
                  _ -> True
            processCP h role = \case
              CPAuth auth -> atomically $ writeTVar role $! newRole cfg
                where
                  newRole NtfServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin}
                    | Just auth == admin = CPRAdmin
                    | Just auth == user = CPRUser
                    | otherwise = CPRNone
              CPStats -> withUserRole $ do
                ss <- unliftIO u $ asks serverStats
                let getStat :: (NtfServerStats -> IORef a) -> IO a
                    getStat var = readIORef (var ss)
                    putStat :: Show a => String -> (NtfServerStats -> IORef a) -> IO ()
                    putStat label var = getStat var >>= \v -> hPutStrLn h $ label <> ": " <> show v
                putStat "fromTime" fromTime
                putStat "tknCreated" tknCreated
                putStat "tknVerified" tknVerified
                putStat "tknDeleted" tknDeleted
                putStat "tknReplaced" tknReplaced
                putStat "subCreated" subCreated
                putStat "subDeleted" subDeleted
                putStat "ntfReceived" ntfReceived
                putStat "ntfDelivered" ntfDelivered
                putStat "ntfFailed" ntfFailed
                putStat "ntfCronDelivered" ntfCronDelivered
                putStat "ntfCronFailed" ntfCronFailed
                putStat "ntfVrfQueued" ntfVrfQueued
                putStat "ntfVrfDelivered" ntfVrfDelivered
                putStat "ntfVrfFailed" ntfVrfFailed
                putStat "ntfVrfInvalidTkn" ntfVrfInvalidTkn
                getStat (day . activeTokens) >>= \v -> hPutStrLn h $ "daily active tokens: " <> show (IS.size v)
                getStat (day . activeSubs) >>= \v -> hPutStrLn h $ "daily active subscriptions: " <> show (IS.size v)
              CPStatsRTS -> tryAny getRTSStats >>= either (hPrint h) (hPrint h)
              CPServerInfo -> readTVarIO role >>= \case
                CPRNone -> do
                  logError "Unauthorized control port command"
                  hPutStrLn h "AUTH"
                r -> do
#if MIN_VERSION_base(4,18,0)
                  threads <- liftIO listThreads
                  hPutStrLn h $ "Threads: " <> show (length threads)
#else
                  hPutStrLn h "Threads: not available on GHC 8.10"
#endif
                  NtfEnv {subscriber, pushServer} <-  unliftIO u ask
                  let NtfSubscriber {smpSubscribers, smpAgent = a} = subscriber
                      NtfPushServer {pushQ} = pushServer
                      SMPClientAgent {smpClients, smpSessions, srvSubs, pendingSrvSubs, smpSubWorkers} = a
                  putSMPWorkers a "SMP subcscribers" smpSubscribers
                  putSMPWorkers a "SMP clients" smpClients
                  putSMPWorkers a "SMP subscription workers" smpSubWorkers
                  sessions <- readTVarIO smpSessions
                  hPutStrLn h $ "SMP sessions count: " <> show (M.size sessions)
                  putSMPSubs a "SMP subscriptions" srvSubs
                  putSMPSubs a "Pending SMP subscriptions" pendingSrvSubs
                  sz <- atomically $ lengthTBQueue pushQ
                  hPutStrLn h $ "Push notifications queue length: " <> show sz
                  where
                    putSMPSubs :: SMPClientAgent -> String -> TMap SMPServer (TMap SMPSub a) -> IO ()
                    putSMPSubs a name v = do
                      subs <- readTVarIO v
                      (totalCnt, ownCount, otherCnt, servers, ownByServer) <- foldM countSubs (0, 0, 0, [], M.empty) $ M.assocs subs
                      showServers a name servers
                      hPutStrLn h $ name <> " total: " <> show totalCnt
                      hPutStrLn h $ name <> " on own servers: " <> show ownCount
                      when (r == CPRAdmin && not (null ownByServer)) $
                        forM_ (M.assocs ownByServer) $ \(SMPServer (host :| _) _ _, cnt) ->
                          hPutStrLn h $ name <> " on " <> B.unpack (strEncode host) <> ": " <> show cnt
                      hPutStrLn h $ name <> " on other servers: " <> show otherCnt
                      where
                        countSubs :: (Int, Int, Int, [SMPServer], M.Map SMPServer Int) -> (SMPServer, TMap SMPSub a) -> IO (Int, Int, Int, [SMPServer], M.Map SMPServer Int)
                        countSubs (!totalCnt, !ownCount, !otherCnt, !servers, !ownByServer) (srv, srvSubs) = do
                          cnt <- M.size <$> readTVarIO srvSubs
                          let totalCnt' = totalCnt + cnt
                              ownServer = isOwnServer a srv
                              (ownCount', otherCnt')
                                | ownServer = (ownCount + cnt, otherCnt)
                                | otherwise = (ownCount, otherCnt + cnt)
                              servers' = if cnt > 0 then srv : servers else servers
                              ownByServer'
                                | r == CPRAdmin && ownServer && cnt > 0 = M.alter (Just . maybe cnt (+ cnt)) srv ownByServer
                                | otherwise = ownByServer
                          pure (totalCnt', ownCount', otherCnt', servers', ownByServer')
                    putSMPWorkers :: SMPClientAgent -> String -> TMap SMPServer a -> IO ()
                    putSMPWorkers a name v = readTVarIO v >>= showServers a name . M.keys
                    showServers :: SMPClientAgent -> String -> [SMPServer] -> IO ()
                    showServers a name srvs = do
                      let (ownSrvs, otherSrvs) = partition (isOwnServer a) srvs
                      hPutStrLn h $ name <> " own servers count: " <> show (length ownSrvs)
                      when (r == CPRAdmin) $ hPutStrLn h $ name <> " own servers: " <> intercalate "," (sort $ map (\(SMPServer (host :| _) _ _) -> B.unpack $ strEncode host) ownSrvs)
                      hPutStrLn h $ name <> " other servers count: " <> show (length otherSrvs)
              CPHelp -> hPutStrLn h "commands: stats, stats-rts, server-info, help, quit"
              CPQuit -> pure ()
              CPSkip -> pure ()
              where
                withUserRole action =
                  readTVarIO role >>= \case
                    CPRAdmin -> action
                    CPRUser -> action
                    _ -> do
                      logError "Unauthorized control port command"
                      hPutStrLn h "AUTH"

resubscribe :: NtfSubscriber -> M ()
resubscribe NtfSubscriber {newSubQ} = do
  logInfo "Preparing SMP resubscriptions..."
  st <- asks store
  batchSize <- asks $ subsBatchSize . config
  liftIO $ do
    srvs <- getUsedSMPServers st
    count <- foldM (subscribeSrvSubs st batchSize) (0 :: Int) srvs
    logInfo $ "SMP resubscriptions queued (" <> tshow count <> " subscriptions)"
  where
    subscribeSrvSubs st batchSize !count srv = do
      (n, subs_) <-
        foldNtfSubscriptions st srv batchSize (0, []) $ \(!i, subs) sub ->
          if length subs == batchSize
            then write (L.fromList subs) $> (i + 1, [])
            else pure (i + 1, sub : subs)
      mapM_ write $ L.nonEmpty subs_
      pure $ count + n
      where
        write subs = atomically $ writeTBQueue newSubQ (srv, subs)

ntfSubscriber :: NtfSubscriber -> M ()
ntfSubscriber NtfSubscriber {smpSubscribers, newSubQ, smpAgent = ca@SMPClientAgent {msgQ, agentQ}} = do
  raceAny_ [subscribe, receiveSMP, receiveAgent]
  where
    subscribe :: M ()
    subscribe = forever $ do
      (srv, subs) <- atomically $ readTBQueue newSubQ
      -- TODO [ntfdb] as we now group by server before putting subs to queue,
      -- maybe this "subscribe" thread can be removed completely,
      -- and the caller would directly write to SMPSubscriber queues
      SMPSubscriber {subscriberSubQ} <- getSMPSubscriber srv
      atomically $ writeTQueue subscriberSubQ subs

    -- TODO [ntfdb] this does not guarantee that only one subscriber per server is created
    -- there should be TMVar in the map
    -- This does not need changing if single newSubQ remains, but if it is removed, it need to change
    getSMPSubscriber :: SMPServer -> M SMPSubscriber
    getSMPSubscriber smpServer =
      liftIO (TM.lookupIO smpServer smpSubscribers) >>= maybe createSMPSubscriber pure
      where
        createSMPSubscriber = do
          sub@SMPSubscriber {subThreadId} <- liftIO $ newSMPSubscriber smpServer
          atomically $ TM.insert smpServer sub smpSubscribers
          tId <- mkWeakThreadId =<< forkIO (runSMPSubscriber sub)
          atomically . writeTVar subThreadId $ Just tId
          pure sub

    runSMPSubscriber :: SMPSubscriber -> M ()
    runSMPSubscriber SMPSubscriber {smpServer, subscriberSubQ} = do
      st <- asks store
      forever $ do
        -- TODO [ntfdb] possibly, the subscriptions can be batched here and sent every say 5 seconds
        -- this should be analysed once we have prometheus stats
        subs <- atomically $ readTQueue subscriberSubQ
        -- TODO [ntfdb] validate/partition that SMP server matches and log internal error if not
        updated <- liftIO $ batchUpdateSubStatus st subs NSPending
        logSubStatus smpServer "subscribing" (L.length subs) updated
        liftIO $ subscribeQueues smpServer subs

    -- \| Subscribe to queues. The list of results can have a different order.
    subscribeQueues :: SMPServer -> NonEmpty NtfSubRec -> IO ()
    subscribeQueues srv subs = subscribeQueuesNtfs ca srv (L.map sub subs)
      where
        sub NtfSubRec {smpQueue = SMPQueueNtf {notifierId}, notifierKey} = (notifierId, notifierKey)

    receiveSMP :: M ()
    receiveSMP = forever $ do
      ((_, srv, _), _thVersion, sessionId, ts) <- atomically $ readTBQueue msgQ
      forM ts $ \(ntfId, t) -> case t of
        STUnexpectedError e -> logError $ "SMP client unexpected error: " <> tshow e -- uncorrelated response, should not happen
        STResponse {} -> pure () -- it was already reported as timeout error
        STEvent msgOrErr -> do
          let smpQueue = SMPQueueNtf srv ntfId
          case msgOrErr of
            Right (SMP.NMSG nmsgNonce encNMsgMeta) -> do
              ntfTs <- liftIO getSystemTime
              st <- asks store
              NtfPushServer {pushQ} <- asks pushServer
              stats <- asks serverStats
              liftIO $ updatePeriodStats (activeSubs stats) ntfId
              let newNtf = PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}
              ntfs_ <- liftIO $ addTokenLastNtf st newNtf
              forM_ ntfs_ $ \(tkn, lastNtfs) -> atomically $ writeTBQueue pushQ (tkn, PNMessage lastNtfs)
              -- TODO [ntfdb] track queued notifications separately?
              incNtfStat ntfReceived
            Right SMP.END -> do
              whenM (atomically $ activeClientSession' ca sessionId srv) $ do
                st <- asks store
                void $ liftIO $ updateSrvSubStatus st smpQueue NSEnd
            Right SMP.DELD -> do 
              st <- asks store
              void $ liftIO $ updateSrvSubStatus st smpQueue NSDeleted
            Right (SMP.ERR e) -> logError $ "SMP server error: " <> tshow e
            Right _ -> logError "SMP server unexpected response"
            Left e -> logError $ "SMP client error: " <> tshow e

    receiveAgent = do
      st <- asks store
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected srv ->
            logInfo $ "SMP server reconnected " <> showServer' srv
          CADisconnected srv subs -> do
            forM_ (L.nonEmpty $ map snd $ S.toList subs) $ \nIds -> do
              updated <- liftIO $ batchUpdateSrvSubStatus st srv nIds NSInactive
              logSubStatus srv "disconnected" (L.length nIds) updated
          CASubscribed srv _ nIds -> do
            updated <- liftIO $ batchUpdateSrvSubStatus st srv nIds NSActive
            logSubStatus srv "subscribed" (L.length nIds) updated
          CASubError srv _ errs -> do
            forM_ (L.nonEmpty $ mapMaybe (\(nId, err) -> (nId,) <$> subErrorStatus err) $ L.toList errs) $ \subStatuses -> do
              updated <- liftIO $ batchUpdateSrvSubStatuses st srv subStatuses
              logSubErrors srv subStatuses updated

    logSubStatus :: SMPServer -> T.Text -> Int -> Int64 -> M ()
    logSubStatus srv event n updated =
      logInfo $ "SMP server " <> event <> " " <> showServer' srv <> " (" <> tshow n <> " subs, " <> tshow updated <> " subs updated)"

    logSubErrors :: SMPServer -> NonEmpty (SMP.NotifierId, NtfSubStatus) -> Int64 -> M ()
    logSubErrors srv subs updated = forM_ (L.group $ L.sort $ L.map snd subs) $ \ss -> do
      logError $ "SMP server subscription errors " <> showServer' srv <> ": " <> tshow (L.head ss) <> " (" <> tshow (length ss) <> " errors, " <> tshow updated <> " subs updated)"

    showServer' = decodeLatin1 . strEncode . host

    subErrorStatus :: SMPClientError -> Maybe NtfSubStatus
    subErrorStatus = \case
      PCEProtocolError AUTH -> Just NSAuth
      PCEProtocolError e -> updateErr "SMP error " e
      PCEResponseError e -> updateErr "ResponseError " e
      PCEUnexpectedResponse r -> updateErr "UnexpectedResponse " r
      PCETransportError e -> updateErr "TransportError " e
      PCECryptoError e -> updateErr "CryptoError " e
      PCEIncompatibleHost -> Just $ NSErr "IncompatibleHost"
      PCEResponseTimeout -> Nothing
      PCENetworkError -> Nothing
      PCEIOError _ -> Nothing
      where
        -- Note on moving to PostgreSQL: the idea of logging errors without e is removed here
        updateErr :: Show e => ByteString -> e -> Maybe NtfSubStatus
        updateErr errType e = Just $ NSErr $ errType <> bshow e

    -- TODO [ntfdb] move to store
    -- updateSubStatus smpQueue status = do
    --   st <- asks store
    --   atomically (findNtfSubscription st smpQueue) >>= mapM_ update
    --   where
    --     update NtfSubData {ntfSubId, subStatus} = do
    --       old <- atomically $ stateTVar subStatus (,status)
    --       when (old /= status) $ withNtfLog $ \sl -> logSubscriptionStatus sl ntfSubId status

ntfPush :: NtfPushServer -> M ()
ntfPush s@NtfPushServer {pushQ} = forever $ do
  (tkn@NtfTknRec {ntfTknId, token = t@(DeviceToken pp _), tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  liftIO $ logDebug $ "sending push notification to " <> T.pack (show pp)
  case ntf of
    PNVerification _ ->
      deliverNotification pp tkn ntf >>= \case
        Right _ -> do
          st <- asks store
          void $ liftIO $ setTknStatusConfirmed st tkn
          -- TODO [ntfdb] move to store
          -- forM_ status_ $ \status' -> withNtfLog $ \sl -> logTokenStatus sl ntfTknId status'
          incNtfStatT t ntfVrfDelivered
        Left _ -> incNtfStatT t ntfVrfFailed
    PNCheckMessages -> checkActiveTkn tknStatus $ do
      deliverNotification pp tkn ntf
        >>= incNtfStatT t . (\case Left _ -> ntfCronFailed; Right () -> ntfCronDelivered)
    PNMessage {} -> checkActiveTkn tknStatus $ do
      stats <- asks serverStats
      liftIO $ updatePeriodStats (activeTokens stats) ntfTknId
      deliverNotification pp tkn ntf
        >>= incNtfStatT t . (\case Left _ -> ntfFailed; Right () -> ntfDelivered)
  where
    checkActiveTkn :: NtfTknStatus -> M () -> M ()
    checkActiveTkn status action
      | status == NTActive = action
      | otherwise = liftIO $ logError "bad notification token status"
    deliverNotification :: PushProvider -> NtfTknRec -> PushNotification -> M (Either PushProviderError ())
    deliverNotification pp tkn@NtfTknRec {ntfTknId} ntf = do
      deliver <- liftIO $ getPushClient s pp
      liftIO (runExceptT $ deliver tkn ntf) >>= \case
        Right _ -> pure $ Right ()
        Left e -> case e of
          PPConnection _ -> retryDeliver
          PPRetryLater -> retryDeliver
          PPCryptoError _ -> err e
          PPResponseError {} -> err e
          PPTokenInvalid r -> do
            st <- asks store
            void $ liftIO $ updateTknStatus st tkn $ NTInvalid $ Just r
            err e
          PPPermanentError -> err e
      where
        retryDeliver :: M (Either PushProviderError ())
        retryDeliver = do
          deliver <- liftIO $ newPushClient s pp
          liftIO (runExceptT $ deliver tkn ntf) >>= \case
            Right _ -> pure $ Right ()
            Left e -> case e of
              PPTokenInvalid r -> do
                st <- asks store
                void $ liftIO $ updateTknStatus st tkn $ NTInvalid $ Just r
                err e
              _ -> err e
        err e = logError ("Push provider error (" <> tshow pp <> ", " <> tshow ntfTknId <> "): " <> tshow e) $> Left e

-- TODO [ntfdb] move to store
-- updateTknStatus :: NtfTknData -> NtfTknStatus -> M ()
-- updateTknStatus NtfTknData {ntfTknId, tknStatus} status = do
--   old <- atomically $ stateTVar tknStatus (,status)
--   when (old /= status) $ withNtfLog $ \sl -> logTokenStatus sl ntfTknId status

runNtfClientTransport :: Transport c => THandleNTF c 'TServer -> M ()
runNtfClientTransport th@THandle {params} = do
  qSize <- asks $ clientQSize . config
  ts <- liftIO getSystemTime
  c <- liftIO $ newNtfServerClient qSize params ts
  s <- asks subscriber
  ps <- asks pushServer
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([liftIO $ send th c, client c s ps, receive th c] <> disconnectThread_ c expCfg)
    `finally` liftIO (clientDisconnected c)
  where
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport th (rcvActiveAt c) (sndActiveAt c) expCfg (pure True)]
    disconnectThread_ _ _ = []

clientDisconnected :: NtfServerClient -> IO ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: Transport c => THandleNTF c 'TServer -> NtfServerClient -> M ()
receive th@THandle {params = THandleParams {thAuth}} NtfServerClient {rcvQ, sndQ, rcvActiveAt} = forever $ do
  ts <- L.toList <$> liftIO (tGet th)
  atomically . (writeTVar rcvActiveAt $!) =<< liftIO getSystemTime
  (errs, cmds) <- partitionEithers <$> mapM cmdAction ts
  write sndQ errs
  write rcvQ cmds
  where
    cmdAction t@(_, _, (corrId, entId, cmdOrError)) =
      case cmdOrError of
        Left e -> do
          logError $ "invalid client request: " <> tshow e
          pure $ Left (corrId, entId, NRErr e)
        Right cmd ->
          verified =<< verifyNtfTransmission ((,C.cbNonce (SMP.bs corrId)) <$> thAuth) t cmd
          where
            verified = \case
              VRVerified req -> pure $ Right req
              VRFailed -> do
                logError "unauthorized client request"
                pure $ Left (corrId, entId, NRErr AUTH)
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty

send :: Transport c => THandleNTF c 'TServer -> NtfServerClient -> IO ()
send h@THandle {params} NtfServerClient {sndQ, sndActiveAt} = forever $ do
  ts <- atomically $ readTBQueue sndQ
  void . liftIO $ tPut h $ L.map (\t -> Right (Nothing, encodeTransmission params t)) ts
  atomically . (writeTVar sndActiveAt $!) =<< liftIO getSystemTime

data VerificationResult = VRVerified NtfRequest | VRFailed

verifyNtfTransmission :: Maybe (THandleAuth 'TServer, C.CbNonce) -> SignedTransmission ErrorType NtfCmd -> NtfCmd -> M VerificationResult
verifyNtfTransmission auth_ (tAuth, authorized, (corrId, entId, _)) cmd = do
  st <- asks store
  case cmd of
    -- TODO [ntfdb] this looks suspicious, as if it can prevent repeated registrations
    NtfCmd SToken c@(TNEW tkn@(NewNtfTkn _ k _)) -> do
      r_ <- liftIO $ getNtfTokenRegistration st tkn
      pure $
        if verifyCmdAuthorization auth_ tAuth authorized k
          then case r_ of
            Right t@NtfTknRec {tknVerifyKey}
              | k == tknVerifyKey -> VRVerified $ tknCmd t c
              | otherwise -> VRFailed
            Left _ -> VRVerified (NtfReqNew corrId (ANE SToken tkn))
          else VRFailed
    NtfCmd SToken c -> do
      t_ <- liftIO $ getNtfToken st entId
      verifyToken_' t_ (`tknCmd` c)
    NtfCmd SSubscription c@(SNEW sub@(NewNtfSub tknId smpQueue _)) ->
      liftIO $ verify <$> findNtfSubscription st tknId smpQueue
      where
        verify = \case
          Right (t, s_) -> verifyToken t $ case s_ of
            Nothing -> NtfReqNew corrId (ANE SSubscription sub)
            Just s -> subCmd s c
          -- TODO [ntfdb] it should simply return error if it is not AUTH
          Left _ -> maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
    NtfCmd SSubscription PING -> pure $ VRVerified $ NtfReqPing corrId entId
    NtfCmd SSubscription c -> liftIO $ verify <$> getNtfSubscription st entId
      where
        verify = \case
          Right (t, s) -> verifyToken t $ subCmd s c
          -- TODO [ntfdb] it should simply return error if it is not AUTH
          Left _ -> maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
  where
    tknCmd t c = NtfReqCmd SToken (NtfTkn t) (corrId, entId, c)
    subCmd s c = NtfReqCmd SSubscription (NtfSub s) (corrId, entId, c)
    verifyToken_' :: Either ErrorType NtfTknRec -> (NtfTknRec -> NtfRequest) -> M VerificationResult
    verifyToken_' t_ result = pure $ case t_ of
      Right t -> verifyToken t $ result t
      -- TODO [ntfdb] it should simply return error if it is not AUTH
      Left _ -> maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
    verifyToken :: NtfTknRec -> NtfRequest -> VerificationResult
    verifyToken NtfTknRec {tknVerifyKey} r
      | verifyCmdAuthorization auth_ tAuth authorized tknVerifyKey = VRVerified r
      | otherwise = VRFailed

client :: NtfServerClient -> NtfSubscriber -> NtfPushServer -> M ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {newSubQ, smpAgent = ca} NtfPushServer {pushQ, intervalNotifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= atomically . writeTBQueue sndQ
  where
    -- TODO [ntfdb] move to store, updating timestamp when token is read
    -- updateTokenDate :: RoundedSystemTime -> Maybe NtfTknData -> M ()
    -- updateTokenDate ts' = mapM_ $ \NtfTknData {ntfTknId, tknUpdatedAt} -> do
    --   let t' = Just ts'
    --   t <- atomically $ swapTVar tknUpdatedAt t'
    --   unless (t' == t) $ withNtfLog $ \s -> logUpdateTokenTime s ntfTknId ts'
    processCommand :: NtfRequest -> M (Transmission NtfResponse)
    processCommand = \case
      NtfReqNew corrId (ANE SToken newTkn@(NewNtfTkn token _ dhPubKey)) -> (corrId,NoEntity,) <$> do
        logDebug "TNEW - new token"
        st <- asks store
        (srvDhPubKey, srvDhPrivKey) <- atomically . C.generateKeyPair =<< asks random
        let dhSecret = C.dh' dhPubKey srvDhPrivKey
        tknId <- getId
        regCode <- getRegCode
        ts <- liftIO $ getSystemDate
        let tkn = mkNtfTknRec tknId newTkn srvDhPrivKey dhSecret regCode ts
        liftIO (addNtfToken st tkn) >>= \case
          Left e -> pure $ NRErr e
          Right () -> do
            atomically $ writeTBQueue pushQ (tkn, PNVerification regCode)
            incNtfStatT token ntfVrfQueued
            -- TODO [ntfdb] move to store
            -- withNtfLog (`logCreateToken` tkn)
            incNtfStatT token tknCreated
            pure $ NRTknId tknId srvDhPubKey
      NtfReqCmd SToken (NtfTkn tkn@NtfTknRec {token, ntfTknId, tknStatus, tknRegCode, tknDhSecret, tknDhPrivKey}) (corrId, tknId, cmd) -> do
        (corrId,tknId,) <$> case cmd of
          TNEW (NewNtfTkn _ _ dhPubKey) -> do
            logDebug "TNEW - registered token"
            let dhSecret = C.dh' dhPubKey tknDhPrivKey
            -- it is required that DH secret is the same, to avoid failed verifications if notification is delaying
            if tknDhSecret == dhSecret
              then do
                atomically $ writeTBQueue pushQ (tkn, PNVerification tknRegCode)
                incNtfStatT token ntfVrfQueued
                pure $ NRTknId ntfTknId $ C.publicKey tknDhPrivKey
              else pure $ NRErr AUTH
          TVFY code -- this allows repeated verification for cases when client connection dropped before server response
            | (tknStatus == NTRegistered || tknStatus == NTConfirmed || tknStatus == NTActive) && tknRegCode == code -> do
                logDebug "TVFY - token verified"
                st <- asks store
                liftIO (setTknStatusActive st tkn) >>= \case
                  Left e -> pure $ NRErr e
                  Right tIds -> do
                    -- TODO [ntfdb] this will be unnecessary if all cron notifications move to one thread
                    forM_ tIds cancelInvervalNotifications
                    incNtfStatT token tknVerified
                    pure NROk
            | otherwise -> do
                logDebug "TVFY - incorrect code or token status"
                liftIO $ print tkn
                let NtfRegCode c = code
                liftIO $ print $ B64.encode c
                pure $ NRErr AUTH
          TCHK -> do
            logDebug "TCHK"
            pure $ NRTkn tknStatus
          TRPL token' -> do
            logDebug "TRPL - replace token"
            st <- asks store
            regCode <- getRegCode
            let tkn' = tkn {token = token', tknStatus = NTRegistered, tknRegCode = regCode}
            liftIO (replaceNtfToken st tkn') >>= \case
              Left e -> pure $ NRErr e
              Right () -> do
                atomically $ writeTBQueue pushQ (tkn', PNVerification regCode)
                incNtfStatT token ntfVrfQueued
                -- TODO [ntfdb] move to store
                -- withNtfLog $ \s -> logUpdateToken s tknId token' regCode
                incNtfStatT token tknReplaced
                pure NROk
          TDEL -> do
            logDebug "TDEL"
            st <- asks store
            liftIO (deleteNtfToken st tknId) >>= \case
              Left e -> pure $ NRErr e
              Right ss -> do
                forM_ ss $ \(smpServer, nIds) -> do
                  atomically $ removeSubscriptions ca smpServer SPNotifier nIds
                  atomically $ removePendingSubs ca smpServer SPNotifier nIds
                cancelInvervalNotifications tknId
                -- TODO [ntfdb] move to store
                -- withNtfLog (`logDeleteToken` tknId)
                incNtfStatT token tknDeleted
                pure NROk
          TCRN 0 -> do
            logDebug "TCRN 0"
            st <- asks store
            liftIO (updateTknCronInterval st ntfTknId 0) >>= \case
              Left e -> pure $ NRErr e
              Right () -> do
                -- TODO [ntfdb] move cron intervals to one thread
                cancelInvervalNotifications tknId
                -- TODO [ntfdb] move to store
                -- withNtfLog $ \s -> logTokenCron s tknId 0
                pure NROk
          TCRN int
            | int < 20 -> pure $ NRErr QUOTA
            | otherwise -> do
                logDebug "TCRN"
                st <- asks store
                liftIO (updateTknCronInterval st ntfTknId int) >>= \case
                  Left e -> pure $ NRErr e
                  Right () -> do
                    -- TODO [ntfdb] move cron intervals to one thread
                    liftIO (TM.lookupIO tknId intervalNotifiers) >>= \case
                      Nothing -> runIntervalNotifier int
                      Just IntervalNotifier {interval, action} ->
                        unless (interval == int) $ do
                          uninterruptibleCancel action
                          runIntervalNotifier int
                    -- TODO [ntfdb] move to store
                    -- withNtfLog $ \s -> logTokenCron s tknId int
                    pure NROk
            where
              runIntervalNotifier interval = do
                action <- async . intervalNotifier $ fromIntegral interval * 1000000 * 60
                let notifier = IntervalNotifier {action, token = tkn, interval}
                atomically $ TM.insert tknId notifier intervalNotifiers
                where
                  intervalNotifier delay = forever $ do
                    liftIO $ threadDelay' delay
                    atomically $ writeTBQueue pushQ (tkn, PNCheckMessages)
      NtfReqNew corrId (ANE SSubscription newSub@(NewNtfSub _ (SMPQueueNtf srv _) _)) -> do
        logDebug "SNEW - new subscription"
        st <- asks store
        subId <- getId
        let sub = mkNtfSubData subId newSub
        resp <-
          liftIO (addNtfSubscription st sub) >>= \case
            Left e -> pure $ NRErr e
            Right True -> do
              atomically $ writeTBQueue newSubQ (srv, [sub])
              incNtfStat subCreated
              pure $ NRSubId subId
            -- TODO [ntfdb] we must allow repeated inserts that don't change credentials
            Right False -> pure $ NRErr AUTH
        -- TODO [ntfdb] move to store
        -- withNtfLog (`logCreateSubscription` sub)
        pure (corrId, NoEntity, resp)
      NtfReqCmd SSubscription (NtfSub NtfSubRec {smpQueue = SMPQueueNtf {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
        (corrId,subId,) <$> case cmd of
          SNEW (NewNtfSub _ _ notifierKey) -> do
            logDebug "SNEW - existing subscription"
            -- possible improvement: retry if subscription failed, if pending or AUTH do nothing
            pure $
              if notifierKey == registeredNKey
                then NRSubId subId
                else NRErr AUTH
          SCHK -> do
            logDebug "SCHK"
            pure $ NRSub subStatus
          SDEL -> do
            logDebug "SDEL"
            st <- asks store
            liftIO (deleteNtfSubscription st subId) >>= \case
              Left e -> pure $ NRErr e
              Right () -> do
                atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
                atomically $ removePendingSub ca smpServer (SPNotifier, notifierId)
                -- TODO [ntfdb] move to store
                -- withNtfLog (`logDeleteSubscription` subId)
                incNtfStat subDeleted
                pure NROk
          PING -> pure NRPong
      NtfReqPing corrId entId -> pure (corrId, entId, NRPong)
    getId :: M NtfEntityId
    getId = fmap EntityId . randomBytes =<< asks (subIdBytes . config)
    getRegCode :: M NtfRegCode
    getRegCode = NtfRegCode <$> (randomBytes =<< asks (regCodeBytes . config))
    randomBytes :: Int -> M ByteString
    randomBytes n = atomically . C.randomBytes n =<< asks random
    cancelInvervalNotifications :: NtfTokenId -> M ()
    cancelInvervalNotifications tknId =
      atomically (TM.lookupDelete tknId intervalNotifiers)
        >>= mapM_ (uninterruptibleCancel . action)

-- TODO [ntfdb] move to postgres store
-- withNtfLog :: (StoreLog 'WriteMode -> IO a) -> M ()
-- withNtfLog action = liftIO . mapM_ action =<< asks storeLog

incNtfStatT :: DeviceToken -> (NtfServerStats -> IORef Int) -> M ()
incNtfStatT (DeviceToken PPApnsNull _) _ = pure ()
incNtfStatT _ statSel = incNtfStat statSel

incNtfStat :: (NtfServerStats -> IORef Int) -> M ()
incNtfStat statSel = do
  stats <- asks serverStats
  liftIO $ atomicModifyIORef'_ (statSel stats) (+ 1)

restoreServerLastNtfs :: NtfSTMStore -> FilePath -> IO ()
restoreServerLastNtfs st f =
  whenM (doesFileExist f) $ do
    logInfo $ "restoring last notifications from file " <> T.pack f
    runExceptT (liftIO (B.readFile f) >>= mapM restoreNtf . B.lines) >>= \case
      Left e -> do
        logError . T.pack $ "error restoring last notifications: " <> e
        exitFailure
      Right _ -> do
        renameFile f $ f <> ".bak"
        logInfo "last notifications restored"
  where
    restoreNtf s = do
      TNMRv1 tknId ntf <- liftEither . first (ntfErr "parsing") $ strDecode s
      liftIO $ stmStoreTokenLastNtf st tknId ntf
      where
        ntfErr :: Show e => String -> e -> String
        ntfErr op e = op <> " error (" <> show e <> "): " <> B.unpack (B.take 100 s)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= liftIO . getNtfServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: M ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d -> do
          s <- asks serverStats
          liftIO $ setNtfServerStats s d
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
