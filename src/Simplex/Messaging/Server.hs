{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      : Simplex.Messaging.Server
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol server with in-memory persistence
-- and optional append only log of SMP queue records.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Server
  ( runSMPServer,
    runSMPServerBlocking,
    disconnectTransport,
    verifyCmdAuthorization,
    dummyVerifyCmd,
    randomId,
  )
where

import Control.Concurrent.STM.TQueue (flushTQueue)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import qualified Crypto.PubKey.Curve25519 as X25519
import qualified Crypto.Error as CE
import Control.Monad.STM (retry)
import Data.Bifunctor (first)
import Data.ByteString.Base64 (encode)
import qualified Data.ByteString.Builder as BLD
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (fromRight, partitionEithers)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (intercalate, mapAccumR)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality
import GHC.IORef (atomicSwapIORef)
import GHC.Stats (getRTSStats)
import GHC.TypeLits (KnownNat)
import Network.Socket (ServiceName, Socket, socketToHandle)
import Numeric.Natural (Natural)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Client (ProtocolClient (thParams), ProtocolClientError (..), SMPClient, SMPClientError, forwardSMPTransmission, smpProxyError, temporaryClientError)
import Simplex.Messaging.Client.Agent (OwnServer, SMPClientAgent (..), SMPClientAgentEvent (..), closeSMPClientAgent, getSMPServerClient'', isOwnServer, lookupSMPServerClient, getConnectedSMPServerClient)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Control
import Simplex.Messaging.Server.DataLog
import Simplex.Messaging.Server.DataStore
import Simplex.Messaging.Server.Env.STM as Env
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.QueueInfo
import Simplex.Messaging.Server.QueueStore.STM as QS
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Exit (exitFailure)
import System.IO (hPrint, hPutStrLn, hSetNewlineMode, universalNewlineMode)
import System.Mem.Weak (deRefWeak)
import UnliftIO (timeout)
import UnliftIO.Concurrent
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM
#if MIN_VERSION_base(4,18,0)
import Data.List (sort)
import GHC.Conc (listThreads, threadStatus)
import GHC.Conc.Sync (threadLabel)
#endif

-- | Runs an SMP server using passed configuration.
--
-- See a full server here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs
runSMPServer :: ServerConfig -> IO ()
runSMPServer cfg = do
  started <- newEmptyTMVarIO
  runSMPServerBlocking started cfg

-- | Runs an SMP server using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPServerBlocking :: TMVar Bool -> ServerConfig -> IO ()
runSMPServerBlocking started cfg = newEnv cfg >>= runReaderT (smpServer started cfg)

type M a = ReaderT Env IO a

smpServer :: TMVar Bool -> ServerConfig -> M ()
smpServer started cfg@ServerConfig {transports, transportConfig = tCfg} = do
  s <- asks server
  pa <- asks proxyAgent
  expired <- restoreServerMessages
  restoreServerStats expired
  raceAny_
    ( serverThread s "server subscribedQ" subscribedQ subscribers pendingENDs subscriptions cancelSub
        : serverThread s "server ntfSubscribedQ" ntfSubscribedQ Env.notifiers pendingNtfENDs ntfSubscriptions (\_ -> pure ())
        : sendPendingENDsThread s
        : receiveFromProxyAgent pa
        : map runServer transports <> expireMessagesThread_ cfg <> serverStatsThread_ cfg <> controlPortThread_ cfg
    )
    `finally` withLock' (savingLock s) "final" (saveServer False >> closeServer)
  where
    runServer :: (ServiceName, ATransport) -> M ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      ss <- asks sockets
      serverSignKey <- either fail pure . fromTLSCredentials $ tlsServerCredentials serverParams
      env <- ask
      liftIO $ runTransportServerState ss started tcpPort serverParams tCfg $ \h -> runClient serverSignKey t h `runReaderT` env
    fromTLSCredentials (_, pk) = C.x509ToPrivate (pk, []) >>= C.privKey

    saveServer :: Bool -> M ()
    saveServer keepMsgs = do
      withLog closeStoreLog
      withLog' dataLog closeStoreLog
      saveServerMessages keepMsgs
      saveServerStats

    closeServer :: M ()
    closeServer = asks (smpAgent . proxyAgent) >>= liftIO . closeSMPClientAgent

    serverThread ::
      forall s.
      Server ->
      String ->
      (Server -> TQueue (QueueId, ClientId, Subscribed)) ->
      (Server -> TMap QueueId (TVar Client)) ->
      (Server -> TVar (IM.IntMap (NonEmpty RecipientId))) ->
      (Client -> TMap QueueId s) ->
      (s -> IO ()) ->
      M ()
    serverThread s label subQ subs ends clientSubs unsub = do
      labelMyThread label
      cls <- asks clients
      liftIO . forever $
        (atomically (readTQueue $ subQ s) >>= atomically . updateSubscribers cls)
          $>>= endPreviousSubscriptions
          >>= mapM_ unsub
      where
        updateSubscribers :: TVar (IM.IntMap (Maybe Client)) -> (QueueId, ClientId, Bool) -> STM (Maybe (QueueId, Client))
        updateSubscribers cls (qId, clntId, subscribed) =
          -- Client lookup by ID is in the same STM transaction.
          -- In case client disconnects during the transaction,
          -- it will be re-evaluated, and the client won't be stored as subscribed.
          (readTVar cls >>= updateSub (subs s) . IM.lookup clntId)
            $>>= clientToBeNotified
          where
            updateSub ss = \case
              Just (Just clnt)
                | subscribed ->
                    TM.lookup qId ss >>= -- insert subscribed and current client
                      maybe
                        (newTVar clnt >>= \cv -> TM.insert qId cv ss $> Nothing)
                        (\cv -> Just <$> swapTVar cv clnt)
                | otherwise -> TM.lookupDelete qId ss >>= mapM readTVar
              -- This case catches Just Nothing - it cannot happen here.
              -- Nothing is there only before client thread is started.
              _ -> TM.lookup qId ss >>= mapM readTVar -- do not insert client if it is already disconnected, but send END to any other client
            clientToBeNotified c'
              | clntId == clientId c' = pure Nothing
              | otherwise = (\yes -> if yes then Just (qId, c') else Nothing) <$> readTVar (connected c')
        endPreviousSubscriptions :: (QueueId, Client) -> IO (Maybe s)
        endPreviousSubscriptions (qId, c) = do
          atomically $ modifyTVar' (ends s) $ IM.alter (Just . maybe [qId] (qId <|)) (clientId c)
          atomically $ TM.lookupDelete qId (clientSubs c)

    sendPendingENDsThread :: Server -> M ()
    sendPendingENDsThread s = do
      endInt <- asks $ pendingENDInterval . config
      cls <- asks clients
      forever $ do
        threadDelay endInt
        sendPending cls $ pendingENDs s
        sendPending cls $ pendingNtfENDs s
      where
        sendPending cls ref = do
          ends <- atomically $ swapTVar ref IM.empty
          unless (null ends) $ forM_ (IM.assocs ends) $ \(cId, qIds) ->
            mapM_ (queueENDs qIds) . join . IM.lookup cId =<< readTVarIO cls
        queueENDs qIds c@Client {connected, sndQ = q} =
          whenM (readTVarIO connected) $ do
            sent <- atomically $ ifM (isFullTBQueue q) (pure False) (writeTBQueue q ts $> True)
            if sent
              then updateEndStats
              else -- if queue is full it can block
                forkClient c ("sendPendingENDsThread.queueENDs") $
                  atomically (writeTBQueue q ts) >> updateEndStats
          where
            ts = L.map (CorrId "",,END) qIds
            updateEndStats = do
              stats <- asks serverStats
              let len = L.length qIds
              liftIO $ atomicModifyIORef'_ (qSubEnd stats) (+ len)
              liftIO $ atomicModifyIORef'_ (qSubEndB stats) (+ (len `div` 255 + 1)) -- up to 255 ENDs in the batch

    receiveFromProxyAgent :: ProxyAgent -> M ()
    receiveFromProxyAgent ProxyAgent {smpAgent = SMPClientAgent {agentQ}} =
      forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected srv -> logInfo $ "SMP server connected " <> showServer' srv
          CADisconnected srv [] -> logInfo $ "SMP server disconnected " <> showServer' srv
          CADisconnected srv subs -> logError $ "SMP server disconnected " <> showServer' srv <> " / subscriptions: " <> tshow (length subs)
          CASubscribed srv _ subs -> logError $ "SMP server subscribed " <> showServer' srv <> " / subscriptions: " <> tshow (length subs)
          CASubError srv _ errs -> logError $ "SMP server subscription errors " <> showServer' srv <> " / errors: " <> tshow (length errs)
      where
        showServer' = decodeLatin1 . strEncode . host

    expireMessagesThread_ :: ServerConfig -> [M ()]
    expireMessagesThread_ ServerConfig {messageExpiration = Just msgExp} = [expireMessages msgExp]
    expireMessagesThread_ _ = []

    expireMessages :: ExpirationConfig -> M ()
    expireMessages expCfg = do
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      let interval = checkInterval expCfg * 1000000
      stats <- asks serverStats
      labelMyThread "expireMessages"
      forever $ do
        liftIO $ threadDelay' interval
        old <- liftIO $ expireBeforeEpoch expCfg
        rIds <- M.keysSet <$> readTVarIO ms
        forM_ rIds $ \rId -> do
          q <- liftIO $ getMsgQueue ms rId quota
          deleted <- liftIO $ deleteExpiredMsgs q old
          liftIO $ atomicModifyIORef'_ (msgExpired stats) (+ deleted)

    serverStatsThread_ :: ServerConfig -> [M ()]
    serverStatsThread_ ServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      labelMyThread "logServerStats"
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1000000 * (initialDelay + if initialDelay < 0 then 86400 else 0)
      ss@ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedAllB, qDeletedNew, qDeletedSecured, qSub, qSubAllB, qSubAuth, qSubDuplicate, qSubProhibited, qSubEnd, qSubEndB, ntfCreated, ntfDeleted, ntfDeletedB, ntfSub, ntfSubB, ntfSubAuth, ntfSubDuplicate, msgSent, msgSentAuth, msgSentQuota, msgSentLarge, msgRecv, msgRecvGet, msgGet, msgGetNoMsg, msgGetAuth, msgGetDuplicate, msgGetProhibited, msgExpired, activeQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount, pRelays, pRelaysOwn, pMsgFwds, pMsgFwdsOwn, pMsgFwdsRecv}
        <- asks serverStats
      QueueStore {queues, notifiers} <- asks queueStore
      let interval = 1000000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomicSwapIORef fromTime ts
          qCreated' <- atomicSwapIORef qCreated 0
          qSecured' <- atomicSwapIORef qSecured 0
          qDeletedAll' <- atomicSwapIORef qDeletedAll 0
          qDeletedAllB' <- atomicSwapIORef qDeletedAllB 0
          qDeletedNew' <- atomicSwapIORef qDeletedNew 0
          qDeletedSecured' <- atomicSwapIORef qDeletedSecured 0
          qSub' <- atomicSwapIORef qSub 0
          qSubAllB' <- atomicSwapIORef qSubAllB 0
          qSubAuth' <- atomicSwapIORef qSubAuth 0
          qSubDuplicate' <- atomicSwapIORef qSubDuplicate 0
          qSubProhibited' <- atomicSwapIORef qSubProhibited 0
          qSubEnd' <- atomicSwapIORef qSubEnd 0
          qSubEndB' <- atomicSwapIORef qSubEndB 0
          ntfCreated' <- atomicSwapIORef ntfCreated 0
          ntfDeleted' <- atomicSwapIORef ntfDeleted 0
          ntfDeletedB' <- atomicSwapIORef ntfDeletedB 0
          ntfSub' <- atomicSwapIORef ntfSub 0
          ntfSubB' <- atomicSwapIORef ntfSubB 0
          ntfSubAuth' <- atomicSwapIORef ntfSubAuth 0
          ntfSubDuplicate' <- atomicSwapIORef ntfSubDuplicate 0
          msgSent' <- atomicSwapIORef msgSent 0
          msgSentAuth' <- atomicSwapIORef msgSentAuth 0
          msgSentQuota' <- atomicSwapIORef msgSentQuota 0
          msgSentLarge' <- atomicSwapIORef msgSentLarge 0
          msgRecv' <- atomicSwapIORef msgRecv 0
          msgRecvGet' <- atomicSwapIORef msgRecvGet 0
          msgGet' <- atomicSwapIORef msgGet 0
          msgGetNoMsg' <- atomicSwapIORef msgGetNoMsg 0
          msgGetAuth' <- atomicSwapIORef msgGetAuth 0
          msgGetDuplicate' <- atomicSwapIORef msgGetDuplicate 0
          msgGetProhibited' <- atomicSwapIORef msgGetProhibited 0
          msgExpired' <- atomicSwapIORef msgExpired 0
          ps <- liftIO $ periodStatCounts activeQueues ts
          msgSentNtf' <- atomicSwapIORef msgSentNtf 0
          msgRecvNtf' <- atomicSwapIORef msgRecvNtf 0
          psNtf <- liftIO $ periodStatCounts activeQueuesNtf ts
          msgNtfs' <- atomicSwapIORef (msgNtfs ss) 0
          msgNtfNoSub' <- atomicSwapIORef (msgNtfNoSub ss) 0
          msgNtfLost' <- atomicSwapIORef (msgNtfLost ss) 0
          pRelays' <- getResetProxyStatsData pRelays
          pRelaysOwn' <- getResetProxyStatsData pRelaysOwn
          pMsgFwds' <- getResetProxyStatsData pMsgFwds
          pMsgFwdsOwn' <- getResetProxyStatsData pMsgFwdsOwn
          pMsgFwdsRecv' <- atomicSwapIORef pMsgFwdsRecv 0
          qCount' <- readIORef qCount
          qCount'' <- M.size <$> readTVarIO queues
          ntfCount' <- M.size <$> readTVarIO notifiers
          msgCount' <- readIORef msgCount
          hPutStrLn h $
            intercalate
              ","
              ( [ iso8601Show $ utctDay fromTime',
                  show qCreated',
                  show qSecured',
                  show qDeletedAll',
                  show msgSent',
                  show msgRecv',
                  dayCount ps,
                  weekCount ps,
                  monthCount ps,
                  show msgSentNtf',
                  show msgRecvNtf',
                  dayCount psNtf,
                  weekCount psNtf,
                  monthCount psNtf,
                  show qCount',
                  show msgCount',
                  show msgExpired',
                  show qDeletedNew',
                  show qDeletedSecured'
                ]
                  <> showProxyStats pRelays'
                  <> showProxyStats pRelaysOwn'
                  <> showProxyStats pMsgFwds'
                  <> showProxyStats pMsgFwdsOwn'
                  <> [ show pMsgFwdsRecv',
                       show qSub',
                       show qSubAuth',
                       show qSubDuplicate',
                       show qSubProhibited',
                       show msgSentAuth',
                       show msgSentQuota',
                       show msgSentLarge',
                       show msgNtfs',
                       show msgNtfNoSub',
                       show msgNtfLost',
                       "0", -- qSubNoMsg' is removed for performance.
                       -- Use qSubAllB for the approximate number of all subscriptions.
                       -- Average observed batch size is 25-30 subscriptions.
                       show msgRecvGet',
                       show msgGet',
                       show msgGetNoMsg',
                       show msgGetAuth',
                       show msgGetDuplicate',
                       show msgGetProhibited',
                       "0", -- dayCount psSub; psSub is removed to reduce memory usage
                       "0", -- weekCount psSub
                       "0", -- monthCount psSub
                       show qCount'',
                       show ntfCreated',
                       show ntfDeleted',
                       show ntfSub',
                       show ntfSubAuth',
                       show ntfSubDuplicate',
                       show ntfCount',
                       show qDeletedAllB',
                       show qSubAllB',
                       show qSubEnd',
                       show qSubEndB',
                       show ntfDeletedB',
                       show ntfSubB'
                     ]
              )
        liftIO $ threadDelay' interval
      where
        showProxyStats ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther} =
          [show _pRequests, show _pSuccesses, show _pErrorsConnect, show _pErrorsCompat, show _pErrorsOther]

    runClient :: Transport c => C.APrivateSignKey -> TProxy c -> c -> M ()
    runClient signKey tp h = do
      kh <- asks serverIdentity
      ks <- atomically . C.generateKeyPair =<< asks random
      ServerConfig {smpServerVRange, smpHandshakeTimeout} <- asks config
      labelMyThread $ "smp handshake for " <> transportName tp
      liftIO (timeout smpHandshakeTimeout . runExceptT $ smpServerHandshake signKey h ks kh smpServerVRange) >>= \case
        Just (Right th) -> runClientTransport th
        _ -> pure ()

    controlPortThread_ :: ServerConfig -> [M ()]
    controlPortThread_ ServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M ()
    runCPServer port = do
      srv <- asks server
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runLocalTCPServer cpStarted port $ runCPClient u srv
      where
        runCPClient :: UnliftIO (ReaderT Env IO) -> Server -> Socket -> IO ()
        runCPClient u srv sock = do
          labelMyThread "control port client"
          h <- socketToHandle sock ReadWriteMode
          hSetBuffering h LineBuffering
          hSetNewlineMode h universalNewlineMode
          hPutStrLn h "SMP server control port\n'help' for supported commands"
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
                  newRole ServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin}
                    | Just auth == admin = CPRAdmin
                    | Just auth == user = CPRUser
                    | otherwise = CPRNone
              CPSuspend -> withAdminRole $ hPutStrLn h "suspend not implemented"
              CPResume -> withAdminRole $ hPutStrLn h "resume not implemented"
              CPClients -> withAdminRole $ do
                active <- unliftIO u (asks clients) >>= readTVarIO
                hPutStrLn h "clientId,sessionId,connected,createdAt,rcvActiveAt,sndActiveAt,age,subscriptions"
                forM_ (IM.toList active) $ \(cid, cl) -> forM_ cl $ \Client {sessionId, connected, createdAt, rcvActiveAt, sndActiveAt, subscriptions} -> do
                  connected' <- bshow <$> readTVarIO connected
                  rcvActiveAt' <- strEncode <$> readTVarIO rcvActiveAt
                  sndActiveAt' <- strEncode <$> readTVarIO sndActiveAt
                  now <- liftIO getSystemTime
                  let age = systemSeconds now - systemSeconds createdAt
                  subscriptions' <- bshow . M.size <$> readTVarIO subscriptions
                  hPutStrLn h . B.unpack $ B.intercalate "," [bshow cid, encode sessionId, connected', strEncode createdAt, rcvActiveAt', sndActiveAt', bshow age, subscriptions']
              CPStats -> withUserRole $ do
                ss <- unliftIO u $ asks serverStats
                let getStat :: (ServerStats -> IORef a) -> IO a
                    getStat var = readIORef (var ss)
                    putStat :: Show a => String -> (ServerStats -> IORef a) -> IO ()
                    putStat label var = getStat var >>= \v -> hPutStrLn h $ label <> ": " <> show v
                    putProxyStat :: String -> (ServerStats -> ProxyStats) -> IO ()
                    putProxyStat label var = do
                      ProxyStatsData {_pRequests, _pSuccesses, _pErrorsConnect, _pErrorsCompat, _pErrorsOther} <- getProxyStatsData $ var ss
                      hPutStrLn h $ label <> ": requests=" <> show _pRequests <> ", successes=" <> show _pSuccesses <> ", errorsConnect=" <> show _pErrorsConnect <> ", errorsCompat=" <> show _pErrorsCompat <> ", errorsOther=" <> show _pErrorsOther
                putStat "fromTime" fromTime
                putStat "qCreated" qCreated
                putStat "qSecured" qSecured
                putStat "qDeletedAll" qDeletedAll
                putStat "qDeletedAllB" qDeletedAllB
                putStat "qDeletedNew" qDeletedNew
                putStat "qDeletedSecured" qDeletedSecured
                getStat (day . activeQueues) >>= \v -> hPutStrLn h $ "daily active queues: " <> show (IS.size v)
                -- removed to reduce memory usage
                -- getStat (day . subscribedQueues) >>= \v -> hPutStrLn h $ "daily subscribed queues: " <> show (S.size v)
                putStat "qSub" qSub
                putStat "qSubAllB" qSubAllB
                putStat "qSubEnd" qSubEnd
                putStat "qSubEndB" qSubEndB
                subs <- (,,) <$> getStat qSubAuth <*> getStat qSubDuplicate <*> getStat qSubProhibited
                hPutStrLn h $ "other SUB events (auth, duplicate, prohibited): " <> show subs
                putStat "msgSent" msgSent
                putStat "msgRecv" msgRecv
                putStat "msgRecvGet" msgRecvGet
                putStat "msgGet" msgGet
                putStat "msgGetNoMsg" msgGet
                gets <- (,,) <$> getStat msgGetAuth <*> getStat msgGetDuplicate <*> getStat msgGetProhibited
                hPutStrLn h $ "other GET events (auth, duplicate, prohibited): " <> show gets
                putStat "msgSentNtf" msgSentNtf
                putStat "msgRecvNtf" msgRecvNtf
                putStat "qCount" qCount
                putStat "msgCount" msgCount
                putProxyStat "pRelays" pRelays
                putProxyStat "pRelaysOwn" pRelaysOwn
                putProxyStat "pMsgFwds" pMsgFwds
                putProxyStat "pMsgFwdsOwn" pMsgFwdsOwn
                putStat "pMsgFwdsRecv" pMsgFwdsRecv
              CPStatsRTS -> getRTSStats >>= hPrint h
              CPThreads -> withAdminRole $ do
#if MIN_VERSION_base(4,18,0)
                threads <- liftIO listThreads
                hPutStrLn h $ "Threads: " <> show (length threads)
                forM_ (sort threads) $ \tid -> do
                  label <- threadLabel tid
                  status <- threadStatus tid
                  hPutStrLn h $ show tid <> " (" <> show status <> ") " <> fromMaybe "" label
#else
                hPutStrLn h "Not available on GHC 8.10"
#endif
              CPSockets -> withUserRole $ do
                (accepted', closed', active') <- unliftIO u $ asks sockets
                (accepted, closed, active) <- (,,) <$> readTVarIO accepted' <*> readTVarIO closed' <*> readTVarIO active'
                hPutStrLn h "Sockets: "
                hPutStrLn h $ "accepted: " <> show accepted
                hPutStrLn h $ "closed: " <> show closed
                hPutStrLn h $ "active: " <> show (IM.size active)
                hPutStrLn h $ "leaked: " <> show (accepted - closed - IM.size active)
              CPSocketThreads -> withAdminRole $ do
#if MIN_VERSION_base(4,18,0)
                (_, _, active') <- unliftIO u $ asks sockets
                active <- readTVarIO active'
                forM_ (IM.toList active) $ \(sid, tid') ->
                  deRefWeak tid' >>= \case
                    Nothing -> hPutStrLn h $ intercalate "," [show sid, "", "gone", ""]
                    Just tid -> do
                      label <- threadLabel tid
                      status <- threadStatus tid
                      hPutStrLn h $ intercalate "," [show sid, show tid, show status, fromMaybe "" label]
#else
                hPutStrLn h "Not available on GHC 8.10"
#endif
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
                  Env {clients, server = Server {subscribers, notifiers}} <- unliftIO u ask
                  activeClients <- readTVarIO clients
                  hPutStrLn h $ "Clients: " <> show (IM.size activeClients)
                  when (r == CPRAdmin) $ do
                    clQs <- clientTBQueueLengths' activeClients
                    hPutStrLn h $ "Client queues (rcvQ, sndQ, msgQ): " <> show clQs
                    (smpSubCnt, smpSubCntByGroup, smpClCnt, smpClQs) <- countClientSubs subscriptions (Just countSMPSubs) activeClients
                    hPutStrLn h $ "SMP subscriptions (via clients): " <> show smpSubCnt
                    hPutStrLn h $ "SMP subscriptions (by group: NoSub, SubPending, SubThread, ProhibitSub): " <> show smpSubCntByGroup
                    hPutStrLn h $ "SMP subscribed clients (via clients): " <> show smpClCnt
                    hPutStrLn h $ "SMP subscribed clients queues (via clients, rcvQ, sndQ, msgQ): " <> show smpClQs
                    (ntfSubCnt, _, ntfClCnt, ntfClQs) <- countClientSubs ntfSubscriptions Nothing activeClients
                    hPutStrLn h $ "Ntf subscriptions (via clients): " <> show ntfSubCnt
                    hPutStrLn h $ "Ntf subscribed clients (via clients): " <> show ntfClCnt
                    hPutStrLn h $ "Ntf subscribed clients queues (via clients, rcvQ, sndQ, msgQ): " <> show ntfClQs
                  putActiveClientsInfo "SMP" subscribers
                  putActiveClientsInfo "Ntf" notifiers
                  where
                    putActiveClientsInfo :: String -> TMap QueueId (TVar Client) -> IO ()
                    putActiveClientsInfo protoName clients = do
                      activeSubs <- readTVarIO clients
                      hPutStrLn h $ protoName <> " subscriptions: " <> show (M.size activeSubs)
                      clCnt <- IS.size <$> countSubClients activeSubs
                      hPutStrLn h $ protoName <> " subscribed clients: " <> show clCnt
                      where
                        countSubClients :: M.Map QueueId (TVar Client) -> IO IS.IntSet
                        countSubClients = foldM (\ !s c -> (`IS.insert` s) . clientId <$> readTVarIO c) IS.empty
                    countClientSubs :: (Client -> TMap QueueId a) -> Maybe (M.Map QueueId a -> IO (Int, Int, Int, Int)) -> IM.IntMap (Maybe Client) -> IO (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural))
                    countClientSubs subSel countSubs_ = foldM addSubs (0, (0, 0, 0, 0), 0, (0, 0, 0))
                      where
                        addSubs :: (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural)) -> Maybe Client -> IO (Int, (Int, Int, Int, Int), Int, (Natural, Natural, Natural))
                        addSubs acc Nothing = pure acc
                        addSubs (!subCnt, cnts@(!c1, !c2, !c3, !c4), !clCnt, !qs) (Just cl) = do
                          subs <- readTVarIO $ subSel cl
                          cnts' <- case countSubs_ of
                            Nothing -> pure cnts
                            Just countSubs -> do
                              (c1', c2', c3', c4') <- countSubs subs
                              pure (c1 + c1', c2 + c2', c3 + c3', c4 + c4')
                          let cnt = M.size subs
                              clCnt' = if cnt == 0 then clCnt else clCnt + 1
                          qs' <- if cnt == 0 then pure qs else addQueueLengths qs cl
                          pure (subCnt + cnt, cnts', clCnt', qs')
                    clientTBQueueLengths' :: Foldable t => t (Maybe Client) -> IO (Natural, Natural, Natural)
                    clientTBQueueLengths' = foldM (\acc -> maybe (pure acc) (addQueueLengths acc)) (0, 0, 0)
                    addQueueLengths (!rl, !sl, !ml) cl = do
                      (rl', sl', ml') <- queueLengths cl
                      pure (rl + rl', sl + sl', ml + ml')
                    queueLengths Client {rcvQ, sndQ, msgQ} = do
                      rl <- atomically $ lengthTBQueue rcvQ
                      sl <- atomically $ lengthTBQueue sndQ
                      ml <- atomically $ lengthTBQueue msgQ
                      pure (rl, sl, ml)
                    countSMPSubs :: M.Map QueueId Sub -> IO (Int, Int, Int, Int)
                    countSMPSubs = foldM countSubs (0, 0, 0, 0)
                      where
                        countSubs (c1, c2, c3, c4) Sub {subThread} = case subThread of
                          ServerSub t -> do
                            st <- readTVarIO t
                            pure $ case st of
                              NoSub -> (c1 + 1, c2, c3, c4)
                              SubPending -> (c1, c2 + 1, c3, c4)
                              SubThread _ -> (c1, c2, c3 + 1, c4)
                          ProhibitSub -> pure (c1, c2, c3, c4 + 1)
              CPDelete queueId' -> withUserRole $ unliftIO u $ do
                st <- asks queueStore
                ms <- asks msgStore
                queueId <- liftIO (getQueue st SSender queueId') >>= \case
                  Left _ -> pure queueId' -- fallback to using as recipientId directly
                  Right QueueRec {recipientId} -> pure recipientId
                r <- liftIO $
                  deleteQueue st queueId $>>= \q ->
                    Right . (q,) <$> delMsgQueueSize ms queueId
                case r of
                  Left e -> liftIO . hPutStrLn h $ "error: " <> show e
                  Right (q, numDeleted) -> do
                    withLog (`logDeleteQueue` queueId)
                    updateDeletedStats q
                    liftIO . hPutStrLn h $ "ok, " <> show numDeleted <> " messages deleted"
              CPSave -> withAdminRole $ withLock' (savingLock srv) "control" $ do
                hPutStrLn h "saving server state..."
                unliftIO u $ saveServer True
                hPutStrLn h "server state saved!"
              CPHelp -> hPutStrLn h "commands: stats, stats-rts, clients, sockets, socket-threads, threads, server-info, delete, save, help, quit"
              CPQuit -> pure ()
              CPSkip -> pure ()
              where
                withUserRole action = readTVarIO role >>= \case
                  CPRAdmin -> action
                  CPRUser -> action
                  _ -> do
                    logError "Unauthorized control port command"
                    hPutStrLn h "AUTH"
                withAdminRole action = readTVarIO role >>= \case
                  CPRAdmin -> action
                  _ -> do
                    logError "Unauthorized control port command"
                    hPutStrLn h "AUTH"

runClientTransport :: Transport c => THandleSMP c 'TServer -> M ()
runClientTransport h@THandle {params = thParams@THandleParams {thVersion, sessionId}} = do
  q <- asks $ tbqSize . config
  ts <- liftIO getSystemTime
  active <- asks clients
  nextClientId <- asks clientSeq
  clientId <- atomically $ stateTVar nextClientId $ \next -> (next, next + 1)
  atomically $ modifyTVar' active $ IM.insert clientId Nothing
  c <- liftIO $ newClient clientId q thVersion sessionId ts
  runClientThreads active c clientId `finally` clientDisconnected c
  where
    runClientThreads active c clientId = do
      atomically $ modifyTVar' active $ IM.insert clientId $ Just c
      s <- asks server
      expCfg <- asks $ inactiveClientExpiration . config
      th <- newMVar h -- put TH under a fair lock to interleave messages and command responses
      labelMyThread . B.unpack $ "client $" <> encode sessionId
      raceAny_ $ [liftIO $ send th c, liftIO $ sendMsg th c, client thParams c s, receive h c] <> disconnectThread_ c expCfg
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport h (rcvActiveAt c) (sndActiveAt c) expCfg (noSubscriptions c)]
    disconnectThread_ _ _ = []
    noSubscriptions c = atomically $ (&&) <$> TM.null (ntfSubscriptions c) <*> (not . hasSubs <$> readTVar (subscriptions c))
    hasSubs = any $ (\case ServerSub _ -> True; ProhibitSub -> False) . subThread

clientDisconnected :: Client -> M ()
clientDisconnected c@Client {clientId, subscriptions, ntfSubscriptions, connected, sessionId, endThreads} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disc"
  -- these can be in separate transactions,
  -- because the client already disconnected and they won't change
  atomically $ writeTVar connected False
  subs <- atomically $ swapTVar subscriptions M.empty
  ntfSubs <- atomically $ swapTVar ntfSubscriptions M.empty
  liftIO $ mapM_ cancelSub subs
  Server {subscribers, notifiers} <- asks server
  liftIO $ updateSubscribers subs subscribers
  liftIO $ updateSubscribers ntfSubs notifiers
  asks clients >>= atomically . (`modifyTVar'` IM.delete clientId)
  tIds <- atomically $ swapTVar endThreads IM.empty
  liftIO $ mapM_ (mapM_ killThread <=< deRefWeak) tIds
  where
    updateSubscribers :: M.Map QueueId a -> TMap QueueId (TVar Client) -> IO ()
    updateSubscribers subs srvSubs =
      forM_ (M.keys subs) $ \qId ->
        -- lookup of the subscribed client TVar can be in separate transaction,
        -- as long as the client is read in the same transaction -
        -- it prevents removing the next subscribed client.
        TM.lookupIO qId srvSubs >>=
          mapM_ (\c' -> atomically $ whenM (sameClientId c <$> readTVar c') $ TM.delete qId srvSubs)

sameClientId :: Client -> Client -> Bool
sameClientId Client {clientId} Client {clientId = cId'} = clientId == cId'

cancelSub :: Sub -> IO ()
cancelSub s = case subThread s of
  ServerSub st ->
    readTVarIO st >>= \case
      SubThread t -> liftIO $ deRefWeak t >>= mapM_ killThread
      _ -> pure ()
  ProhibitSub -> pure ()

receive :: Transport c => THandleSMP c 'TServer -> Client -> M ()
receive h@THandle {params = THandleParams {thAuth}} Client {rcvQ, sndQ, rcvActiveAt, sessionId} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " receive"
  forever $ do
    ts <- L.toList <$> liftIO (tGet h)
    atomically . (writeTVar rcvActiveAt $!) =<< liftIO getSystemTime
    stats <- asks serverStats
    (errs, cmds) <- partitionEithers <$> mapM (cmdAction stats) ts
    updateBatchStats stats cmds
    write sndQ errs
    write rcvQ cmds
  where
    updateBatchStats :: ServerStats -> [(VerificationResult, Transmission Cmd)] -> M ()
    updateBatchStats stats = \case
      (_, (_, _, (Cmd _ cmd))) : _ -> do
        let sel_ = case cmd of
              SUB -> Just qSubAllB
              DEL -> Just qDeletedAllB
              NSUB -> Just ntfSubB
              NDEL -> Just ntfDeletedB
              _ -> Nothing
        mapM_ (\sel -> incStat $ sel stats) sel_
      [] -> pure ()
    cmdAction :: ServerStats -> SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) (VerificationResult, Transmission Cmd))
    cmdAction stats (tAuth, authorized, (corrId, entId, cmdOrError)) =
      case cmdOrError of
        Left e -> pure $ Left (corrId, entId, ERR e)
        Right cmd -> verified =<< verifyTransmission ((,C.cbNonce (bs corrId)) <$> thAuth) tAuth authorized entId cmd
          where
            verified = \case
              VRFailed -> do
                case cmd of
                  Cmd _ SEND {} -> incStat $ msgSentAuth stats
                  Cmd _ SUB -> incStat $ qSubAuth stats
                  Cmd _ NSUB -> incStat $ ntfSubAuth stats
                  Cmd _ GET -> incStat $ msgGetAuth stats
                  _ -> pure ()
                pure $ Left (corrId, entId, ERR AUTH)
              vRes -> pure $ Right (vRes, (corrId, entId, cmd))
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty

send :: Transport c => MVar (THandleSMP c 'TServer) -> Client -> IO ()
send th c@Client {sndQ, msgQ, sessionId} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " send"
  forever $ atomically (readTBQueue sndQ) >>= sendTransmissions
  where
    sendTransmissions :: NonEmpty (Transmission BrokerMsg) -> IO ()
    sendTransmissions ts
      | L.length ts <= 2 = tSend th c ts
      | otherwise = do
          let (msgs_, ts') = mapAccumR splitMessages [] ts
          -- If the request had batched subscriptions and L.length ts > 2
          -- this will reply OK to all SUBs in the first batched transmission,
          -- to reduce client timeouts.
          tSend th c ts'
          -- After that all messages will be sent in separate transmissions,
          -- without any client response timeouts, and allowing them to interleave
          -- with other requests responses.
          mapM_ (atomically . writeTBQueue msgQ) $ L.nonEmpty msgs_
      where
        splitMessages :: [Transmission BrokerMsg] -> Transmission BrokerMsg -> ([Transmission BrokerMsg], Transmission BrokerMsg)
        splitMessages msgs t@(corrId, entId, cmd) = case cmd of
          -- replace MSG response with OK, accumulating MSG in a separate list.
          MSG {} -> ((CorrId "", entId, cmd) : msgs, (corrId, entId, OK))
          _ -> (msgs, t)
        
sendMsg :: Transport c => MVar (THandleSMP c 'TServer) -> Client -> IO ()
sendMsg th c@Client {msgQ, sessionId} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " sendMsg"
  forever $ atomically (readTBQueue msgQ) >>= mapM_ (\t -> tSend th c [t])

tSend :: Transport c => MVar (THandleSMP c 'TServer) -> Client -> NonEmpty (Transmission BrokerMsg) -> IO ()
tSend th Client {sndActiveAt} ts = do
  withMVar th $ \h@THandle {params} ->
    void . tPut h $ L.map (\t -> Right (Nothing, encodeTransmission params t)) ts
  atomically . (writeTVar sndActiveAt $!) =<< liftIO getSystemTime

disconnectTransport :: Transport c => THandle v c 'TServer -> TVar SystemTime -> TVar SystemTime -> ExpirationConfig -> IO Bool -> IO ()
disconnectTransport THandle {connection, params = THandleParams {sessionId}} rcvActiveAt sndActiveAt expCfg noSubscriptions = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disconnectTransport"
  loop
  where
    loop = do
      threadDelay' $ checkInterval expCfg * 1000000
      ifM noSubscriptions checkExpired loop
    checkExpired = do
      old <- expireBeforeEpoch expCfg
      ts <- max <$> readTVarIO rcvActiveAt <*> readTVarIO sndActiveAt
      if systemSeconds ts < old then closeConnection connection else loop

-- This function verifies queue command authorization, with the objective to have constant time between the three AUTH error scenarios:
-- - the queue and party key exist, and the provided authorization has type matching queue key, but it is made with the different key.
-- - the queue and party key exist, but the provided authorization has incorrect type.
-- - the queue or party key do not exist.
-- In all cases, the time of the verification should depend only on the provided authorization type,
-- a dummy key is used to run verification in the last two cases, and failure is returned irrespective of the result.
verifyTransmission :: Maybe (THandleAuth 'TServer, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> QueueId -> Cmd -> M VerificationResult
verifyTransmission auth_ tAuth authorized entId cmd =
  case cmd of
    Cmd SRecipient (NEW k _ _ _ _) -> pure $ Nothing `verifiedWith` k
    Cmd SRecipient (WRT k _) -> (\d -> d `verifiedData` (verify k && maybe True ((k ==) . dataKey) d)) <$> getData entId
    Cmd SRecipient CLR -> maybe dummyVerify (\d -> Just d `verifiedData` verify (dataKey d)) <$> getData entId
    Cmd SRecipient _ -> verifyQueue (\q -> Just q `verifiedWith` recipientKey q) <$> get SRecipient
    -- SEND will be accepted without authorization before the queue is secured with KEY or SKEY command
    Cmd SSender (SKEY k) -> verifyQueue (\q -> Just q `verifiedWith` k) <$> get SSender
    Cmd SSender SEND {} -> verifyQueue (\q -> Just q `verified` maybe (isNothing tAuth) verify (senderKey q)) <$> get SSender
    Cmd SSender READ -> maybe VRFailed (VRVerifiedData . Just) <$> getData (EntityId $ C.sha256Hash $ unEntityId entId)
    Cmd SSender PING -> pure $ VRVerified Nothing
    Cmd SSender RFWD {} -> pure $ VRVerified Nothing
    -- NSUB will not be accepted without authorization
    Cmd SNotifier NSUB -> verifyQueue (\q -> maybe dummyVerify (\n -> Just q `verifiedWith` notifierKey n) (notifier q)) <$> get SNotifier
    Cmd SProxiedClient _ -> pure $ VRVerified Nothing
  where
    verify = verifyCmdAuthorization auth_ tAuth authorized
    dummyVerify = verify (dummyAuthKey tAuth) `seq` VRFailed
    verifyQueue :: (QueueRec -> VerificationResult) -> Either ErrorType QueueRec -> VerificationResult
    verifyQueue = either (const dummyVerify)
    verified q cond = if cond then VRVerified q else VRFailed
    verifiedWith q k = q `verified` verify k
    verifiedData d cond = if cond then VRVerifiedData d else VRFailed
    get :: DirectParty p => SParty p -> M (Either ErrorType QueueRec)
    get party = do
      st <- asks queueStore
      liftIO $ getQueue st party entId
    getData :: BlobId -> M (Maybe DataRec)
    getData blobId = atomically . TM.lookup blobId =<< asks dataStore

verifyCmdAuthorization :: Maybe (THandleAuth 'TServer, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> C.APublicAuthKey -> Bool
verifyCmdAuthorization auth_ tAuth authorized key = maybe False (verify key) tAuth
  where
    verify :: C.APublicAuthKey -> TransmissionAuth -> Bool
    verify (C.APublicAuthKey a k) = \case
      TASignature (C.ASignature a' s) -> case testEquality a a' of
        Just Refl -> C.verify' k s authorized
        _ -> C.verify' (dummySignKey a') s authorized `seq` False
      TAAuthenticator s -> case a of
        C.SX25519 -> verifyCmdAuth auth_ k s authorized
        _ -> verifyCmdAuth auth_ dummyKeyX25519 s authorized `seq` False

verifyCmdAuth :: Maybe (THandleAuth 'TServer, C.CbNonce) -> C.PublicKeyX25519 -> C.CbAuthenticator -> ByteString -> Bool
verifyCmdAuth auth_ k authenticator authorized = case auth_ of
  Just (THAuthServer {serverPrivKey = pk}, nonce) -> C.cbVerify k pk nonce authenticator authorized
  Nothing -> False

dummyVerifyCmd :: Maybe (THandleAuth 'TServer, C.CbNonce) -> ByteString -> TransmissionAuth -> Bool
dummyVerifyCmd auth_ authorized = \case
  TASignature (C.ASignature a s) -> C.verify' (dummySignKey a) s authorized
  TAAuthenticator s -> verifyCmdAuth auth_ dummyKeyX25519 s authorized

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummySignKey :: C.SignatureAlgorithm a => C.SAlgorithm a -> C.PublicKey a
dummySignKey = \case
  C.SEd25519 -> dummyKeyEd25519
  C.SEd448 -> dummyKeyEd448

dummyAuthKey :: Maybe TransmissionAuth -> C.APublicAuthKey
dummyAuthKey = \case
  Just (TASignature (C.ASignature a _)) -> case a of
    C.SEd25519 -> C.APublicAuthKey C.SEd25519 dummyKeyEd25519
    C.SEd448 -> C.APublicAuthKey C.SEd448 dummyKeyEd448
  _ -> C.APublicAuthKey C.SX25519 dummyKeyX25519

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

dummyKeyX25519 :: C.PublicKey 'C.X25519
dummyKeyX25519 = "MCowBQYDK2VuAyEA4JGSMYht18H4mas/jHeBwfcM7jLwNYJNOAhi2/g4RXg="

forkClient :: Client -> String -> M () -> M ()
forkClient Client {endThreads, endThreadSeq} label action = do
  tId <- atomically $ stateTVar endThreadSeq $ \next -> (next, next + 1)
  t <- forkIO $ do
    labelMyThread label
    action `finally` atomically (modifyTVar' endThreads $ IM.delete tId)
  mkWeakThreadId t >>= atomically . modifyTVar' endThreads . IM.insert tId

client :: THandleParams SMPVersion 'TServer -> Client -> Server -> M ()
client thParams' clnt@Client {clientId, subscriptions, ntfSubscriptions, rcvQ, sndQ, sessionId, procThreads} Server {subscribedQ, ntfSubscribedQ, subscribers, notifiers} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " commands"
  forever $
    atomically (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= mapM_ reply . L.nonEmpty . catMaybes . L.toList
  where
    reply :: MonadIO m => NonEmpty (Transmission BrokerMsg) -> m ()
    reply = atomically . writeTBQueue sndQ
    processProxiedCmd :: Transmission (Command 'ProxiedClient) -> M (Maybe (Transmission BrokerMsg))
    processProxiedCmd (corrId, EntityId sessId, command) = (corrId,EntityId sessId,) <$$> case command of
      PRXY srv auth -> ifM allowProxy getRelay (pure $ Just $ ERR $ PROXY BASIC_AUTH)
        where
          allowProxy = do
            ServerConfig {allowSMPProxy, newQueueBasicAuth} <- asks config
            pure $ allowSMPProxy && maybe True ((== auth) . Just) newQueueBasicAuth
          getRelay = do
            ProxyAgent {smpAgent = a} <- asks proxyAgent
            liftIO (getConnectedSMPServerClient a srv) >>= \case
              Just r -> Just <$> proxyServerResponse a r
              Nothing ->
                forkProxiedCmd $
                  liftIO (runExceptT (getSMPServerClient'' a srv) `catch` (pure . Left . PCEIOError))
                    >>= proxyServerResponse a
          proxyServerResponse :: SMPClientAgent -> Either SMPClientError (OwnServer, SMPClient) -> M BrokerMsg
          proxyServerResponse a smp_ = do
            ServerStats {pRelays, pRelaysOwn} <- asks serverStats
            let inc = mkIncProxyStats pRelays pRelaysOwn
            case smp_ of
              Right (own, smp) -> do
                inc own pRequests
                case proxyResp smp of
                  r@PKEY {} -> r <$ inc own pSuccesses
                  r -> r <$ inc own pErrorsCompat
              Left e -> do
                let own = isOwnServer a srv
                inc own pRequests
                inc own $ if temporaryClientError e then pErrorsConnect else pErrorsOther
                logWarn $ "Error connecting: " <> decodeLatin1 (strEncode $ host srv) <> " " <> tshow e
                pure . ERR $ smpProxyError e
            where
              proxyResp smp =
                let THandleParams {sessionId = srvSessId, thVersion, thServerVRange, thAuth} = thParams smp
                  in case compatibleVRange thServerVRange proxiedSMPRelayVRange of
                      -- Cap the destination relay version range to prevent client version fingerprinting.
                      -- See comment for proxiedSMPRelayVersion.
                      Just (Compatible vr) | thVersion >= sendingProxySMPVersion -> case thAuth of
                        Just THAuthClient {serverCertKey} -> PKEY srvSessId vr serverCertKey
                        Nothing -> ERR $ transportErr TENoServerAuth
                      _ -> ERR $ transportErr TEVersion
      PFWD fwdV pubKey encBlock -> do
        ProxyAgent {smpAgent = a} <- asks proxyAgent
        ServerStats {pMsgFwds, pMsgFwdsOwn} <- asks serverStats
        let inc = mkIncProxyStats pMsgFwds pMsgFwdsOwn
        liftIO (lookupSMPServerClient a sessId) >>= \case
          Just (own, smp) -> do
            inc own pRequests
            if v >= sendingProxySMPVersion
              then forkProxiedCmd $ do
                liftIO (runExceptT (forwardSMPTransmission smp corrId fwdV pubKey encBlock) `catch` (pure . Left . PCEIOError))  >>= \case
                  Right r -> PRES r <$ inc own pSuccesses
                  Left e -> ERR (smpProxyError e) <$ case e of
                    PCEProtocolError {} -> inc own pSuccesses
                    _ -> inc own pErrorsOther
              else Just (ERR $ transportErr TEVersion) <$ inc own pErrorsCompat
            where
              THandleParams {thVersion = v} = thParams smp
          Nothing -> inc False pRequests >> inc False pErrorsConnect $> Just (ERR $ PROXY NO_SESSION)
      where
        forkProxiedCmd :: M BrokerMsg -> M (Maybe BrokerMsg)
        forkProxiedCmd cmdAction = do
          bracket_ wait signal . forkClient clnt (B.unpack $ "client $" <> encode sessionId <> " proxy") $ do
            -- commands MUST be processed under a reasonable timeout or the client would halt
            cmdAction >>= \t -> reply [(corrId, EntityId sessId, t)]
          pure Nothing
          where
            wait = do
              ServerConfig {serverClientConcurrency} <- asks config
              atomically $ do
                used <- readTVar procThreads
                when (used >= serverClientConcurrency) retry
                writeTVar procThreads $! used + 1
            signal = atomically $ modifyTVar' procThreads (\t -> t - 1)
    transportErr :: TransportError -> ErrorType
    transportErr = PROXY . BROKER . TRANSPORT
    mkIncProxyStats :: MonadIO m => ProxyStats -> ProxyStats -> OwnServer -> (ProxyStats -> IORef Int) -> m ()
    mkIncProxyStats ps psOwn own sel = do
      incStat $ sel ps
      when own $ incStat $ sel psOwn
    processCommand :: (VerificationResult, Transmission Cmd) -> M (Maybe (Transmission BrokerMsg))
    processCommand (vRes, (corrId, entId, cmd)) = case cmd of
      Cmd SProxiedClient command -> processProxiedCmd (corrId, entId, command)
      Cmd SSender command -> Just <$> case command of
        SKEY sKey ->
          withQueue $ \QueueRec {sndSecure, recipientId} ->
            (corrId,entId,) <$> if sndSecure then secureQueue_ "SKEY" recipientId sKey else pure $ ERR AUTH
        SEND flags msgBody -> withQueue $ \qr -> sendMessage qr flags msgBody
        READ -> getDataBlob
        PING -> pure (corrId, NoEntity, PONG)
        RFWD encBlock -> (corrId, NoEntity,) <$> processForwardedCommand encBlock
      Cmd SNotifier NSUB -> Just <$> subscribeNotifications
      Cmd SRecipient command -> do
        st <- asks queueStore
        Just <$> case command of
          NEW rKey dhKey auth subMode sndSecure ->
            ifM
              allowNew
              (createQueue st rKey dhKey subMode sndSecure)
              (pure (corrId, entId, ERR AUTH))
            where
              allowNew = do
                ServerConfig {allowNewQueues, newQueueBasicAuth} <- asks config
                pure $ allowNewQueues && maybe True ((== auth) . Just) newQueueBasicAuth
          SUB -> withQueue (`subscribeQueue` entId)
          GET -> withQueue getMessage
          ACK msgId -> withQueue (`acknowledgeMsg` msgId)
          KEY sKey ->
            withQueue $ \QueueRec {recipientId} ->
              (corrId,entId,) <$> secureQueue_ "KEY" recipientId sKey
          NKEY nKey dhKey -> addQueueNotifier_ st nKey dhKey
          NDEL -> deleteQueueNotifier_ st
          OFF -> suspendQueue_ st
          DEL -> delQueueAndMsgs st
          QUE -> withQueue getQueueInfo
          WRT key blob -> storeDataBlob key blob
          CLR -> deleteDataBlob
      where
        createQueue :: QueueStore -> RcvPublicAuthKey -> RcvPublicDhKey -> SubscriptionMode -> SenderCanSecure -> M (Transmission BrokerMsg)
        createQueue st recipientKey dhKey subMode sndSecure = time "NEW" $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
          updatedAt <- Just <$> liftIO getSystemDate
          let rcvDhSecret = C.dh' dhKey privDhKey
              qik (rcvId, sndId) = QIK {rcvId, sndId, rcvPublicDhKey, sndSecure}
              qRec (recipientId, senderId) =
                QueueRec
                  { recipientId,
                    senderId,
                    recipientKey,
                    rcvDhSecret,
                    senderKey = Nothing,
                    notifier = Nothing,
                    status = QueueActive,
                    sndSecure,
                    updatedAt
                  }
          (corrId,entId,) <$> addQueueRetry 3 qik qRec
          where
            addQueueRetry ::
              Int -> ((RecipientId, SenderId) -> QueueIdsKeys) -> ((RecipientId, SenderId) -> QueueRec) -> M BrokerMsg
            addQueueRetry 0 _ _ = pure $ ERR INTERNAL
            addQueueRetry n qik qRec = do
              ids@(rId, _) <- getIds
              -- create QueueRec record with these ids and keys
              let qr = qRec ids
              liftIO (addQueue st qr) >>= \case
                Left DUPLICATE_ -> addQueueRetry (n - 1) qik qRec
                Left e -> pure $ ERR e
                Right () -> do
                  withLog (`logCreateQueue` qr)
                  stats <- asks serverStats
                  incStat $ qCreated stats
                  incStat $ qCount stats
                  case subMode of
                    SMOnlyCreate -> pure ()
                    SMSubscribe -> void $ subscribeQueue qr rId
                  pure $ IDS (qik ids)

            getIds :: M (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        secureQueue_ :: T.Text -> RecipientId -> SndPublicAuthKey -> M BrokerMsg
        secureQueue_ name rId sKey = time name $ do
          withLog $ \s -> logSecureQueue s rId sKey
          st <- asks queueStore
          stats <- asks serverStats
          incStat $ qSecured stats
          liftIO $ either ERR (const OK) <$> secureQueue st rId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicAuthKey -> RcvNtfPublicDhKey -> M (Transmission BrokerMsg)
        addQueueNotifier_ st notifierKey dhKey = time "NKEY" $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
          let rcvNtfDhSecret = C.dh' dhKey privDhKey
          (corrId,entId,) <$> addNotifierRetry 3 rcvPublicDhKey rcvNtfDhSecret
          where
            addNotifierRetry :: Int -> RcvNtfPublicDhKey -> RcvNtfDhSecret -> M BrokerMsg
            addNotifierRetry 0 _ _ = pure $ ERR INTERNAL
            addNotifierRetry n rcvPublicDhKey rcvNtfDhSecret = do
              notifierId <- randomId =<< asks (queueIdBytes . config)
              let ntfCreds = NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}
              liftIO (addQueueNotifier st entId ntfCreds) >>= \case
                Left DUPLICATE_ -> addNotifierRetry (n - 1) rcvPublicDhKey rcvNtfDhSecret
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s entId ntfCreds
                  incStat . ntfCreated =<< asks serverStats
                  pure $ NID notifierId rcvPublicDhKey

        deleteQueueNotifier_ :: QueueStore -> M (Transmission BrokerMsg)
        deleteQueueNotifier_ st = do
          withLog (`logDeleteNotifier` entId)
          liftIO (deleteQueueNotifier st entId) >>= \case
            Right () -> do
              -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
              atomically $ writeTQueue ntfSubscribedQ (entId, clientId, False)
              incStat . ntfDeleted =<< asks serverStats
              pure ok
            Left e -> pure $ err e

        suspendQueue_ :: QueueStore -> M (Transmission BrokerMsg)
        suspendQueue_ st = do
          withLog (`logSuspendQueue` entId)
          okResp <$> liftIO (suspendQueue st entId)

        subscribeQueue :: QueueRec -> RecipientId -> M (Transmission BrokerMsg)
        subscribeQueue qr rId = do
          atomically (TM.lookup rId subscriptions) >>= \case
            Nothing -> newSub >>= deliver True
            Just s@Sub {subThread} -> do
              stats <- asks serverStats
              case subThread of
                ProhibitSub -> do
                  -- cannot use SUB in the same connection where GET was used
                  incStat $ qSubProhibited stats
                  pure (corrId, rId, ERR $ CMD PROHIBITED)
                _ -> do
                  incStat $ qSubDuplicate stats
                  atomically (tryTakeTMVar $ delivered s) >> deliver False s
          where
            newSub :: M Sub
            newSub = time "SUB newSub" . atomically $ do
              writeTQueue subscribedQ (rId, clientId, True)
              sub <- newSubscription NoSub
              TM.insert rId sub subscriptions
              pure sub
            deliver :: Bool -> Sub -> M (Transmission BrokerMsg)
            deliver inc sub = do
              q <- getStoreMsgQueue "SUB" rId
              msg_ <- liftIO $ tryPeekMsgIO q
              when (inc && isJust msg_) $
                incStat . qSub =<< asks serverStats
              deliverMessage "SUB" qr rId sub msg_

        -- clients that use GET are not added to server subscribers
        getMessage :: QueueRec -> M (Transmission BrokerMsg)
        getMessage qr = time "GET" $ do
          atomically (TM.lookup entId subscriptions) >>= \case
            Nothing ->
              atomically newSub >>= (`getMessage_` Nothing)
            Just s@Sub {subThread} ->
              case subThread of
                ProhibitSub ->
                  atomically (tryTakeTMVar $ delivered s)
                    >>= getMessage_ s
                -- cannot use GET in the same connection where there is an active subscription
                _ -> do
                  stats <- asks serverStats
                  incStat $ msgGetProhibited stats
                  pure (corrId, entId, ERR $ CMD PROHIBITED)
          where
            newSub :: STM Sub
            newSub = do
              s <- newProhibitedSub
              TM.insert entId s subscriptions
              pure s
            getMessage_ :: Sub -> Maybe MsgId -> M (Transmission BrokerMsg)
            getMessage_ s delivered_ = do
              q <- getStoreMsgQueue "GET" entId
              stats <- asks serverStats
              (statCnt, r) <-
                -- TODO split STM, use tryPeekMsgIO
                atomically $
                  tryPeekMsg q >>= \case
                    Just msg ->
                      let encMsg = encryptMsg qr msg
                          cnt = if isJust delivered_ then msgGetDuplicate else msgGet
                       in setDelivered s msg $> (cnt, (corrId, entId, MSG encMsg))
                    _ -> pure (msgGetNoMsg, (corrId, entId, OK))
              incStat $ statCnt stats
              pure r

        withQueue :: (QueueRec -> M (Transmission BrokerMsg)) -> M (Transmission BrokerMsg)
        withQueue action = case vRes of
          VRVerified (Just qr) -> updateQueueDate qr >> action qr
          _ -> pure $ err INTERNAL

        updateQueueDate :: QueueRec -> M ()
        updateQueueDate QueueRec {updatedAt, recipientId = rId} = do
          t <- liftIO getSystemDate
          when (Just t /= updatedAt) $ do
            withLog $ \s -> logUpdateQueueTime s rId t
            st <- asks queueStore
            liftIO $ updateQueueTime st rId t 

        subscribeNotifications :: M (Transmission BrokerMsg)
        subscribeNotifications = do
          statCount <-
            time "NSUB" . atomically $ do
              ifM
                (TM.member entId ntfSubscriptions)
                (pure ntfSubDuplicate)
                (newSub $> ntfSub)
          incStat . statCount =<< asks serverStats
          pure ok
          where
            newSub = do
              writeTQueue ntfSubscribedQ (entId, clientId, True)
              TM.insert entId () ntfSubscriptions

        acknowledgeMsg :: QueueRec -> MsgId -> M (Transmission BrokerMsg)
        acknowledgeMsg qr msgId = time "ACK" $ do
          liftIO (TM.lookupIO entId subscriptions) >>= \case
            Nothing -> pure $ err NO_MSG
            Just sub ->
              atomically (getDelivered sub) >>= \case
                Just st -> do
                  q <- getStoreMsgQueue "ACK" entId
                  case st of
                    ProhibitSub -> do
                      deletedMsg_ <- liftIO $ tryDelMsg q msgId
                      mapM_ (updateStats True) deletedMsg_
                      pure ok
                    _ -> do
                      (deletedMsg_, msg_) <- liftIO $ tryDelPeekMsg q msgId
                      mapM_ (updateStats False) deletedMsg_
                      deliverMessage "ACK" qr entId sub msg_
                _ -> pure $ err NO_MSG
          where
            getDelivered :: Sub -> STM (Maybe ServerSub)
            getDelivered Sub {delivered, subThread} = do
              tryTakeTMVar delivered $>>= \msgId' ->
                if msgId == msgId' || B.null msgId
                  then pure $ Just subThread
                  else putTMVar delivered msgId' $> Nothing
            updateStats :: Bool -> Message -> M ()
            updateStats isGet = \case
              MessageQuota {} -> pure ()
              Message {msgFlags} -> do
                stats <- asks serverStats
                incStat $ msgRecv stats
                when isGet $ incStat $ msgRecvGet stats
                liftIO $ atomicModifyIORef'_ (msgCount stats) (subtract 1)
                liftIO $ updatePeriodStats (activeQueues stats) entId
                when (notification msgFlags) $ do
                  incStat $ msgRecvNtf stats
                  liftIO $ updatePeriodStats (activeQueuesNtf stats) entId

        sendMessage :: QueueRec -> MsgFlags -> MsgBody -> M (Transmission BrokerMsg)
        sendMessage qr msgFlags msgBody
          | B.length msgBody > maxMessageLength thVersion = do
              stats <- asks serverStats
              incStat $ msgSentLarge stats
              pure $ err LARGE_MSG
          | otherwise = do
              stats <- asks serverStats
              case status qr of
                QueueOff -> do
                  incStat $ msgSentAuth stats
                  pure $ err AUTH
                QueueActive ->
                  case C.maxLenBS msgBody of
                    Left _ -> pure $ err LARGE_MSG
                    Right body -> do
                      msg_ <- time "SEND" $ do
                        q <- getStoreMsgQueue "SEND" $ recipientId qr
                        expireMessages q
                        liftIO . writeMsg q =<< mkMessage body
                      case msg_ of
                        Nothing -> do
                          incStat $ msgSentQuota stats
                          pure $ err QUOTA
                        Just (msg, wasEmpty) -> time "SEND ok" $ do
                          when wasEmpty $ liftIO $ tryDeliverMessage msg
                          when (notification msgFlags) $ do
                            mapM_ (`trySendNotification` msg) (notifier qr)
                            incStat $ msgSentNtf stats
                            liftIO $ updatePeriodStats (activeQueuesNtf stats) (recipientId qr)
                          incStat $ msgSent stats
                          incStat $ msgCount stats
                          liftIO $ updatePeriodStats (activeQueues stats) (recipientId qr)
                          pure ok
          where
            THandleParams {thVersion} = thParams'
            mkMessage :: C.MaxLenBS MaxMessageLen -> M Message
            mkMessage body = do
              msgId <- randomId' =<< asks (msgIdBytes . config)
              msgTs <- liftIO getSystemTime
              pure $! Message msgId msgTs msgFlags body

            expireMessages :: MsgQueue -> M ()
            expireMessages q = do
              msgExp <- asks $ messageExpiration . config
              old <- liftIO $ mapM expireBeforeEpoch msgExp
              deleted <- liftIO $ sum <$> mapM (deleteExpiredMsgs q) old
              when (deleted > 0) $ do
                stats <- asks serverStats
                liftIO $ atomicModifyIORef'_ (msgExpired stats) (+ deleted)

            -- The condition for delivery of the message is:
            -- - the queue was empty when the message was sent,
            -- - there is subscribed recipient,
            -- - no message was "delivered" that was not acknowledged.
            -- If the send queue of the subscribed client is not full the message is put there in the same transaction.
            -- If the queue is not full, then the thread is created where these checks are made:
            -- - it is the same subscribed client (in case it was reconnected it would receive message via SUB command)
            -- - nothing was delivered to this subscription (to avoid race conditions with the recipient).
            tryDeliverMessage :: Message -> IO ()
            tryDeliverMessage msg =
              -- the subscription is checked outside of STM to avoid transaction cost
              -- in case no client is subscribed.
              whenM (TM.memberIO rId subscribers) $
                atomically deliverToSub >>= mapM_ forkDeliver
              where
                rId = recipientId qr
                -- remove tryPeekMsg
                deliverToSub =
                  -- lookup has ot be in the same transaction,
                  -- so that if subscription ends, it re-evalutates
                  -- and delivery is cancelled -
                  -- the new client will receive message in response to SUB.
                  (TM.lookup rId subscribers >>= mapM readTVar)
                    $>>= \rc@Client {subscriptions = subs, sndQ = q} -> TM.lookup rId subs
                    $>>= \s@Sub {subThread, delivered} -> case subThread of
                      ProhibitSub -> pure Nothing
                      ServerSub st -> readTVar st >>= \case
                        NoSub ->
                          tryTakeTMVar delivered >>= \case
                            Just _ -> pure Nothing -- if a message was already delivered, should not deliver more
                            Nothing ->
                              ifM
                                (isFullTBQueue q)
                                (writeTVar st SubPending $> Just (rc, s, st))
                                (deliver q s $> Nothing)
                        _ -> pure Nothing
                deliver q s = do
                  let encMsg = encryptMsg qr msg
                  writeTBQueue q [(CorrId "", rId, MSG encMsg)]
                  void $ setDelivered s msg
                forkDeliver (rc@Client {sndQ = q}, s@Sub {delivered}, st) = do
                  t <- mkWeakThreadId =<< forkIO deliverThread
                  atomically $ modifyTVar' st $ \case
                    -- this case is needed because deliverThread can exit before it
                    SubPending -> SubThread t
                    st' -> st'
                  where
                    deliverThread = do
                      labelMyThread $ B.unpack ("client $" <> encode sessionId) <> " deliver/SEND"
                      -- lookup can be outside of STM transaction,
                      -- as long as the check that it is the same client is inside.
                      TM.lookupIO rId subscribers >>= mapM_ deliverIfSame
                    deliverIfSame rc' = time "deliver" . atomically $
                      whenM (sameClientId rc <$> readTVar rc') $
                        tryTakeTMVar delivered >>= \case
                          Just _ -> pure () -- if a message was already delivered, should not deliver more
                          Nothing -> do
                            -- a separate thread is needed because it blocks when client sndQ is full.
                            deliver q s
                            writeTVar st NoSub

            trySendNotification :: NtfCreds -> Message -> M ()
            trySendNotification NtfCreds {notifierId, rcvNtfDhSecret} msg = do
              stats <- asks serverStats
              liftIO (TM.lookupIO notifierId notifiers) >>= \case
                Nothing -> do
                  incStat $ msgNtfNoSub stats
                  logWarn "No notification subscription"
                Just ntfClnt -> do
                  let updateStats True = incStat $ msgNtfs stats
                      updateStats _ = do
                        incStat $ msgNtfLost stats
                        logWarn "Dropped message notification"
                  writeNtf notifierId msg rcvNtfDhSecret ntfClnt >>= mapM_ updateStats

            writeNtf :: NotifierId -> Message -> RcvNtfDhSecret -> TVar Client -> M (Maybe Bool)
            writeNtf nId msg rcvNtfDhSecret ntfClnt = case msg of
              Message {msgId, msgTs} -> Just <$> do
                (nmsgNonce, encNMsgMeta) <- mkMessageNotification msgId msgTs rcvNtfDhSecret
                -- must be in one STM transaction to avoid the queue becoming full between the check and writing
                atomically $ do
                  Client {sndQ = q} <- readTVar ntfClnt
                  ifM
                    (isFullTBQueue q)
                    (pure $ False)
                    (True <$ writeTBQueue q [(CorrId "", nId, NMSG nmsgNonce encNMsgMeta)])
              _ -> pure Nothing

            mkMessageNotification :: ByteString -> SystemTime -> RcvNtfDhSecret -> M (C.CbNonce, EncNMsgMeta)
            mkMessageNotification msgId msgTs rcvNtfDhSecret = do
              cbNonce <- atomically . C.randomCbNonce =<< asks random
              let msgMeta = NMsgMeta {msgId, msgTs}
                  encNMsgMeta = C.cbEncrypt rcvNtfDhSecret cbNonce (smpEncode msgMeta) 128
              pure . (cbNonce,) $ fromRight "" encNMsgMeta

        processForwardedCommand :: EncFwdTransmission -> M BrokerMsg
        processForwardedCommand (EncFwdTransmission s) = fmap (either ERR id) . runExceptT $ do
          THAuthServer {serverPrivKey, sessSecret'} <- maybe (throwE $ transportErr TENoServerAuth) pure (thAuth thParams')
          sessSecret <- maybe (throwE $ transportErr TENoServerAuth) pure sessSecret'
          let proxyNonce = C.cbNonce $ bs corrId
          s' <- liftEitherWith (const CRYPTO) $ C.cbDecryptNoPad sessSecret proxyNonce s
          FwdTransmission {fwdCorrId, fwdVersion, fwdKey, fwdTransmission = EncTransmission et} <- liftEitherWith (const $ CMD SYNTAX) $ smpDecode s'
          let clientSecret = C.dh' fwdKey serverPrivKey
              clientNonce = C.cbNonce $ bs fwdCorrId
          b <- liftEitherWith (const CRYPTO) $ C.cbDecrypt clientSecret clientNonce et
          let clntTHParams = smpTHParamsSetVersion fwdVersion thParams'
          -- only allowing single forwarded transactions
          t' <- case tParse clntTHParams b of
            t :| [] -> pure $ tDecodeParseValidate clntTHParams t
            _ -> throwE BLOCK
          let clntThAuth = Just $ THAuthServer {serverPrivKey, sessSecret' = Just clientSecret}
          -- process forwarded command
          r <-
            lift (rejectOrVerify clntThAuth t') >>= \case
              Left r -> pure r
              -- rejectOrVerify filters allowed commands, no need to repeat it here.
              -- INTERNAL is used because processCommand never returns Nothing for sender commands (could be extracted for better types).
              Right t''@(_, (corrId', entId', _)) -> fromMaybe (corrId', entId', ERR INTERNAL) <$> lift (processCommand t'')
          -- encode response
          r' <- case batchTransmissions (batch clntTHParams) (blockSize clntTHParams) [Right (Nothing, encodeTransmission clntTHParams r)] of
            [] -> throwE INTERNAL -- at least 1 item is guaranteed from NonEmpty/Right
            TBError _ _ : _ -> throwE BLOCK
            TBTransmission b' _ : _ -> pure b'
            TBTransmissions b' _ _ : _ -> pure b'
          -- encrypt to client
          r2 <- liftEitherWith (const BLOCK) $ EncResponse <$> C.cbEncrypt clientSecret (C.reverseNonce clientNonce) r' paddedProxiedTLength
          -- encrypt to proxy
          let fr = FwdResponse {fwdCorrId, fwdResponse = r2}
              r3 = EncFwdResponse $ C.cbEncryptNoPad sessSecret (C.reverseNonce proxyNonce) (smpEncode fr)
          stats <- asks serverStats
          incStat $ pMsgFwdsRecv stats
          pure $ RRES r3
          where
            rejectOrVerify :: Maybe (THandleAuth 'TServer) -> SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) (VerificationResult, Transmission Cmd))
            rejectOrVerify clntThAuth (tAuth, authorized, (corrId', entId', cmdOrError)) =
              case cmdOrError of
                Left e -> pure $ Left (corrId', entId', ERR e)
                Right cmd'
                  | allowed -> verified <$> verifyTransmission ((,C.cbNonce (bs corrId')) <$> clntThAuth) tAuth authorized entId' cmd'
                  | otherwise -> pure $ Left (corrId', entId', ERR $ CMD PROHIBITED)
                  where
                    allowed = case cmd' of
                      Cmd SSender SEND {} -> True
                      Cmd SSender (SKEY _) -> True
                      Cmd SSender READ -> True
                      _ -> False
                    verified = \case
                      VRFailed -> Left (corrId', entId', ERR AUTH)
                      vRes' -> Right (vRes', (corrId', entId', cmd'))

        deliverMessage :: T.Text -> QueueRec -> RecipientId -> Sub -> Maybe Message -> M (Transmission BrokerMsg)
        deliverMessage name qr rId s@Sub {subThread} msg_ = time (name <> " deliver") . atomically $
          case subThread of
            ProhibitSub -> pure resp
            _ -> case msg_ of
              Just msg ->
                let encMsg = encryptMsg qr msg
                 in setDelivered s msg $> (corrId, rId, MSG encMsg)
              _ -> pure resp
          where
            resp = (corrId, rId, OK)

        time :: MonadIO m => T.Text -> m a -> m a
        time name = timed name entId

        encryptMsg :: QueueRec -> Message -> RcvMessage
        encryptMsg qr msg = encrypt . encodeRcvMsgBody $ case msg of
          Message {msgFlags, msgBody} -> RcvMsgBody {msgTs = msgTs', msgFlags, msgBody}
          MessageQuota {} -> RcvMsgQuota msgTs'
          where
            encrypt :: KnownNat i => C.MaxLenBS i -> RcvMessage
            encrypt body = RcvMessage msgId' . EncRcvMsgBody $ C.cbEncryptMaxLenBS (rcvDhSecret qr) (C.cbNonce msgId') body
            msgId' = messageId msg
            msgTs' = messageTs msg

        setDelivered :: Sub -> Message -> STM Bool
        setDelivered s msg = tryPutTMVar (delivered s) $! messageId msg

        getStoreMsgQueue :: T.Text -> RecipientId -> M MsgQueue
        getStoreMsgQueue name rId = time (name <> " getMsgQueue") $ do
          ms <- asks msgStore
          quota <- asks $ msgQueueQuota . config
          liftIO $ getMsgQueue ms rId quota

        delQueueAndMsgs :: QueueStore -> M (Transmission BrokerMsg)
        delQueueAndMsgs st = do
          withLog (`logDeleteQueue` entId)
          ms <- asks msgStore
          liftIO (deleteQueue st entId $>>= \q -> delMsgQueue ms entId $> Right q) >>= \case
            Right q -> do
              -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
              atomically $ writeTQueue subscribedQ (entId, clientId, False)
              forM_ (notifierId <$> notifier q) $ \nId ->
                atomically $ writeTQueue ntfSubscribedQ (nId, clientId, False)
              updateDeletedStats q
              pure ok
            Left e -> pure $ err e

        getQueueInfo :: QueueRec -> M (Transmission BrokerMsg)
        getQueueInfo QueueRec {senderKey, notifier} = do
          q <- getStoreMsgQueue "getQueueInfo" entId
          qiSub <- liftIO $ TM.lookupIO entId subscriptions >>= mapM mkQSub
          qiSize <- liftIO $ getQueueSize q
          qiMsg <- liftIO $ toMsgInfo <$$> tryPeekMsgIO q
          let info = QueueInfo {qiSnd = isJust senderKey, qiNtf = isJust notifier, qiSub, qiSize, qiMsg}
          pure (corrId, entId, INFO info)
          where
            mkQSub Sub {subThread, delivered} = do
              qSubThread <- case subThread of
                ServerSub t -> do
                  st <- readTVarIO t
                  pure $ case st of
                    NoSub -> QNoSub
                    SubPending -> QSubPending
                    SubThread _ -> QSubThread
                ProhibitSub -> pure QProhibitSub
              qDelivered <- atomically $ decodeLatin1 . encode <$$> tryReadTMVar delivered
              pure QSub {qSubThread, qDelivered}

        storeDataBlob :: DataPublicAuthKey -> DataBlob -> M (Transmission BrokerMsg)
        storeDataBlob dataKey dataBlob
          | B.length (dataBody dataBlob) > e2eEncMessageLength = pure $ err LARGE_MSG
          | otherwise = do
              atomically . TM.insert entId d =<< asks dataStore
              withLog' dataLog (`logCreateBlob` d)
              pure ok
          where
            d = DataRec {dataId = entId, dataKey, dataBlob}

        deleteDataBlob :: M (Transmission BrokerMsg)
        deleteDataBlob = do
          atomically . TM.delete entId =<< asks dataStore
          withLog' dataLog (`logDeleteBlob` entId)
          pure ok

        getDataBlob :: M (Transmission BrokerMsg)
        getDataBlob = case vRes of
          VRVerifiedData (Just DataRec {dataBlob}) -> 
            case thAuth thParams' of
              Nothing -> pure $ err $ transportErr TENoServerAuth
              Just THAuthServer {serverPrivKey} -> case X25519.publicKey $ unEntityId entId of
                CE.CryptoFailed _ -> pure $ err AUTH
                CE.CryptoPassed k -> do
                  let secret = C.dh' (C.PublicKeyX25519 k) serverPrivKey
                      nonce = C.cbNonce $ bs corrId
                      THandleParams {thVersion} = thParams'
                  pure . (corrId,entId,) $
                    case C.cbEncrypt secret nonce (smpEncode dataBlob) (maxMessageLength thVersion) of
                      Left _ -> ERR CRYPTO
                      Right encBlob -> DATA encBlob
          _ -> pure $ err INTERNAL

        ok :: Transmission BrokerMsg
        ok = (corrId, entId, OK)

        err :: ErrorType -> Transmission BrokerMsg
        err e = (corrId, entId, ERR e)

        okResp :: Either ErrorType () -> Transmission BrokerMsg
        okResp = either err $ const ok

updateDeletedStats :: QueueRec -> M ()
updateDeletedStats q = do
  stats <- asks serverStats
  let delSel = if isNothing (senderKey q) then qDeletedNew else qDeletedSecured
  incStat $ delSel stats
  incStat $ qDeletedAll stats
  incStat $ qCount stats

incStat :: MonadIO m => IORef Int -> m ()
incStat r = liftIO $ atomicModifyIORef'_ r (+ 1)
{-# INLINE incStat #-}

withLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withLog = withLog' storeLog
{-# INLINE withLog #-}

withLog' :: (Env -> Maybe (StoreLog 'WriteMode)) -> (StoreLog 'WriteMode -> IO a) -> M ()
withLog' sel action = liftIO . mapM_ action =<< asks sel

timed :: MonadIO m => T.Text -> RecipientId -> m a -> m a
timed name (EntityId qId) a = do
  t <- liftIO getSystemTime
  r <- a
  t' <- liftIO getSystemTime
  let int = diff t t'
  when (int > sec) . logDebug $ T.unwords [name, tshow $ encode qId, tshow int]
  pure r
  where
    diff t t' = (systemSeconds t' - systemSeconds t) * sec + fromIntegral (systemNanoseconds t' - systemNanoseconds t)
    sec = 1000_000000

randomId' :: Int -> M ByteString
randomId' n = atomically . C.randomBytes n =<< asks random

randomId :: Int -> M EntityId
randomId = fmap EntityId . randomId'
{-# INLINE randomId #-}

saveServerMessages :: Bool -> M ()
saveServerMessages keepMsgs = asks (storeMsgsFile . config) >>= mapM_ saveMessages
  where
    saveMessages f = do
      logInfo $ "saving messages to file " <> T.pack f
      ms <- asks msgStore
      liftIO . withFile f WriteMode $ \h ->
        readTVarIO ms >>= mapM_ (saveQueueMsgs h) . M.assocs
      logInfo "messages saved"
      where
        saveQueueMsgs h (rId, q) = BLD.hPutBuilder h . encodeMessages rId =<< atomically (getMessages $ msgQueue q)
        getMessages = if keepMsgs then snapshotTQueue else flushTQueue
        snapshotTQueue q = do
          msgs <- flushTQueue q
          mapM_ (writeTQueue q) msgs
          pure msgs
        encodeMessages rId = mconcat . map (\msg -> BLD.byteString (strEncode $ MLRv3 rId msg) <> BLD.char8 '\n')

restoreServerMessages :: M Int
restoreServerMessages =
  asks (storeMsgsFile . config) >>= \case
    Just f -> ifM (doesFileExist f) (restoreMessages f) (pure 0)
    Nothing -> pure 0
  where
    restoreMessages f = do
      logInfo $ "restoring messages from file " <> T.pack f
      ms <- asks msgStore
      quota <- asks $ msgQueueQuota . config
      old_ <- asks (messageExpiration . config) $>>= (liftIO . fmap Just . expireBeforeEpoch)
      runExceptT (liftIO (LB.readFile f) >>= foldM (\expired -> restoreMsg expired ms quota old_) 0 . LB.lines) >>= \case
        Left e -> do
          logError . T.pack $ "error restoring messages: " <> e
          liftIO exitFailure
        Right expired -> do
          renameFile f $ f <> ".bak"
          logInfo "messages restored"
          pure expired
      where
        restoreMsg !expired ms quota old_ s' = do
          MLRv3 rId msg <- liftEither . first (msgErr "parsing") $ strDecode s
          addToMsgQueue rId msg
          where
            s = LB.toStrict s'
            addToMsgQueue rId msg = do
              q <- liftIO $ getMsgQueue ms rId quota
              (isExpired, logFull) <- liftIO $ case msg of
                Message {msgTs}
                  | maybe True (systemSeconds msgTs >=) old_ -> (False,) . isNothing <$> writeMsg q msg
                  | otherwise -> pure (True, False)
                MessageQuota {} -> writeMsg q msg $> (False, False)
              when logFull . logError . decodeLatin1 $ "message queue " <> strEncode rId <> " is full, message not restored: " <> strEncode (messageId msg)
              pure $ if isExpired then expired + 1 else expired
            msgErr :: Show e => String -> e -> String
            msgErr op e = op <> " error (" <> show e <> "): " <> B.unpack (B.take 100 s)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= liftIO . getServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: Int -> M ()
restoreServerStats expiredWhileRestoring = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d@ServerStatsData {_qCount = statsQCount} -> do
          s <- asks serverStats
          _qCount <- fmap M.size . readTVarIO . queues =<< asks queueStore
          _msgCount <- liftIO . foldM (\(!n) q -> (n +) <$> getQueueSize q) 0 =<< readTVarIO =<< asks msgStore
          liftIO $ setServerStats s d {_qCount, _msgCount, _msgExpired = _msgExpired d + expiredWhileRestoring}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
          when (_qCount /= statsQCount) $ logWarn $ "Queue count differs: stats: " <> tshow statsQCount <> ", store: " <> tshow _qCount
          logInfo $ "Restored " <> tshow _msgCount <> " messages in " <> tshow _qCount <> " queues"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
