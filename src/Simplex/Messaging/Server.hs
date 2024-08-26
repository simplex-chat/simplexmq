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
import Crypto.Random
import Control.Monad.STM (retry)
import Data.Bifunctor (first)
import Data.ByteString.Base64 (encode)
import qualified Data.ByteString.Builder as BLD
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (fromRight, partitionEithers, rights)
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (intercalate, mapAccumR)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality
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
    ( serverThread s "server subscribedQ" subscribedQ subscribers subscriptions cancelSub
        : serverThread s "server ntfSubscribedQ" ntfSubscribedQ Env.notifiers ntfSubscriptions (\_ -> pure ())
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
    saveServer keepMsgs = withLog closeStoreLog >> saveServerMessages keepMsgs >> saveServerStats

    closeServer :: M ()
    closeServer = asks (smpAgent . proxyAgent) >>= liftIO . closeSMPClientAgent

    serverThread ::
      forall s.
      Server ->
      String ->
      (Server -> TQueue (Client, Subscribed, NonEmpty RecipientId)) ->
      (Server -> TMap QueueId Client) ->
      (Client -> TMap QueueId s) ->
      (s -> IO ()) ->
      M ()
    serverThread s label subQ subs clientSubs unsub = do
      labelMyThread label
      cls <- asks clients
      stats <- asks serverStats
      forever $
        atomically (updateSubscribers cls)
          >>= endPreviousSubscriptions stats
          >>= liftIO . mapM_ (mapM_ (mapM_ unsub))
      where
        updateSubscribers :: TVar (IM.IntMap (Maybe Client)) -> STM [(Client, NonEmpty QueueId)]
        updateSubscribers cls = do
          (clnt, subscribed, qIds) <- readTQueue $ subQ s
          current <- IM.member (clientId clnt) <$> readTVar cls
          let updateSub
                | not subscribed = TM.lookupDelete
                | not current = TM.lookup -- do not insert client if it is already disconnected, but send END to any other client
                | otherwise = (`TM.lookupInsert` clnt) -- insert subscribed and current client
              clientToBeNotified c'
                | sameClientId clnt c' = pure Nothing
                | otherwise = do
                    yes <- readTVar $ connected c'
                    pure $ if yes then Just c' else Nothing
              addPreviousSub :: Map ClientId (Client, NonEmpty QueueId) -> QueueId -> STM (Map ClientId (Client, NonEmpty QueueId))
              addPreviousSub m qId = (updateSub qId (subs s) $>>= clientToBeNotified) >>= pure . maybe m alterSubs
                where
                  alterSubs c' = M.alter (Just . addSub c') (clientId c') m
                  addSub :: Client -> Maybe (Client, NonEmpty QueueId) -> (Client, NonEmpty QueueId)
                  addSub c' = maybe (c', [qId]) (\(_, qIds') -> (c', qId <| qIds'))
          M.elems <$> foldM addPreviousSub M.empty qIds
        endPreviousSubscriptions :: ServerStats -> [(Client, NonEmpty QueueId)] -> M [NonEmpty (Maybe s)]
        endPreviousSubscriptions stats cls =
          forM cls $ \(c, qIds) -> do
            forkClient c (label <> ".endPreviousSubscriptions") $ do
              atomically $ writeTBQueue (sndQ c) $ L.map (CorrId "",,END) qIds
              let len = L.length qIds
              atomically $ modifyTVar' (qSubEnd stats) (+ len)
              atomically $ modifyTVar' (qSubEndB stats) (+ (len `div` 255 + 1)) -- up to 255 ENDs in the batch
            mapM (atomically . (`TM.lookupDelete` clientSubs c)) qIds

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
          q <- atomically (getMsgQueue ms rId quota)
          deleted <- atomically $ deleteExpiredMsgs q old
          atomically $ modifyTVar' (msgExpired stats) (+ deleted)

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
      ss@ServerStats {fromTime, qCreated, qSecured, qDeletedAll, qDeletedAllB, qDeletedNew, qDeletedSecured, qSub, qSubNoMsg, qSubAllB, qSubAuth, qSubDuplicate, qSubProhibited, qSubEnd, qSubEndB, qSubEndSent, qSubEndSentB, ntfCreated, ntfDeleted, ntfDeletedB, ntfSub, ntfSubB, ntfSubAuth, ntfSubDuplicate, msgSent, msgSentAuth, msgSentQuota, msgSentLarge, msgRecv, msgRecvGet, msgGet, msgGetNoMsg, msgGetAuth, msgGetDuplicate, msgGetProhibited, msgExpired, activeQueues, subscribedQueues, msgSentNtf, msgRecvNtf, activeQueuesNtf, qCount, msgCount, pRelays, pRelaysOwn, pMsgFwds, pMsgFwdsOwn, pMsgFwdsRecv}
        <- asks serverStats
      QueueStore {queues, notifiers} <- asks queueStore
      let interval = 1000000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomically $ swapTVar fromTime ts
          qCreated' <- atomically $ swapTVar qCreated 0
          qSecured' <- atomically $ swapTVar qSecured 0
          qDeletedAll' <- atomically $ swapTVar qDeletedAll 0
          qDeletedAllB' <- atomically $ swapTVar qDeletedAllB 0
          qDeletedNew' <- atomically $ swapTVar qDeletedNew 0
          qDeletedSecured' <- atomically $ swapTVar qDeletedSecured 0
          qSub' <- atomically $ swapTVar qSub 0
          qSubNoMsg' <- atomically $ swapTVar qSubNoMsg 0
          qSubAllB' <- atomically $ swapTVar qSubAllB 0
          qSubAuth' <- atomically $ swapTVar qSubAuth 0
          qSubDuplicate' <- atomically $ swapTVar qSubDuplicate 0
          qSubProhibited' <- atomically $ swapTVar qSubProhibited 0
          qSubEnd' <- atomically $ swapTVar qSubEnd 0
          qSubEndB' <- atomically $ swapTVar qSubEndB 0
          qSubEndSent' <- atomically $ swapTVar qSubEndSent 0
          qSubEndSentB' <- atomically $ swapTVar qSubEndSentB 0
          ntfCreated' <- atomically $ swapTVar ntfCreated 0
          ntfDeleted' <- atomically $ swapTVar ntfDeleted 0
          ntfDeletedB' <- atomically $ swapTVar ntfDeletedB 0
          ntfSub' <- atomically $ swapTVar ntfSub 0
          ntfSubB' <- atomically $ swapTVar ntfSubB 0
          ntfSubAuth' <- atomically $ swapTVar ntfSubAuth 0
          ntfSubDuplicate' <- atomically $ swapTVar ntfSubDuplicate 0
          msgSent' <- atomically $ swapTVar msgSent 0
          msgSentAuth' <- atomically $ swapTVar msgSentAuth 0
          msgSentQuota' <- atomically $ swapTVar msgSentQuota 0
          msgSentLarge' <- atomically $ swapTVar msgSentLarge 0
          msgRecv' <- atomically $ swapTVar msgRecv 0
          msgRecvGet' <- atomically $ swapTVar msgRecvGet 0
          msgGet' <- atomically $ swapTVar msgGet 0
          msgGetNoMsg' <- atomically $ swapTVar msgGetNoMsg 0
          msgGetAuth' <- atomically $ swapTVar msgGetAuth 0
          msgGetDuplicate' <- atomically $ swapTVar msgGetDuplicate 0
          msgGetProhibited' <- atomically $ swapTVar msgGetProhibited 0
          msgExpired' <- atomically $ swapTVar msgExpired 0
          ps <- atomically $ periodStatCounts activeQueues ts
          psSub <- atomically $ periodStatCounts subscribedQueues ts
          msgSentNtf' <- atomically $ swapTVar msgSentNtf 0
          msgRecvNtf' <- atomically $ swapTVar msgRecvNtf 0
          psNtf <- atomically $ periodStatCounts activeQueuesNtf ts
          msgNtfs' <- atomically $ swapTVar (msgNtfs ss) 0
          msgNtfNoSub' <- atomically $ swapTVar (msgNtfNoSub ss) 0
          msgNtfLost' <- atomically $ swapTVar (msgNtfLost ss) 0
          pRelays' <- atomically $ getResetProxyStatsData pRelays
          pRelaysOwn' <- atomically $ getResetProxyStatsData pRelaysOwn
          pMsgFwds' <- atomically $ getResetProxyStatsData pMsgFwds
          pMsgFwdsOwn' <- atomically $ getResetProxyStatsData pMsgFwdsOwn
          pMsgFwdsRecv' <- atomically $ swapTVar pMsgFwdsRecv 0
          qCount' <- readTVarIO qCount
          qCount'' <- M.size <$> readTVarIO queues
          ntfCount' <- M.size <$> readTVarIO notifiers
          msgCount' <- readTVarIO msgCount
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
                       show qSubNoMsg',
                       show msgRecvGet',
                       show msgGet',
                       show msgGetNoMsg',
                       show msgGetAuth',
                       show msgGetDuplicate',
                       show msgGetProhibited',
                       dayCount psSub,
                       weekCount psSub,
                       monthCount psSub,
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
                       show qSubEndSent',
                       show qSubEndSentB',
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
        runTCPServer cpStarted port $ runCPClient u srv
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
                let getStat :: (ServerStats -> TVar a) -> IO a
                    getStat var = readTVarIO (var ss)
                    putStat :: Show a => String -> (ServerStats -> TVar a) -> IO ()
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
                getStat (day . activeQueues) >>= \v -> hPutStrLn h $ "daily active queues: " <> show (S.size v)
                getStat (day . subscribedQueues) >>= \v -> hPutStrLn h $ "daily subscribed queues: " <> show (S.size v)
                putStat "qSub" qSub
                putStat "qSubNoMsg" qSubNoMsg
                putStat "qSubAllB" qSubAllB
                subEnds <- (,,,) <$> getStat qSubEnd <*> getStat qSubEndB <*> getStat qSubEndSent <*> getStat qSubEndSentB
                hPutStrLn h $ "SUB ENDs (queued, queued batches, sent, sent batches): " <> show subEnds
                subs <- (,,) <$> getStat qSubAuth <*> getStat qSubDuplicate <*> getStat qSubProhibited
                hPutStrLn h $ "other SUB events (auth, duplicate, prohibited): " <> show subs
                putStat "qSubEnd" qSubEnd
                putStat "qSubEndSent" qSubEndSent
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
                    putActiveClientsInfo :: String -> TMap QueueId Client -> IO ()
                    putActiveClientsInfo protoName clients = do
                      activeSubs <- readTVarIO clients
                      hPutStrLn h $ protoName <> " subscriptions: " <> show (M.size activeSubs)
                      clCnt <- if r == CPRAdmin then putClientQueues activeSubs else pure $ countSubClients activeSubs
                      hPutStrLn h $ protoName <> " subscribed clients: " <> show clCnt
                      where
                        putClientQueues :: M.Map QueueId Client -> IO Int
                        putClientQueues subs = do
                          let cls = differentClients subs
                          clQs <- clientTBQueueLengths cls
                          hPutStrLn h $ protoName <> " subscribed clients queues (rcvQ, sndQ, msgQ): " <> show clQs
                          pure $ length cls
                        differentClients :: M.Map QueueId Client -> [Client]
                        differentClients = fst . M.foldl' addClient ([], IS.empty)
                          where
                            addClient acc@(cls, clSet) cl@Client {clientId}
                              | IS.member clientId clSet = acc
                              | otherwise = (cl : cls, IS.insert clientId clSet)
                        countSubClients :: M.Map QueueId Client -> Int
                        countSubClients = IS.size . M.foldr' (IS.insert . clientId) IS.empty
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
                    clientTBQueueLengths :: Foldable t => t Client -> IO (Natural, Natural, Natural)
                    clientTBQueueLengths = foldM addQueueLengths (0, 0, 0)
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
                queueId <- atomically (getQueue st SSender queueId') >>= \case
                  Left _ -> pure queueId' -- fallback to using as recipientId directly
                  Right QueueRec {recipientId} -> pure recipientId
                r <- atomically $
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
      stats <- asks serverStats
      th <- newMVar h -- put TH under a fair lock to interleave messages and command responses
      labelMyThread . B.unpack $ "client $" <> encode sessionId
      raceAny_ $ [liftIO $ send th c stats, liftIO $ sendMsg th c, client thParams c s, receive h c] <> disconnectThread_ c expCfg
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport h (rcvActiveAt c) (sndActiveAt c) expCfg (noSubscriptions c)]
    disconnectThread_ _ _ = []
    noSubscriptions c = atomically $ (&&) <$> TM.null (ntfSubscriptions c) <*> (not . hasSubs <$> readTVar (subscriptions c))
    hasSubs = any $ (\case ServerSub _ -> True; ProhibitSub -> False) . subThread

clientDisconnected :: Client -> M ()
clientDisconnected c@Client {clientId, subscriptions, ntfSubscriptions, connected, sessionId, endThreads} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " disc"
  (subs, ntfSubs) <- atomically $ do
    writeTVar connected False
    (,) <$> swapTVar subscriptions M.empty <*> swapTVar ntfSubscriptions M.empty
  liftIO $ mapM_ cancelSub subs
  Server {subscribers, notifiers} <- asks server
  updateSubscribers subs subscribers
  updateSubscribers ntfSubs notifiers
  asks clients >>= atomically . (`modifyTVar'` IM.delete clientId)
  tIds <- atomically $ swapTVar endThreads IM.empty
  liftIO $ mapM_ (mapM_ killThread <=< deRefWeak) tIds
  where
    updateSubscribers subs srvSubs = do
      atomically $ modifyTVar' srvSubs $ \cs ->
        M.foldrWithKey (\sub _ -> M.update deleteCurrentClient sub) cs subs
    deleteCurrentClient :: Client -> Maybe Client
    deleteCurrentClient c'
      | sameClientId c c' = Nothing
      | otherwise = Just c'

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
    let cmd = listToMaybe $ rights $ map (\(_, _, (_, _, cmdOrError)) -> cmdOrError) ts
    forM_ (cmd >>= batchStatSel) $ \sel -> incStat $ sel stats
    (errs, cmds) <- partitionEithers <$> mapM (cmdAction stats) ts
    write sndQ errs
    write rcvQ $ foldr batchRequests [] cmds
  where
    batchStatSel :: Cmd -> Maybe (ServerStats -> TVar Int)
    batchStatSel (Cmd _ cmd) = case cmd of
      SUB -> Just qSubAllB
      DEL -> Just qDeletedAllB
      NSUB -> Just ntfSubB
      NDEL -> Just ntfDeletedB
      _ -> Nothing
    cmdAction :: ServerStats -> SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) SMPRequest)
    cmdAction stats (tAuth, authorized, (corrId, entId, cmdOrError)) =
      case cmdOrError of
        Left e -> pure $ Left (corrId, entId, ERR e)
        Right cmd -> verified =<< verifyTransmission ((,C.cbNonce (bs corrId)) <$> thAuth) tAuth authorized corrId entId cmd
          where
            verified = \case
              VRVerified t -> pure $ Right t
              VRFailed -> do
                case cmd of
                  Cmd _ SEND {} -> incStat $ msgSentAuth stats
                  Cmd _ SUB -> incStat $ qSubAuth stats
                  Cmd _ NSUB -> incStat $ ntfSubAuth stats
                  Cmd _ GET -> incStat $ msgGetAuth stats
                  _ -> pure ()
                pure $ Left (corrId, entId, ERR AUTH)
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty
    batchRequests :: SMPRequest -> [SMPRequest] -> [SMPRequest]
    batchRequests r rs = case r of
      SMPReqCmd cmd t -> case batchedCmd cmd of
        Just br -> case rs of
          SMPReqBatched br' ts : rs'
            | br == br' -> SMPReqBatched br' (t <| ts) : rs'
          _ -> SMPReqBatched br [t] : rs
        Nothing -> r : rs
      _ -> r : rs
      where
        batchedCmd :: DirectCmd -> Maybe BatchedCommand
        batchedCmd (DCmd _ command) = case command of
          SUB -> Just B_SUB
          DEL -> Just B_DEL
          NSUB -> Just B_NSUB
          NDEL -> Just B_NDEL
          _ -> Nothing

send :: Transport c => MVar (THandleSMP c 'TServer) -> Client -> ServerStats -> IO ()
send th c@Client {sndQ, msgQ, sessionId} stats = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " send"
  forever $ do
    ts <- atomically (readTBQueue sndQ)
    sendTransmissions ts
    updateENDStats ts
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
    updateENDStats :: NonEmpty (Transmission BrokerMsg) -> IO ()
    updateENDStats = \case
      ts@((_, _, END) :| _) -> do -- END events are not combined with others
        let len = L.length ts
        atomically $ modifyTVar' (qSubEndSent stats) (+ len)
        atomically $ modifyTVar' (qSubEndSentB stats) (+ (len `div` 255 + 1)) -- up to 255 ENDs in the batch
      _ -> pure ()
        
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

data VerificationResult = VRVerified SMPRequest | VRFailed

-- This function verifies queue command authorization, with the objective to have constant time between the three AUTH error scenarios:
-- - the queue and party key exist, and the provided authorization has type matching queue key, but it is made with the different key.
-- - the queue and party key exist, but the provided authorization has incorrect type.
-- - the queue or party key do not exist.
-- In all cases, the time of the verification should depend only on the provided authorization type,
-- a dummy key is used to run verification in the last two cases, and failure is returned irrespective of the result.
verifyTransmission :: Maybe (THandleAuth 'TServer, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> CorrId -> QueueId -> Cmd -> M VerificationResult
verifyTransmission auth_ tAuth authorized corrId entId (Cmd p cmd) =
  case p of
    SService -> case cmd of
      (NEW k dhKey newAuth_ sm ss) -> pure $ SMPReqNew (corrId, entId, NewSMPQueue k dhKey newAuth_ sm ss) `verifiedWith` k
      PING -> pure $ VRVerified $ SMPReqPing corrId
      RFWD encBlock -> pure $ VRVerified $ SMPReqFwdCmd corrId encBlock
    SRecipient -> verifyQueue (\q -> reqCmd p cmd q `verifiedWith` recipientKey q) <$> get SRecipient
    SSender -> case cmd of
      SKEY k -> verifyQueue (\q -> reqCmd p cmd q `verifiedWith` k) <$> get SSender
      -- SEND will be accepted without authorization before the queue is secured with KEY or SKEY command
      SEND {} -> verifyQueue (\q -> reqCmd p cmd q `verified` maybe (isNothing tAuth) verify (senderKey q)) <$> get SSender
    -- NSUB will not be accepted without authorization
    SNotifier -> verifyQueue (\q -> maybe dummyVerify (\n -> reqCmd p cmd q `verifiedWith` notifierKey n) (notifier q)) <$> get SNotifier
    SProxiedClient -> pure $ VRVerified $ SMPReqPrxCmd (corrId, entId, cmd)
  where
    verify = verifyCmdAuthorization auth_ tAuth authorized
    dummyVerify = verify (dummyAuthKey tAuth) `seq` VRFailed
    verifyQueue :: (QueueRec -> VerificationResult) -> Either ErrorType QueueRec -> VerificationResult
    verifyQueue = either (const dummyVerify)
    reqCmd :: (PartyI p, DirectParty p) => SParty p -> Command p -> QueueRec -> SMPRequest
    reqCmd p' cmd' q = SMPReqCmd (DCmd p' cmd') (corrId, entId, q)
    verified r cond = if cond then VRVerified r else VRFailed
    verifiedWith r k = r `verified` verify k
    get :: DirectParty p => SParty p -> M (Either ErrorType QueueRec)
    get party = do
      st <- asks queueStore
      atomically $ getQueue st party entId

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
client thParams' clnt@Client {subscriptions, ntfSubscriptions, rcvQ, sndQ, sessionId, procThreads} Server {subscribedQ, ntfSubscribedQ, subscribers, notifiers} = do
  labelMyThread . B.unpack $ "client $" <> encode sessionId <> " commands"
  forever $
    atomically (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= mapM_ reply . L.nonEmpty . concat . L.toList
  where
    reply :: MonadIO m => NonEmpty (Transmission BrokerMsg) -> m ()
    reply = atomically . writeTBQueue sndQ
    processProxiedCmd :: Transmission (Command 'ProxiedClient) -> M [Transmission BrokerMsg]
    processProxiedCmd (corrId, sessId, command) = map (corrId,sessId,) <$> case command of
      PRXY srv auth -> ifM allowProxy getRelay (pure [ERR $ PROXY BASIC_AUTH])
        where
          allowProxy = do
            ServerConfig {allowSMPProxy, newQueueBasicAuth} <- asks config
            pure $ allowSMPProxy && maybe True ((== auth) . Just) newQueueBasicAuth
          getRelay = do
            ProxyAgent {smpAgent = a} <- asks proxyAgent
            liftIO (getConnectedSMPServerClient a srv) >>= \case
              Just r -> (: []) <$> proxyServerResponse a r
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
              else [ERR $ transportErr TEVersion] <$ inc own pErrorsCompat
            where
              THandleParams {thVersion = v} = thParams smp
          Nothing -> inc False pRequests >> inc False pErrorsConnect $> [ERR $ PROXY NO_SESSION]
      where
        forkProxiedCmd :: M BrokerMsg -> M [BrokerMsg]
        forkProxiedCmd cmdAction = do
          bracket_ wait signal . forkClient clnt (B.unpack $ "client $" <> encode sessionId <> " proxy") $ do
            -- commands MUST be processed under a reasonable timeout or the client would halt
            cmdAction >>= \t -> reply [(corrId, sessId, t)]
          pure []
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
    mkIncProxyStats :: MonadIO m => ProxyStats -> ProxyStats -> OwnServer -> (ProxyStats -> TVar Int) -> m ()
    mkIncProxyStats ps psOwn own sel = do
      incStat $ sel ps
      when own $ incStat $ sel psOwn
    processCommand :: SMPRequest -> M [Transmission BrokerMsg]
    processCommand req = do
      st <- asks queueStore
      case req of
        SMPReqPrxCmd t -> processProxiedCmd t
        SMPReqPing corrId -> pure [(corrId, "", PONG)]
        SMPReqFwdCmd corrId encBlock -> (\r -> [(corrId, "", r)]) <$> processForwardedCommand corrId encBlock
        SMPReqNew t@(_, _, NewSMPQueue _ _ auth _ _) ->
          (: []) <$> ifM allowNew (createQueue st t) (pure $ err t AUTH)
          where
            allowNew = do
              ServerConfig {allowNewQueues, newQueueBasicAuth} <- asks config
              pure $ allowNewQueues && maybe True ((== auth) . Just) newQueueBasicAuth
        SMPReqBatched br ts -> case br of
          B_SUB -> mapM subscribeQueue ts >>= notifySubscriptions subscribedQ True
          B_DEL -> do
            (qIds, rs) <- L.unzip <$> mapM (delQueueAndMsgs st) ts
            forM_ (catMaybesNE qIds) $ \qIds' -> do
              let (rIds, nIds) = L.unzip qIds'
              -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
              atomically $ writeTQueue subscribedQ (clnt, False, rIds)
              mapM_ (atomically . writeTQueue ntfSubscribedQ . (clnt,False,)) $ catMaybesNE nIds
            pure $ L.toList rs
          B_NSUB -> mapM subscribeNotifications ts >>= notifySubscriptions ntfSubscribedQ True
          B_NDEL -> mapM (deleteQueueNotifier_ st) ts >>= notifySubscriptions ntfSubscribedQ False
        SMPReqCmd (DCmd _ command) t -> (: []) <$> case command of
          SKEY sKey -> sndSecureQueue t sKey
          SEND flags msgBody -> sendMessage t flags msgBody
          NSUB -> pure $ err t $ INTERNAL -- subscribeNotifications t >>= notifySubscription ntfSubscribedQ True
          SUB -> pure $ err t $ INTERNAL -- subscribeQueue t >>= notifySubscription subscribedQ True
          GET -> getMessage t
          ACK msgId -> acknowledgeMsg t msgId
          KEY sKey -> rcvSecureQueue t sKey
          NKEY nKey dhKey -> addQueueNotifier_ st t nKey dhKey
          NDEL -> pure $ err t $ INTERNAL -- deleteQueueNotifier_ st t >>= notifySubscription ntfSubscribedQ False
          OFF -> suspendQueue_ st t
          DEL -> pure $ err t $ INTERNAL
          -- do
          --   (qIds_, r) <- delQueueAndMsgs st t
          --   forM_ qIds_ $ \(rId, nId_) -> do
          --     -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
          --     atomically $ writeTQueue subscribedQ (clnt, False, [rId])
          --     forM_ nId_ $ \nId -> atomically $ writeTQueue ntfSubscribedQ (clnt, False, [nId])
          --   pure r
          QUE -> getQueueInfo t
      where
        -- Possibly, the same should be done if the queue is suspended, but currently we do not use it
        notifySubscription :: TQueue (Client, Subscribed, NonEmpty QueueId) -> Subscribed -> (Maybe QueueId, Transmission BrokerMsg) -> M (Transmission BrokerMsg)
        notifySubscription subQ subscribed (qId_, r) = do
          mapM_ (\qId -> atomically $ writeTQueue subQ (clnt, subscribed, [qId])) qId_
          pure r

        notifySubscriptions :: TQueue (Client, Subscribed, NonEmpty QueueId) -> Subscribed -> NonEmpty (Maybe QueueId, Transmission BrokerMsg) -> M [Transmission BrokerMsg]
        notifySubscriptions subQ subscribed rs = do
          let (qIds, rs') = L.unzip rs
          mapM_ (atomically . writeTQueue subQ . (clnt,subscribed,)) $ catMaybesNE qIds
          pure $ L.toList rs'

        catMaybesNE :: NonEmpty (Maybe a) -> Maybe (NonEmpty a)
        catMaybesNE = L.nonEmpty . catMaybes . L.toList

        createQueue :: QueueStore -> Transmission NewSMPQueue -> M (Transmission BrokerMsg)
        createQueue st (corrId, entId, NewSMPQueue recipientKey dhKey _auth subMode sndSecure) = timed "NEW" entId $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
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
                    sndSecure
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
              atomically (addQueue st qr) >>= \case
                Left DUPLICATE_ -> addQueueRetry (n - 1) qik qRec
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog (`logCreateById` rId)
                  stats <- asks serverStats
                  incStat $ qCreated stats
                  incStat $ qCount stats
                  case subMode of
                    SMOnlyCreate -> pure ()
                    SMSubscribe -> do
                      (rId_, _) <- subscribeQueue (corrId, rId, qr)
                      mapM_ (\rId' -> atomically $ writeTQueue subscribedQ (clnt, True, [rId'])) rId_
                  pure $ IDS (qik ids)

            logCreateById :: StoreLog 'WriteMode -> RecipientId -> IO ()
            logCreateById s rId =
              atomically (getQueue st SRecipient rId) >>= \case
                Right q -> logCreateQueue s q
                _ -> pure ()

            getIds :: M (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        rcvSecureQueue :: Transmission QueueRec -> SndPublicAuthKey -> M (Transmission BrokerMsg)
        rcvSecureQueue (corrId, entId, QueueRec {recipientId}) sKey =
          (corrId,entId,) <$> secureQueue_ "KEY" recipientId sKey

        sndSecureQueue :: Transmission QueueRec -> SndPublicAuthKey -> M (Transmission BrokerMsg)
        sndSecureQueue t@(corrId, entId, QueueRec {sndSecure, recipientId}) sKey
          | sndSecure = (corrId,entId,) <$> secureQueue_ "SKEY" recipientId sKey
          | otherwise = pure $ err t AUTH

        secureQueue_ :: T.Text -> RecipientId -> SndPublicAuthKey -> M BrokerMsg
        secureQueue_ name rId sKey = timed name rId $ do
          withLog $ \s -> logSecureQueue s rId sKey
          st <- asks queueStore
          stats <- asks serverStats
          incStat $ qSecured stats
          atomically $ either ERR (const OK) <$> secureQueue st rId sKey

        addQueueNotifier_ :: QueueStore -> Transmission QueueRec -> NtfPublicAuthKey -> RcvNtfPublicDhKey -> M (Transmission BrokerMsg)
        addQueueNotifier_ st (corrId, entId, _) notifierKey dhKey = timed "NKEY" entId $ do
          (rcvPublicDhKey, privDhKey) <- atomically . C.generateKeyPair =<< asks random
          let rcvNtfDhSecret = C.dh' dhKey privDhKey
          (corrId,entId,) <$> addNotifierRetry 3 rcvPublicDhKey rcvNtfDhSecret
          where
            addNotifierRetry :: Int -> RcvNtfPublicDhKey -> RcvNtfDhSecret -> M BrokerMsg
            addNotifierRetry 0 _ _ = pure $ ERR INTERNAL
            addNotifierRetry n rcvPublicDhKey rcvNtfDhSecret = do
              notifierId <- randomId =<< asks (queueIdBytes . config)
              let ntfCreds = NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}
              atomically (addQueueNotifier st entId ntfCreds) >>= \case
                Left DUPLICATE_ -> addNotifierRetry (n - 1) rcvPublicDhKey rcvNtfDhSecret
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s entId ntfCreds
                  incStat . ntfCreated =<< asks serverStats
                  pure $ NID notifierId rcvPublicDhKey

        deleteQueueNotifier_ :: QueueStore -> Transmission QueueRec -> M (Maybe NotifierId, Transmission BrokerMsg)
        deleteQueueNotifier_ st t@(_, entId, _) = do
          withLog (`logDeleteNotifier` entId)
          atomically (deleteQueueNotifier st entId) >>= \case
            Right () -> do
              incStat . ntfDeleted =<< asks serverStats
              pure (Just entId, ok t)
            Left e -> pure (Nothing, err t e)

        suspendQueue_ :: QueueStore -> Transmission QueueRec -> M (Transmission BrokerMsg)
        suspendQueue_ st t@(_, entId, _) = do
          withLog (`logSuspendQueue` entId)
          either (err t) (const $ ok t) <$> atomically (suspendQueue st entId)

        subscribeQueue :: Transmission QueueRec -> M (Maybe RecipientId, Transmission BrokerMsg)
        subscribeQueue t@(_, rId, _) = do
          atomically (TM.lookup rId subscriptions) >>= \case
            Nothing -> (Just rId,) <$> (deliver True =<< newSub)
            Just s@Sub {subThread} -> do
              stats <- asks serverStats
              case subThread of
                ProhibitSub -> do
                  -- cannot use SUB in the same connection where GET was used
                  incStat $ qSubProhibited stats
                  pure (Nothing, err t $ CMD PROHIBITED)
                _ -> do
                  incStat $ qSubDuplicate stats
                  void $ atomically $ tryTakeTMVar $ delivered s
                  (Nothing,) <$> deliver False s
          where
            newSub :: M Sub
            newSub = timed "SUB newSub" rId . atomically $ do
              sub <- newSubscription NoSub
              TM.insert rId sub subscriptions
              pure sub
            deliver :: Bool -> Sub -> M (Transmission BrokerMsg)
            deliver inc sub = do
              q <- getStoreMsgQueue "SUB" rId
              msg_ <- atomically $ tryPeekMsg q
              when inc $ do
                stats <- asks serverStats
                incStat $ (if isJust msg_ then qSub else qSubNoMsg) stats
                atomically $ updatePeriodStats (subscribedQueues stats) rId
              deliverMessage "SUB" t sub msg_

        getMessage :: Transmission QueueRec -> M (Transmission BrokerMsg)
        getMessage t@(corrId, rId, qr) = timed "GET" rId $ do
          atomically (TM.lookup rId subscriptions) >>= \case
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
                  pure $ err t $ CMD PROHIBITED
          where
            newSub :: STM Sub
            newSub = do
              s <- newProhibitedSub
              TM.insert rId s subscriptions
              pure s
            getMessage_ :: Sub -> Maybe MsgId -> M (Transmission BrokerMsg)
            getMessage_ s delivered_ = do
              q <- getStoreMsgQueue "GET" rId
              stats <- asks serverStats
              (statCnt, r) <-
                atomically $
                  tryPeekMsg q >>= \case
                    Just msg ->
                      let encMsg = encryptMsg qr msg
                          cnt = if isJust delivered_ then msgGetDuplicate else msgGet
                       in setDelivered s msg $> (cnt, (corrId, rId, MSG encMsg))
                    _ -> pure (msgGetNoMsg, ok t)
              incStat $ statCnt stats
              pure r

        subscribeNotifications :: Transmission QueueRec -> M (Maybe NotifierId, Transmission BrokerMsg)
        subscribeNotifications t@(_, nId, _)= do
          (statCount, nId_) <-
            timed "NSUB" nId . atomically $ do
              ifM
                (TM.member nId ntfSubscriptions)
                (pure (ntfSubDuplicate, Nothing))
                (newSub $> (ntfSub, Just nId))
          incStat . statCount =<< asks serverStats
          pure (nId_, ok t)
          where
            newSub = TM.insert nId () ntfSubscriptions

        acknowledgeMsg :: Transmission QueueRec -> MsgId -> M (Transmission BrokerMsg)
        acknowledgeMsg t@(_, rId, _) msgId = timed "ACK" rId $ do
          liftIO (TM.lookupIO rId subscriptions) >>= \case
            Nothing -> pure $ err t NO_MSG
            Just sub ->
              atomically (getDelivered sub) >>= \case
                Just st -> do
                  q <- getStoreMsgQueue "ACK" rId
                  case st of
                    ProhibitSub -> do
                      deletedMsg_ <- atomically $ tryDelMsg q msgId
                      mapM_ (updateStats True) deletedMsg_
                      pure $ ok t
                    _ -> do
                      (deletedMsg_, msg_) <- atomically $ tryDelPeekMsg q msgId
                      mapM_ (updateStats False) deletedMsg_
                      deliverMessage "ACK" t sub msg_
                _ -> pure $ err t NO_MSG
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
                atomically $ modifyTVar' (msgCount stats) (subtract 1)
                atomically $ updatePeriodStats (activeQueues stats) rId
                when (notification msgFlags) $ do
                  incStat $ msgRecvNtf stats
                  atomically $ updatePeriodStats (activeQueuesNtf stats) rId

        sendMessage :: Transmission QueueRec -> MsgFlags -> MsgBody -> M (Transmission BrokerMsg)
        sendMessage t@(_, sId, qr@QueueRec {recipientId = rId, notifier, status}) msgFlags msgBody
          | B.length msgBody > maxMessageLength thVersion = do
              stats <- asks serverStats
              incStat $ msgSentLarge stats
              pure $ err t LARGE_MSG
          | otherwise = do
              stats <- asks serverStats
              case status of
                QueueOff -> do
                  incStat $ msgSentAuth stats
                  pure $ err t AUTH
                QueueActive ->
                  case C.maxLenBS msgBody of
                    Left _ -> pure $ err t LARGE_MSG
                    Right body -> do
                      msg_ <- timed "SEND" sId $ do
                        q <- getStoreMsgQueue "SEND" rId
                        expireMessages q
                        atomically . writeMsg q =<< mkMessage body
                      case msg_ of
                        Nothing -> do
                          incStat $ msgSentQuota stats
                          pure $ err t QUOTA
                        Just (msg, wasEmpty) -> timed "SEND ok" sId $ do
                          when wasEmpty $ tryDeliverMessage msg
                          when (notification msgFlags) $ do
                            forM_ notifier $ \ntf -> do
                              asks random >>= atomically . trySendNotification ntf msg >>= \case
                                Nothing -> do
                                  incStat $ msgNtfNoSub stats
                                  logWarn "No notification subscription"
                                Just False -> do
                                  incStat $ msgNtfLost stats
                                  logWarn "Dropped message notification"
                                Just True -> incStat $ msgNtfs stats
                            incStat $ msgSentNtf stats
                            atomically $ updatePeriodStats (activeQueuesNtf stats) rId
                          incStat $ msgSent stats
                          incStat $ msgCount stats
                          atomically $ updatePeriodStats (activeQueues stats) rId
                          pure $ ok t
          where
            THandleParams {thVersion} = thParams'
            mkMessage :: C.MaxLenBS MaxMessageLen -> M Message
            mkMessage body = do
              msgId <- randomId =<< asks (msgIdBytes . config)
              msgTs <- liftIO getSystemTime
              pure $! Message msgId msgTs msgFlags body

            expireMessages :: MsgQueue -> M ()
            expireMessages q = do
              msgExp <- asks $ messageExpiration . config
              old <- liftIO $ mapM expireBeforeEpoch msgExp
              deleted <- atomically $ sum <$> mapM (deleteExpiredMsgs q) old
              when (deleted > 0) $ do
                stats <- asks serverStats
                atomically $ modifyTVar' (msgExpired stats) (+ deleted)

            -- The condition for delivery of the message is:
            -- - the queue was empty when the message was sent,
            -- - there is subscribed recipient,
            -- - no message was "delivered" that was not acknowledged.
            -- If the send queue of the subscribed client is not full the message is put there in the same transaction.
            -- If the queue is not full, then the thread is created where these checks are made:
            -- - it is the same subscribed client (in case it was reconnected it would receive message via SUB command)
            -- - nothing was delivered to this subscription (to avoid race conditions with the recipient).
            tryDeliverMessage :: Message -> M ()
            tryDeliverMessage msg = atomically deliverToSub >>= mapM_ forkDeliver
              where
                deliverToSub =
                  TM.lookup rId subscribers
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
                  tId <- mkWeakThreadId =<< forkIO deliverThread
                  atomically $ modifyTVar' st $ \case
                    -- this case is needed because deliverThread can exit before it
                    SubPending -> SubThread tId
                    st' -> st'
                  where
                    deliverThread = do
                      labelMyThread $ B.unpack ("client $" <> encode sessionId) <> " deliver/SEND"
                      timed "deliver" sId . atomically $
                        whenM (maybe False (sameClientId rc) <$> TM.lookup rId subscribers) $ do
                          tryTakeTMVar delivered >>= \case
                            Just _ -> pure () -- if a message was already delivered, should not deliver more
                            Nothing -> do
                              deliver q s
                              writeTVar st NoSub

            trySendNotification :: NtfCreds -> Message -> TVar ChaChaDRG -> STM (Maybe Bool)
            trySendNotification NtfCreds {notifierId, rcvNtfDhSecret} msg ntfNonceDrg =
              mapM (writeNtf notifierId msg rcvNtfDhSecret ntfNonceDrg) =<< TM.lookup notifierId notifiers

            writeNtf :: NotifierId -> Message -> RcvNtfDhSecret -> TVar ChaChaDRG -> Client -> STM Bool
            writeNtf nId msg rcvNtfDhSecret ntfNonceDrg Client {sndQ = q} =
              ifM (isFullTBQueue q) (pure False) (sendNtf $> True)
              where
                sendNtf = case msg of
                  Message {msgId, msgTs} -> do
                    (nmsgNonce, encNMsgMeta) <- mkMessageNotification msgId msgTs rcvNtfDhSecret ntfNonceDrg
                    writeTBQueue q [(CorrId "", nId, NMSG nmsgNonce encNMsgMeta)]
                  _ -> pure ()

            mkMessageNotification :: ByteString -> SystemTime -> RcvNtfDhSecret -> TVar ChaChaDRG -> STM (C.CbNonce, EncNMsgMeta)
            mkMessageNotification msgId msgTs rcvNtfDhSecret ntfNonceDrg = do
              cbNonce <- C.randomCbNonce ntfNonceDrg
              let msgMeta = NMsgMeta {msgId, msgTs}
                  encNMsgMeta = C.cbEncrypt rcvNtfDhSecret cbNonce (smpEncode msgMeta) 128
              pure . (cbNonce,) $ fromRight "" encNMsgMeta

        processForwardedCommand :: CorrId -> EncFwdTransmission -> M BrokerMsg
        processForwardedCommand corrId (EncFwdTransmission s) = fmap (either ERR id) . runExceptT $ do
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
          t'@(_, _, (corrId', entId', _)) <- case tParse clntTHParams b of
            t :| [] -> pure $ tDecodeParseValidate clntTHParams t
            _ -> throwE BLOCK
          let clntThAuth = Just $ THAuthServer {serverPrivKey, sessSecret' = Just clientSecret}
          -- process forwarded command
          r <-
            lift (rejectOrVerify clntThAuth t') >>= \case
              Left r -> pure r
              -- rejectOrVerify filters allowed commands, no need to repeat it here.
              -- INTERNAL is used because processCommand never returns Nothing for sender commands (could be extracted for better types).
              Right req' -> fromMaybe (corrId', entId', ERR INTERNAL) . listToMaybe <$> lift (processCommand req')
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
            rejectOrVerify :: Maybe (THandleAuth 'TServer) -> SignedTransmission ErrorType Cmd -> M (Either (Transmission BrokerMsg) SMPRequest)
            rejectOrVerify clntThAuth (tAuth, authorized, t@(corrId', entId', cmdOrError)) =
              case cmdOrError of
                Left e -> pure $ Left $ err t e
                Right cmd'
                  | allowed -> verified <$> verifyTransmission ((,C.cbNonce (bs corrId')) <$> clntThAuth) tAuth authorized corrId' entId' cmd'
                  | otherwise -> pure $ Left $ err t $ CMD PROHIBITED
                  where
                    allowed = case cmd' of
                      Cmd SSender SEND {} -> True
                      Cmd SSender (SKEY _) -> True
                      _ -> False
                    verified = \case
                      VRVerified req' -> Right req'
                      VRFailed -> Left $ err t AUTH

        deliverMessage :: T.Text -> Transmission QueueRec -> Sub -> Maybe Message -> M (Transmission BrokerMsg)
        deliverMessage name t@(corrId, rId, qr) s@Sub {subThread} msg_ = timed (name <> " deliver") rId . atomically $
          case subThread of
            ProhibitSub -> pure $ ok t
            _ -> case msg_ of
              Just msg ->
                let encMsg = encryptMsg qr msg
                 in setDelivered s msg $> (corrId, rId, MSG encMsg)
              _ -> pure $ ok t

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
        getStoreMsgQueue name rId = timed (name <> " getMsgQueue") rId $ do
          ms <- asks msgStore
          quota <- asks $ msgQueueQuota . config
          atomically $ getMsgQueue ms rId quota

        delQueueAndMsgs :: QueueStore -> Transmission QueueRec -> M (Maybe (RecipientId, Maybe NotifierId), Transmission BrokerMsg)
        delQueueAndMsgs st t@(_, rId, QueueRec {notifier}) = do
          withLog (`logDeleteQueue` rId)
          ms <- asks msgStore
          atomically (deleteQueue st rId $>>= \q -> delMsgQueue ms rId $> Right q) >>= \case
            Right q -> updateDeletedStats q $> (Just (rId, notifierId <$> notifier), ok t)
            Left e -> pure (Nothing, err t e)

        getQueueInfo :: Transmission QueueRec -> M (Transmission BrokerMsg)
        getQueueInfo (corrId, rId, QueueRec {senderKey, notifier}) = do
          q@MsgQueue {size} <- getStoreMsgQueue "getQueueInfo" rId
          info <- atomically $ do
            qiSub <- TM.lookup rId subscriptions >>= mapM mkQSub
            qiSize <- readTVar size
            qiMsg <- toMsgInfo <$$> tryPeekMsg q
            pure QueueInfo {qiSnd = isJust senderKey, qiNtf = isJust notifier, qiSub, qiSize, qiMsg}
          pure (corrId, rId, INFO info)
          where
            mkQSub Sub {subThread, delivered} = do
              qSubThread <- case subThread of
                ServerSub t -> do
                  st <- readTVar t
                  pure $ case st of
                    NoSub -> QNoSub
                    SubPending -> QSubPending
                    SubThread _ -> QSubThread
                ProhibitSub -> pure QProhibitSub
              qDelivered <- decodeLatin1 . encode <$$> tryReadTMVar delivered
              pure QSub {qSubThread, qDelivered}

        ok :: Transmission a -> Transmission BrokerMsg
        ok (corrId, qId, _) = (corrId, qId, OK)

        err :: Transmission a -> ErrorType -> Transmission BrokerMsg
        err (corrId, qId, _) e = (corrId, qId, ERR e)

updateDeletedStats :: QueueRec -> M ()
updateDeletedStats q = do
  stats <- asks serverStats
  let delSel = if isNothing (senderKey q) then qDeletedNew else qDeletedSecured
  incStat $ delSel stats
  incStat $ qDeletedAll stats
  incStat $ qCount stats

incStat :: MonadIO m => TVar Int -> m ()
incStat v = atomically $ modifyTVar' v (+ 1)
{-# INLINE incStat #-}

withLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withLog action = do
  env <- ask
  liftIO . mapM_ action $ storeLog (env :: Env)

timed :: T.Text -> RecipientId -> M a -> M a
timed name qId a = do
  t <- liftIO getSystemTime
  r <- a
  t' <- liftIO getSystemTime
  let int = diff t t'
  when (int > sec) . logDebug $ T.unwords [name, tshow $ encode qId, tshow int]
  pure r
  where
    diff t t' = (systemSeconds t' - systemSeconds t) * sec + fromIntegral (systemNanoseconds t' - systemNanoseconds t)
    sec = 1000_000000

randomId :: Int -> M ByteString
randomId n = atomically . C.randomBytes n =<< asks random

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
              (isExpired, logFull) <- atomically $ do
                q <- getMsgQueue ms rId quota
                case msg of
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
          _msgCount <- foldM (\(!n) q -> (n +) <$> readTVarIO (size q)) 0 =<< readTVarIO =<< asks msgStore
          atomically $ setServerStats s d {_qCount, _msgCount, _msgExpired = _msgExpired d + expiredWhileRestoring}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
          when (_qCount /= statsQCount) $ logWarn $ "Queue count differs: stats: " <> tshow statsQCount <> ", store: " <> tshow _qCount
          logInfo $ "Restored " <> tshow _msgCount <> " messages in " <> tshow _qCount <> " queues"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
