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
import qualified Data.ByteString.Builder as BLD
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import qualified Data.IntSet as IS
import Data.List (intercalate, partition, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
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
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Server.StoreLog
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (EntityId (..), ErrorType (..), ProtocolServer (host), SMPServer, SignedTransmission, Transmission, pattern NoEntity, pattern SMPServer, encodeTransmission, tGet, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Control (CPClientRole (..))
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime, getSystemDate)
import Simplex.Messaging.Server.Stats (PeriodStats (..), PeriodStatCounts (..), periodStatCounts, updatePeriodStats)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), THandleAuth (..), THandleParams (..), TProxy, Transport (..), TransportPeer (..), defaultSupportedParams)
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server (AddHTTP, runTransportServer, runLocalTCPServer)
import Simplex.Messaging.Util
import System.Exit (exitFailure)
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

runNtfServer :: NtfServerConfig -> IO ()
runNtfServer cfg = do
  started <- newEmptyTMVarIO
  runNtfServerBlocking started cfg

runNtfServerBlocking :: TMVar Bool -> NtfServerConfig -> IO ()
runNtfServerBlocking started cfg = runReaderT (ntfServer cfg started) =<< newNtfServerEnv cfg

type M a = ReaderT NtfEnv IO a

ntfServer :: NtfServerConfig -> TMVar Bool -> M ()
ntfServer cfg@NtfServerConfig {transports, transportConfig = tCfg} started = do
  restoreServerLastNtfs
  restoreServerStats
  s <- asks subscriber
  ps <- asks pushServer
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
    saveServer = withNtfLog closeStoreLog >> saveServerLastNtfs >> saveServerStats

    serverStatsThread_ :: NtfServerConfig -> [M ()]
    serverStatsThread_ NtfServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      logInfo $ "server stats log enabled: " <> T.pack statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      NtfServerStats {fromTime, tknCreated, tknVerified, tknDeleted, subCreated, subDeleted, ntfReceived, ntfDelivered, ntfFailed, ntfCronDelivered, ntfCronFailed, ntfVrfDelivered, ntfVrfFailed, ntfVrfInvalidTkn, activeTokens, activeSubs} <-
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
          subCreated' <- atomicSwapIORef subCreated 0
          subDeleted' <- atomicSwapIORef subDeleted 0
          ntfReceived' <- atomicSwapIORef ntfReceived 0
          ntfDelivered' <- atomicSwapIORef ntfDelivered 0
          ntfFailed' <- atomicSwapIORef ntfFailed 0
          ntfCronDelivered' <- atomicSwapIORef ntfCronDelivered 0
          ntfCronFailed' <- atomicSwapIORef ntfCronFailed 0
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
                show ntfFailed',
                show ntfCronDelivered',
                show ntfCronFailed',
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
                putStat "subCreated" subCreated
                putStat "subDeleted" subDeleted
                putStat "ntfReceived" ntfReceived
                putStat "ntfDelivered" ntfDelivered
                putStat "ntfFailed" ntfFailed
                putStat "ntfCronDelivered" ntfCronDelivered
                putStat "ntfCronFailed" ntfCronFailed
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
  subs <- readTVarIO =<< asks (subscriptions . store)
  subs' <- filterM (fmap ntfShouldSubscribe . readTVarIO . subStatus) $ M.elems subs
  atomically . writeTBQueue newSubQ $ map NtfSub subs'
  logInfo $ "SMP resubscriptions queued (" <> tshow (length subs') <> " subscriptions)"

ntfSubscriber :: NtfSubscriber -> M ()
ntfSubscriber NtfSubscriber {smpSubscribers, newSubQ, smpAgent = ca@SMPClientAgent {msgQ, agentQ}} = do
  raceAny_ [subscribe, receiveSMP, receiveAgent]
  where
    subscribe :: M ()
    subscribe = forever $ do
      subs <- atomically (readTBQueue newSubQ)
      let ss = L.groupAllWith server subs
      batchSize <- asks $ subsBatchSize . config
      forM_ ss $ \serverSubs -> do
        let srv = server $ L.head serverSubs
            batches = toChunks batchSize $ L.toList serverSubs
        SMPSubscriber {newSubQ = subscriberSubQ} <- getSMPSubscriber srv
        mapM_ (atomically . writeTQueue subscriberSubQ) batches

    server :: NtfEntityRec 'Subscription -> SMPServer
    server (NtfSub sub) = ntfSubServer sub

    getSMPSubscriber :: SMPServer -> M SMPSubscriber
    getSMPSubscriber smpServer =
      liftIO (TM.lookupIO smpServer smpSubscribers) >>= maybe createSMPSubscriber pure
      where
        createSMPSubscriber = do
          sub@SMPSubscriber {subThreadId} <- liftIO newSMPSubscriber
          atomically $ TM.insert smpServer sub smpSubscribers
          tId <- mkWeakThreadId =<< forkIO (runSMPSubscriber sub)
          atomically . writeTVar subThreadId $ Just tId
          pure sub

    runSMPSubscriber :: SMPSubscriber -> M ()
    runSMPSubscriber SMPSubscriber {newSubQ = subscriberSubQ} =
      forever $ do
        subs <- atomically $ readTQueue subscriberSubQ
        let subs' = L.map (\(NtfSub sub) -> sub) subs
            srv = server $ L.head subs
        logSubStatus srv "subscribing" $ length subs
        mapM_ (\NtfSubData {smpQueue} -> updateSubStatus smpQueue NSPending) subs'
        liftIO $ subscribeQueues srv subs'

    -- \| Subscribe to queues. The list of results can have a different order.
    subscribeQueues :: SMPServer -> NonEmpty NtfSubData -> IO ()
    subscribeQueues srv subs = subscribeQueuesNtfs ca srv (L.map sub subs)
      where
        sub NtfSubData {smpQueue = SMPQueueNtf {notifierId}, notifierKey} = (notifierId, notifierKey)

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
              tkn_ <- atomically (findNtfSubscriptionToken st smpQueue)
              forM_ tkn_ $ \tkn -> do
                let newNtf = PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}
                lastNtfs <- liftIO $ addTokenLastNtf st (ntfTknId tkn) newNtf
                atomically (writeTBQueue pushQ (tkn, PNMessage lastNtfs))
              incNtfStat ntfReceived
            Right SMP.END ->
              whenM (atomically $ activeClientSession' ca sessionId srv) $
                updateSubStatus smpQueue NSEnd
            Right SMP.DELD -> updateSubStatus smpQueue NSDeleted
            Right (SMP.ERR e) -> logError $ "SMP server error: " <> tshow e
            Right _ -> logError "SMP server unexpected response"
            Left e -> logError $ "SMP client error: " <> tshow e

    receiveAgent =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected srv ->
            logInfo $ "SMP server reconnected " <> showServer' srv
          CADisconnected srv subs -> do
            logSubStatus srv "disconnected" $ length subs
            forM_ subs $ \(_, ntfId) -> do
              let smpQueue = SMPQueueNtf srv ntfId
              updateSubStatus smpQueue NSInactive
          CASubscribed srv _ subs -> do
            forM_ subs $ \ntfId -> updateSubStatus (SMPQueueNtf srv ntfId) NSActive
            logSubStatus srv "subscribed" $ length subs
          CASubError srv _ errs ->
            forM errs (\(ntfId, err) -> handleSubError (SMPQueueNtf srv ntfId) err)
              >>= logSubErrors srv . catMaybes . L.toList

    logSubStatus srv event n =
      when (n > 0) . logInfo $
        "SMP server " <> event <> " " <> showServer' srv <> " (" <> tshow n <> " subscriptions)"

    logSubErrors :: SMPServer -> [NtfSubStatus] -> M ()
    logSubErrors srv errs = forM_ (L.group $ sort errs) $ \errs' -> do
      logError $ "SMP subscription errors on server " <> showServer' srv <> ": " <> tshow (L.head errs') <> " (" <> tshow (length errs') <> " errors)"

    showServer' = decodeLatin1 . strEncode . host

    handleSubError :: SMPQueueNtf -> SMPClientError -> M (Maybe NtfSubStatus)
    handleSubError smpQueue = \case
      PCEProtocolError AUTH -> updateSubStatus smpQueue NSAuth $> Just NSAuth
      PCEProtocolError e -> updateErr "SMP error " e
      PCEResponseError e -> updateErr "ResponseError " e
      PCEUnexpectedResponse r -> updateErr "UnexpectedResponse " r
      PCETransportError e -> updateErr "TransportError " e
      PCECryptoError e -> updateErr "CryptoError " e
      PCEIncompatibleHost -> let e = NSErr "IncompatibleHost" in updateSubStatus smpQueue e $> Just e
      PCEResponseTimeout -> pure Nothing
      PCENetworkError -> pure Nothing
      PCEIOError _ -> pure Nothing
      where
        updateErr :: Show e => ByteString -> e -> M (Maybe NtfSubStatus)
        updateErr errType e = updateSubStatus smpQueue (NSErr $ errType <> bshow e) $> Just (NSErr errType)

    updateSubStatus smpQueue status = do
      st <- asks store
      atomically (findNtfSubscription st smpQueue) >>= mapM_ update
      where
        update NtfSubData {ntfSubId, subStatus} = do
          old <- atomically $ stateTVar subStatus (,status)
          when (old /= status) $ withNtfLog $ \sl -> logSubscriptionStatus sl ntfSubId status

ntfPush :: NtfPushServer -> M ()
ntfPush s@NtfPushServer {pushQ} = forever $ do
  (tkn@NtfTknData {ntfTknId, token = DeviceToken pp _, tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  liftIO $ logDebug $ "sending push notification to " <> T.pack (show pp)
  status <- readTVarIO tknStatus
  case ntf of
    PNVerification _ -> case status of
      NTInvalid _ -> do
        logError $ "bad notification token status: " <> tshow status
        incNtfStat ntfVrfInvalidTkn
      -- TODO nothing makes token "expired" on the server
      NTExpired -> do
        logError $ "bad notification token status: " <> tshow status
        incNtfStat ntfVrfInvalidTkn
      _ ->
        deliverNotification pp tkn ntf >>= \case
          Right _ -> do
            status_ <- atomically $ stateTVar tknStatus $ \case
              NTActive -> (Nothing, NTActive)
              NTConfirmed -> (Nothing, NTConfirmed)
              _ -> (Just NTConfirmed, NTConfirmed)
            forM_ status_ $ \status' -> withNtfLog $ \sl -> logTokenStatus sl ntfTknId status'
            incNtfStat ntfVrfDelivered
          Left _ -> incNtfStat ntfVrfFailed
    PNCheckMessages -> checkActiveTkn status $ do
      deliverNotification pp tkn ntf
        >>= incNtfStat . (\case Left _ -> ntfCronFailed; Right () -> ntfCronDelivered)
    PNMessage {} -> checkActiveTkn status $ do
      stats <- asks serverStats
      liftIO $ updatePeriodStats (activeTokens stats) ntfTknId
      deliverNotification pp tkn ntf
        >>= incNtfStat . (\case Left _ -> ntfFailed; Right () -> ntfDelivered)
  where
    checkActiveTkn :: NtfTknStatus -> M () -> M ()
    checkActiveTkn status action
      | status == NTActive = action
      | otherwise = liftIO $ logError "bad notification token status"
    deliverNotification :: PushProvider -> NtfTknData -> PushNotification -> M (Either PushProviderError ())
    deliverNotification pp tkn@NtfTknData {ntfTknId} ntf = do
      deliver <- liftIO $ getPushClient s pp
      liftIO (runExceptT $ deliver tkn ntf) >>= \case
        Right _ -> pure $ Right ()
        Left e -> case e of
          PPConnection _ -> retryDeliver
          PPRetryLater -> retryDeliver
          PPCryptoError _ -> err e
          PPResponseError _ _ -> err e
          PPTokenInvalid r -> updateTknStatus tkn (NTInvalid $ Just r) >> err e
          PPPermanentError -> err e
      where
        retryDeliver :: M (Either PushProviderError ())
        retryDeliver = do
          deliver <- liftIO $ newPushClient s pp
          liftIO (runExceptT $ deliver tkn ntf) >>= either err (pure . Right)
        err e = logError ("Push provider error (" <> tshow pp <> ", " <> tshow ntfTknId <> "): " <> tshow e) $> Left e

updateTknStatus :: NtfTknData -> NtfTknStatus -> M ()
updateTknStatus NtfTknData {ntfTknId, tknStatus} status = do
  old <- atomically $ stateTVar tknStatus (,status)
  when (old /= status) $ withNtfLog $ \sl -> logTokenStatus sl ntfTknId status

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

data VerificationResult = VRVerified (Maybe NtfTknData, NtfRequest) | VRFailed

verifyNtfTransmission :: Maybe (THandleAuth 'TServer, C.CbNonce) -> SignedTransmission ErrorType NtfCmd -> NtfCmd -> M VerificationResult
verifyNtfTransmission auth_ (tAuth, authorized, (corrId, entId, _)) cmd = do
  st <- asks store
  case cmd of
    NtfCmd SToken c@(TNEW tkn@(NewNtfTkn _ k _)) -> do
      r_ <- atomically $ getNtfTokenRegistration st tkn
      pure $
        if verifyCmdAuthorization auth_ tAuth authorized k
          then case r_ of
            Just t@NtfTknData {tknVerifyKey}
              | k == tknVerifyKey -> verifiedTknCmd t c
              | otherwise -> VRFailed
            Nothing -> VRVerified (Nothing, NtfReqNew corrId (ANE SToken tkn))
          else VRFailed
    NtfCmd SToken c -> do
      t_ <- liftIO $ getNtfTokenIO st entId
      verifyToken t_ (`verifiedTknCmd` c)
    NtfCmd SSubscription c@(SNEW sub@(NewNtfSub tknId smpQueue _)) -> do
      s_ <- atomically $ findNtfSubscription st smpQueue
      case s_ of
        Nothing -> do
          t_ <- atomically $ getActiveNtfToken st tknId
          verifyToken' t_ $ VRVerified (t_, NtfReqNew corrId (ANE SSubscription sub))
        Just s@NtfSubData {tokenId = subTknId} ->
          if subTknId == tknId
            then do
              t_ <- atomically $ getActiveNtfToken st subTknId
              verifyToken' t_ $ verifiedSubCmd t_ s c
            else pure $ maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
    NtfCmd SSubscription PING -> pure $ VRVerified (Nothing, NtfReqPing corrId entId)
    NtfCmd SSubscription c -> do
      s_ <- liftIO $ getNtfSubscriptionIO st entId
      case s_ of
        Just s@NtfSubData {tokenId = subTknId} -> do
          t_ <- atomically $ getActiveNtfToken st subTknId
          verifyToken' t_ $ verifiedSubCmd t_ s c
        _ -> pure $ maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
  where
    verifiedTknCmd t c = VRVerified (Just t, NtfReqCmd SToken (NtfTkn t) (corrId, entId, c))
    verifiedSubCmd t_ s c = VRVerified (t_, NtfReqCmd SSubscription (NtfSub s) (corrId, entId, c))
    verifyToken :: Maybe NtfTknData -> (NtfTknData -> VerificationResult) -> M VerificationResult
    verifyToken t_ positiveVerificationResult =
      pure $ case t_ of
        Just t@NtfTknData {tknVerifyKey} ->
          if verifyCmdAuthorization auth_ tAuth authorized tknVerifyKey
            then positiveVerificationResult t
            else VRFailed
        _ -> maybe False (dummyVerifyCmd auth_ authorized) tAuth `seq` VRFailed
    verifyToken' :: Maybe NtfTknData -> VerificationResult -> M VerificationResult
    verifyToken' t_ = verifyToken t_ . const

client :: NtfServerClient -> NtfSubscriber -> NtfPushServer -> M ()
client NtfServerClient {rcvQ, sndQ} NtfSubscriber {newSubQ, smpAgent = ca} NtfPushServer {pushQ, intervalNotifiers} =
  forever $ do
    ts <- liftIO getSystemDate
    atomically (readTBQueue rcvQ)
      >>= mapM (\(tkn_, req) -> updateTokenDate ts tkn_ >> processCommand req)
      >>= atomically . writeTBQueue sndQ
  where
    updateTokenDate :: RoundedSystemTime -> Maybe NtfTknData -> M ()
    updateTokenDate ts' = mapM_ $ \NtfTknData {ntfTknId, tknUpdatedAt} -> do
      let t' = Just ts'
      t <- atomically $ swapTVar tknUpdatedAt t'
      unless (t' == t) $ withNtfLog $ \s -> logUpdateTokenTime s ntfTknId ts'
      
    processCommand :: NtfRequest -> M (Transmission NtfResponse)
    processCommand = \case
      NtfReqNew corrId (ANE SToken newTkn@(NewNtfTkn token _ dhPubKey)) -> do
        logDebug "TNEW - new token"
        st <- asks store
        ks@(srvDhPubKey, srvDhPrivKey) <- atomically . C.generateKeyPair =<< asks random
        let dhSecret = C.dh' dhPubKey srvDhPrivKey
        tknId <- getId
        regCode <- getRegCode
        ts <- liftIO $ getSystemDate
        tkn <- liftIO $ mkNtfTknData tknId newTkn ks dhSecret regCode ts
        atomically $ addNtfToken st tknId tkn
        atomically $ writeTBQueue pushQ (tkn, PNVerification regCode)
        withNtfLog (`logCreateToken` tkn)
        incNtfStatT token tknCreated
        pure (corrId, NoEntity, NRTknId tknId srvDhPubKey)
      NtfReqCmd SToken (NtfTkn tkn@NtfTknData {token, ntfTknId, tknStatus, tknRegCode, tknDhSecret, tknDhKeys = (srvDhPubKey, srvDhPrivKey), tknCronInterval}) (corrId, tknId, cmd) -> do
        status <- readTVarIO tknStatus
        (corrId,tknId,) <$> case cmd of
          TNEW (NewNtfTkn _ _ dhPubKey) -> do
            logDebug "TNEW - registered token"
            let dhSecret = C.dh' dhPubKey srvDhPrivKey
            -- it is required that DH secret is the same, to avoid failed verifications if notification is delaying
            if tknDhSecret == dhSecret
              then do
                atomically $ writeTBQueue pushQ (tkn, PNVerification tknRegCode)
                pure $ NRTknId ntfTknId srvDhPubKey
              else pure $ NRErr AUTH
          TVFY code -- this allows repeated verification for cases when client connection dropped before server response
            | (status == NTRegistered || status == NTConfirmed || status == NTActive) && tknRegCode == code -> do
                logDebug "TVFY - token verified"
                st <- asks store
                updateTknStatus tkn NTActive
                tIds <- atomically $ removeInactiveTokenRegistrations st tkn
                forM_ tIds cancelInvervalNotifications
                incNtfStatT token tknVerified
                pure NROk
            | otherwise -> do
                logDebug "TVFY - incorrect code or token status"
                pure $ NRErr AUTH
          TCHK -> do
            logDebug "TCHK"
            pure $ NRTkn status
          TRPL token' -> do
            logDebug "TRPL - replace token"
            st <- asks store
            regCode <- getRegCode
            atomically $ do
              removeTokenRegistration st tkn
              writeTVar tknStatus NTRegistered
              let tkn' = tkn {token = token', tknRegCode = regCode}
              addNtfToken st tknId tkn'
              writeTBQueue pushQ (tkn', PNVerification regCode)
            withNtfLog $ \s -> logUpdateToken s tknId token' regCode
            incNtfStatT token tknDeleted
            incNtfStatT token tknCreated
            pure NROk
          TDEL -> do
            logDebug "TDEL"
            st <- asks store
            qs <- atomically $ deleteNtfToken st tknId
            forM_ qs $ \SMPQueueNtf {smpServer, notifierId} ->
              atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
            cancelInvervalNotifications tknId
            withNtfLog (`logDeleteToken` tknId)
            incNtfStatT token tknDeleted
            pure NROk
          TCRN 0 -> do
            logDebug "TCRN 0"
            atomically $ writeTVar tknCronInterval 0
            cancelInvervalNotifications tknId
            withNtfLog $ \s -> logTokenCron s tknId 0
            pure NROk
          TCRN int
            | int < 20 -> pure $ NRErr QUOTA
            | otherwise -> do
                logDebug "TCRN"
                atomically $ writeTVar tknCronInterval int
                liftIO (TM.lookupIO tknId intervalNotifiers) >>= \case
                  Nothing -> runIntervalNotifier int
                  Just IntervalNotifier {interval, action} ->
                    unless (interval == int) $ do
                      uninterruptibleCancel action
                      runIntervalNotifier int
                withNtfLog $ \s -> logTokenCron s tknId int
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
      NtfReqNew corrId (ANE SSubscription newSub) -> do
        logDebug "SNEW - new subscription"
        st <- asks store
        subId <- getId
        sub <- atomically $ mkNtfSubData subId newSub
        resp <-
          atomically (addNtfSubscription st subId sub) >>= \case
            Just _ -> atomically (writeTBQueue newSubQ [NtfSub sub]) $> NRSubId subId
            _ -> pure $ NRErr AUTH
        withNtfLog (`logCreateSubscription` sub)
        incNtfStat subCreated
        pure (corrId, NoEntity, resp)
      NtfReqCmd SSubscription (NtfSub NtfSubData {smpQueue = SMPQueueNtf {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
        status <- readTVarIO subStatus
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
            pure $ NRSub status
          SDEL -> do
            logDebug "SDEL"
            st <- asks store
            atomically $ deleteNtfSubscription st subId
            atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
            withNtfLog (`logDeleteSubscription` subId)
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

withNtfLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withNtfLog action = liftIO . mapM_ action =<< asks storeLog

incNtfStatT :: DeviceToken -> (NtfServerStats -> IORef Int) -> M ()
incNtfStatT (DeviceToken PPApnsNull _) _ = pure ()
incNtfStatT _ statSel = incNtfStat statSel

incNtfStat :: (NtfServerStats -> IORef Int) -> M ()
incNtfStat statSel = do
  stats <- asks serverStats
  liftIO $ atomicModifyIORef'_ (statSel stats) (+ 1)

saveServerLastNtfs :: M ()
saveServerLastNtfs = asks (storeLastNtfsFile . config) >>= mapM_ saveLastNtfs
  where
    saveLastNtfs f = do
      logInfo $ "saving last notifications to file " <> T.pack f
      NtfStore {tokenLastNtfs} <- asks store
      liftIO . withFile f WriteMode $ \h ->
        readTVarIO tokenLastNtfs >>= mapM_ (saveTokenLastNtfs h) . M.assocs
      logInfo "notifications saved"
      where
        -- reverse on save, to save notifications in order, will become reversed again when restoring.
        saveTokenLastNtfs h (tknId, v) = BLD.hPutBuilder h . encodeLastNtfs tknId . L.reverse =<< readTVarIO v
        encodeLastNtfs tknId = mconcat . L.toList . L.map (\ntf -> BLD.byteString (strEncode $ TNMRv1 tknId ntf) <> BLD.char8 '\n')

restoreServerLastNtfs :: M ()
restoreServerLastNtfs =
  asks (storeLastNtfsFile . config) >>= mapM_ restoreLastNtfs
  where
    restoreLastNtfs f =
      whenM (doesFileExist f) $ do
        logInfo $ "restoring last notifications from file " <> T.pack f
        st <- asks store
        runExceptT (liftIO (LB.readFile f) >>= mapM (restoreNtf st) . LB.lines) >>= \case
          Left e -> do
            logError . T.pack $ "error restoring last notifications: " <> e
            liftIO exitFailure
          Right _ -> do
            renameFile f $ f <> ".bak"
            logInfo "last notifications restored"
      where
        restoreNtf st s' = do
          TNMRv1 tknId ntf <- liftEither . first (ntfErr "parsing") $ strDecode s
          liftIO $ storeTokenLastNtf st tknId ntf
          where
            s = LB.toStrict s'
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
