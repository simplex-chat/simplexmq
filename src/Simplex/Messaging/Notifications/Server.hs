{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Notifications.Server where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import qualified Control.Exception as E
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
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, mapMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
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
import Simplex.Messaging.Notifications.Server.Prometheus
import Simplex.Messaging.Notifications.Server.Push (PushNotification(..), PushProviderError(..))
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store (NtfSTMStore, TokenNtfMessageRecord (..), stmStoreTokenLastNtf)
import Simplex.Messaging.Notifications.Server.Store.Postgres
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol (EntityId (..), ErrorType (..), NotifierId, Party (..), ProtocolServer (host), SMPServer, ServiceId, SignedTransmission, Transmission, pattern NoEntity, pattern SMPServer, encodeTransmission, tGetServer, tPut)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Control (CPClientRole (..))
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.QueueStore (getSystemDate)
import Simplex.Messaging.Server.Stats (PeriodStats (..), PeriodStatCounts (..), periodStatCounts, periodStatDataCounts, updatePeriodStats)
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Transport (ASrvTransport, ATransport (..), THandle (..), THandleAuth (..), THandleParams (..), TProxy, Transport (..), TransportPeer (..), defaultSupportedParams)
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.Server (AddHTTP, runTransportServer, runLocalTCPServer)
import Simplex.Messaging.Util
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.IO (BufferMode (..), hClose, hPrint, hPutStrLn, hSetBuffering, hSetNewlineMode, universalNewlineMode)
import System.Mem.Weak (deRefWeak)
import System.Timeout (timeout)
import UnliftIO (IOMode (..), UnliftIO, askUnliftIO, race_, unliftIO, withFile)
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
ntfServer cfg@NtfServerConfig {transports, transportConfig = tCfg, startOptions} started = do
  restoreServerStats
  s <- asks subscriber
  ps <- asks pushServer
  when (maintenance startOptions) $ do
    liftIO $ putStrLn "Server started in 'maintenance' mode, exiting"
    stopServer
    liftIO $ exitSuccess
  void $ forkIO $ resubscribe s
  raceAny_
    ( ntfSubscriber s
        : ntfPush ps
        : periodicNtfsThread ps
        : map runServer transports
          <> serverStatsThread_ cfg
          <> prometheusMetricsThread_ cfg
          <> controlPortThread_ cfg
    )
    `finally` stopServer
  where
    runServer :: (ServiceName, ASrvTransport, AddHTTP) -> M ()
    runServer (tcpPort, ATransport t, _addHTTP) = do
      srvCreds <- asks tlsServerCreds
      serverSignKey <- either fail pure $ C.x509ToPrivate' $ snd srvCreds
      env <- ask
      liftIO $ runTransportServer started tcpPort defaultSupportedParams srvCreds tCfg $ \h -> runClient serverSignKey t h `runReaderT` env

    runClient :: Transport c => C.APrivateSignKey -> TProxy c 'TServer -> c 'TServer -> M ()
    runClient signKey _ h = do
      kh <- asks serverIdentity
      ks <- atomically . C.generateKeyPair =<< asks random
      NtfServerConfig {ntfServerVRange} <- asks config
      liftIO (runExceptT $ ntfServerHandshake signKey h ks kh ntfServerVRange) >>= \case
        Right th -> runNtfClientTransport th
        Left _ -> pure ()

    stopServer :: M ()
    stopServer = do
      logNote "Saving server state..."
      saveServer
      NtfSubscriber {smpSubscribers, smpAgent} <- asks subscriber
      liftIO $ readTVarIO smpSubscribers >>= mapM_ stopSubscriber
      liftIO $ closeSMPClientAgent smpAgent
      logNote "Server stopped"
      where
        stopSubscriber v =
          atomically (tryReadTMVar $ sessionVar v)
            >>= mapM (deRefWeak . subThreadId >=> mapM_ killThread)

    saveServer :: M ()
    saveServer = asks store >>= liftIO . closeNtfDbStore >> saveServerStats

    serverStatsThread_ :: NtfServerConfig -> [M ()]
    serverStatsThread_ NtfServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      logNote $ "server stats log enabled: " <> T.pack statsFilePath
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
          T.hPutStrLn h $
            T.intercalate
              ","
              [ T.pack $ iso8601Show $ utctDay fromTime',
                tshow tknCreated',
                tshow tknVerified',
                tshow tknDeleted',
                tshow subCreated',
                tshow subDeleted',
                tshow ntfReceived',
                tshow ntfDelivered',
                dayCount tkn,
                weekCount tkn,
                monthCount tkn,
                dayCount sub,
                weekCount sub,
                monthCount sub,
                tshow tknReplaced',
                tshow ntfFailed',
                tshow ntfCronDelivered',
                tshow ntfCronFailed',
                tshow ntfVrfQueued',
                tshow ntfVrfDelivered',
                tshow ntfVrfFailed',
                tshow ntfVrfInvalidTkn'
              ]
        liftIO $ threadDelay' interval

    prometheusMetricsThread_ :: NtfServerConfig -> [M ()]
    prometheusMetricsThread_ NtfServerConfig {prometheusInterval = Just interval, prometheusMetricsFile} =
      [savePrometheusMetrics interval prometheusMetricsFile]
    prometheusMetricsThread_ _ = []

    savePrometheusMetrics :: Int -> FilePath -> M ()
    savePrometheusMetrics saveInterval metricsFile = do
      labelMyThread "savePrometheusMetrics"
      liftIO $ putStrLn $ "Prometheus metrics saved every " <> show saveInterval <> " seconds to " <> metricsFile
      st <- asks store
      ss <- asks serverStats
      env <- ask
      rtsOpts <- liftIO $ maybe ("set " <> rtsOptionsEnv) T.pack <$> lookupEnv (T.unpack rtsOptionsEnv)
      let interval = 1000000 * saveInterval
      liftIO $ forever $ do
        threadDelay interval
        ts <- getCurrentTime
        sm <- getNtfServerMetrics st ss rtsOpts
        rtm <- getNtfRealTimeMetrics env
        T.writeFile metricsFile $ ntfPrometheusMetrics sm rtm ts

    getNtfServerMetrics :: NtfPostgresStore -> NtfServerStats -> Text -> IO NtfServerMetrics
    getNtfServerMetrics st ss rtsOptions = do
      d <- getNtfServerStatsData ss
      let psTkns = periodStatDataCounts $ _activeTokens d
          psSubs = periodStatDataCounts $ _activeSubs d
      (tokenCount, approxSubCount, lastNtfCount) <- getEntityCounts st
      pure NtfServerMetrics {statsData = d, activeTokensCounts = psTkns, activeSubsCounts = psSubs, tokenCount, approxSubCount, lastNtfCount, rtsOptions}

    getNtfRealTimeMetrics :: NtfEnv -> IO NtfRealTimeMetrics
    getNtfRealTimeMetrics NtfEnv {subscriber, pushServer} = do
#if MIN_VERSION_base(4,18,0)
      threadsCount <- length <$> listThreads
#else
      let threadsCount = 0
#endif
      let NtfSubscriber {smpSubscribers, smpAgent = a} = subscriber
          NtfPushServer {pushQ} = pushServer
          SMPClientAgent {smpClients, smpSessions, smpSubWorkers} = a
      srvSubscribers <- getSMPWorkerMetrics a smpSubscribers
      srvClients <- getSMPWorkerMetrics a smpClients
      srvSubWorkers <- getSMPWorkerMetrics a smpSubWorkers
      ntfActiveServiceSubs <- getSMPServiceSubMetrics a activeServiceSubs $ snd . fst
      ntfActiveQueueSubs <- getSMPSubMetrics a activeQueueSubs
      ntfPendingServiceSubs <- getSMPServiceSubMetrics a pendingServiceSubs snd
      ntfPendingQueueSubs <- getSMPSubMetrics a pendingQueueSubs
      smpSessionCount <- M.size <$> readTVarIO smpSessions
      apnsPushQLength <- atomically $ lengthTBQueue pushQ
      pure
        NtfRealTimeMetrics
          { threadsCount,
            srvSubscribers,
            srvClients,
            srvSubWorkers,
            ntfActiveServiceSubs,
            ntfActiveQueueSubs,
            ntfPendingServiceSubs,
            ntfPendingQueueSubs,
            smpSessionCount,
            apnsPushQLength
          }
      where
        getSMPServiceSubMetrics :: forall sub. SMPClientAgent 'NotifierService -> (SMPClientAgent 'NotifierService -> TMap SMPServer (TVar (Maybe sub))) -> (sub -> Int64) -> IO NtfSMPSubMetrics
        getSMPServiceSubMetrics a sel subQueueCount = getSubMetrics_ a sel countSubs
          where
            countSubs :: (NtfSMPSubMetrics, S.Set Text) -> (SMPServer, TVar (Maybe sub)) -> IO (NtfSMPSubMetrics, S.Set Text)
            countSubs acc (srv, serviceSubs) = subMetricsResult a acc srv . fromIntegral . maybe 0 subQueueCount <$> readTVarIO serviceSubs

        getSMPSubMetrics :: SMPClientAgent 'NotifierService -> (SMPClientAgent 'NotifierService -> TMap SMPServer (TMap NotifierId a)) -> IO NtfSMPSubMetrics
        getSMPSubMetrics a sel = getSubMetrics_ a sel countSubs
          where
            countSubs :: (NtfSMPSubMetrics, S.Set Text) -> (SMPServer, TMap NotifierId a) -> IO (NtfSMPSubMetrics, S.Set Text)
            countSubs acc (srv, queueSubs) = subMetricsResult a acc srv . M.size <$> readTVarIO queueSubs

        getSubMetrics_ ::
          SMPClientAgent 'NotifierService ->
          (SMPClientAgent 'NotifierService -> TVar (M.Map SMPServer sub')) ->
          ((NtfSMPSubMetrics, S.Set Text) -> (SMPServer, sub') -> IO (NtfSMPSubMetrics, S.Set Text)) ->
          IO NtfSMPSubMetrics
        getSubMetrics_ a sel countSubs = do
          subs <- readTVarIO $ sel a
          let metrics = NtfSMPSubMetrics {ownSrvSubs = M.empty, otherServers = 0, otherSrvSubCount = 0}
          (metrics', otherSrvs) <- foldM countSubs (metrics, S.empty) $ M.assocs subs
          pure (metrics' :: NtfSMPSubMetrics) {otherServers = S.size otherSrvs}

        subMetricsResult :: SMPClientAgent 'NotifierService -> (NtfSMPSubMetrics, S.Set Text) -> SMPServer -> Int -> (NtfSMPSubMetrics, S.Set Text)
        subMetricsResult a acc@(metrics, !otherSrvs) srv@(SMPServer (h :| _) _ _) cnt
          | isOwnServer a srv =
              let !ownSrvSubs' = M.alter (Just . maybe cnt (+ cnt)) host ownSrvSubs
                  metrics' = metrics {ownSrvSubs = ownSrvSubs'} :: NtfSMPSubMetrics
               in (metrics', otherSrvs)
          | cnt == 0 = acc
          | otherwise =
              let metrics' = metrics {otherSrvSubCount = otherSrvSubCount + cnt} :: NtfSMPSubMetrics
               in (metrics', S.insert host otherSrvs)
          where
            NtfSMPSubMetrics {ownSrvSubs, otherSrvSubCount} = metrics
            host = safeDecodeUtf8 $ strEncode h

        getSMPWorkerMetrics :: SMPClientAgent 'NotifierService -> TMap SMPServer a -> IO NtfSMPWorkerMetrics
        getSMPWorkerMetrics a v = workerMetrics a . M.keys <$> readTVarIO v
        workerMetrics :: SMPClientAgent 'NotifierService -> [SMPServer] -> NtfSMPWorkerMetrics
        workerMetrics a srvs = NtfSMPWorkerMetrics {ownServers = reverse ownSrvs, otherServers}
          where
            (ownSrvs, otherServers) = foldl' countSrv ([], 0) srvs
            countSrv (!own, !other) srv@(SMPServer (h :| _) _ _)
              | isOwnServer a srv = (host : own, other)
              | otherwise = (own, other + 1)
              where
                host = safeDecodeUtf8 $ strEncode h


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
              CPAuth auth -> controlPortAuth h user admin role auth
                where
                  NtfServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin} = cfg
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
                  rtm <- getNtfRealTimeMetrics =<< unliftIO u ask
#if MIN_VERSION_base(4,18,0)
                  hPutStrLn h $ "Threads: " <> show (threadsCount rtm)
#else
                  hPutStrLn h "Threads: not available on GHC 8.10"
#endif
                  putSMPWorkers "SMP subcscribers" $ srvSubscribers rtm
                  putSMPWorkers "SMP clients" $ srvClients rtm
                  putSMPWorkers "SMP subscription workers" $ srvSubWorkers rtm
                  hPutStrLn h $ "SMP sessions count: " <> show (smpSessionCount rtm)
                  putSMPSubs "SMP service subscriptions" $ ntfActiveServiceSubs rtm
                  putSMPSubs "SMP queue subscriptions" $ ntfActiveQueueSubs rtm
                  putSMPSubs "Pending SMP service subscriptions" $ ntfPendingServiceSubs rtm
                  putSMPSubs "Pending SMP queue subscriptions" $ ntfPendingQueueSubs rtm
                  hPutStrLn h $ "Push notifications queue length: " <> show (apnsPushQLength rtm)
                  where
                    putSMPSubs :: Text -> NtfSMPSubMetrics -> IO ()
                    putSMPSubs name NtfSMPSubMetrics {ownSrvSubs, otherServers, otherSrvSubCount} = do
                      showServers name (M.keys ownSrvSubs) otherServers
                      let ownSrvSubCount = M.foldl' (+) 0 ownSrvSubs
                      T.hPutStrLn h $ name <> " total: " <> tshow (ownSrvSubCount + otherSrvSubCount)
                      T.hPutStrLn h $ name <> " on own servers: " <> tshow ownSrvSubCount
                      when (r == CPRAdmin && not (M.null ownSrvSubs)) $
                        forM_ (M.assocs ownSrvSubs) $ \(host, cnt) ->
                          T.hPutStrLn h $ name <> " on " <> host <> ": " <> tshow cnt
                      T.hPutStrLn h $ name <> " on other servers: " <> tshow otherSrvSubCount
                    putSMPWorkers :: Text -> NtfSMPWorkerMetrics -> IO ()
                    putSMPWorkers name NtfSMPWorkerMetrics {ownServers, otherServers} = showServers name ownServers otherServers
                    showServers :: Text -> [Text] -> Int -> IO ()
                    showServers name ownServers otherServers = do
                      T.hPutStrLn h $ name <> " own servers count: " <> tshow (length ownServers)
                      when (r == CPRAdmin) $ T.hPutStrLn h $ name <> " own servers: " <> T.intercalate "," ownServers
                      T.hPutStrLn h $ name <> " other servers count: " <> tshow otherServers
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
resubscribe NtfSubscriber {smpAgent = ca} = do
  st <- asks store
  batchSize <- asks $ subsBatchSize . config
  liftIO $ do
    srvs <- getUsedSMPServers st
    logNote $ "Starting SMP resubscriptions for " <> tshow (length srvs) <> " servers..."
    counts <- mapConcurrently (subscribeSrvSubs ca st batchSize) srvs
    logNote $ "Completed all SMP resubscriptions for " <> tshow (length srvs) <> " servers (" <> tshow (sum counts) <> " subscriptions)"

subscribeSrvSubs :: SMPClientAgent 'NotifierService -> NtfPostgresStore -> Int -> (SMPServer, Int64, Maybe (ServiceId, Int64)) -> IO Int
subscribeSrvSubs ca st batchSize (srv, srvId, service_) = do
  let srvStr = safeDecodeUtf8 (strEncode $ L.head $ host srv)
  logNote $ "Starting SMP resubscriptions for " <> srvStr
  forM_ service_ $ \(serviceId, n) -> do
    logNote $ "Subscribing service to " <> srvStr <> " with " <> tshow n <> " associated queues"
    subscribeServiceNtfs ca srv (serviceId, n)
  n <- subscribeLoop 0 Nothing
  logNote $ "Completed SMP resubscriptions for " <> srvStr <> " (" <> tshow n <> " subscriptions)"
  pure n
  where
    dbBatchSize = batchSize * 100
    subscribeLoop n afterSubId_ =
      getServerNtfSubscriptions st srvId afterSubId_ dbBatchSize >>= \case
        Left _ -> exitFailure
        Right [] -> pure n
        Right subs -> do
          mapM_ (subscribeQueuesNtfs ca srv . L.map snd) $ toChunks batchSize subs
          let len = length subs
              n' = n + len
              afterSubId_' = Just $ fst $ last subs
          if len < dbBatchSize then pure n' else subscribeLoop n' afterSubId_'

-- this function is concurrency-safe - only onle subscriber per server can be created at a time,
-- other threads would wait for the first thread to create it.
subscribeNtfs :: NtfSubscriber -> NtfPostgresStore -> SMPServer -> Int64 -> ServerNtfSub -> IO ()
subscribeNtfs NtfSubscriber {smpSubscribers, subscriberSeq, smpAgent = ca} st smpServer srvId ntfSub =
  getSubscriberVar
    >>= either createSMPSubscriber waitForSMPSubscriber
    >>= mapM_ (\sub -> atomically $ writeTQueue (subscriberSubQ sub) ntfSub)
  where
    getSubscriberVar :: IO (Either SMPSubscriberVar SMPSubscriberVar)
    getSubscriberVar = atomically . getSessVar subscriberSeq smpServer smpSubscribers =<< getCurrentTime

    createSMPSubscriber :: SMPSubscriberVar -> IO (Maybe SMPSubscriber)
    createSMPSubscriber v =
      E.handle (\(e :: SomeException) -> logError ("SMP subscriber exception: " <> tshow e) >> removeSubscriber v) $ do
        q <- newTQueueIO
        tId <- mkWeakThreadId =<< forkIO (runSMPSubscriber smpServer srvId q)
        let sub = SMPSubscriber {smpServer, smpServerId = srvId, subscriberSubQ = q, subThreadId = tId}
        atomically $ putTMVar (sessionVar v) sub -- this makes it available for other threads
        pure $ Just sub

    waitForSMPSubscriber :: SMPSubscriberVar -> IO (Maybe SMPSubscriber)
    waitForSMPSubscriber v =
      -- reading without timeout first to avoid creating extra thread for timeout
      atomically (tryReadTMVar $ sessionVar v)
        >>= maybe (timeout 10000000 $ atomically $ readTMVar $ sessionVar v) (pure . Just)
        >>= maybe (logError "SMP subscriber timeout" >> removeSubscriber v) (pure . Just)

    -- create/waitForSMPSubscriber should never throw, removing it from map in case it did
    removeSubscriber v = do
      atomically $ removeSessVar v smpServer smpSubscribers
      pure Nothing

    runSMPSubscriber :: SMPServer -> Int64 -> TQueue ServerNtfSub -> IO ()
    runSMPSubscriber smpServer' srvId' q = forever $ do
      -- TODO [ntfdb] possibly, the subscriptions can be batched here and sent every say 5 seconds
      -- this should be analysed once we have prometheus stats
      (nId, sub) <- atomically $ readTQueue q
      void $ updateSubStatus st srvId' nId NSPending
      subscribeQueuesNtfs ca smpServer' [sub]

ntfSubscriber :: NtfSubscriber -> M ()
ntfSubscriber NtfSubscriber {smpAgent = ca@SMPClientAgent {msgQ, agentQ}} =
  race_ receiveSMP receiveAgent
  where
    receiveSMP = do
      st <- asks store
      NtfPushServer {pushQ} <- asks pushServer
      stats <- asks serverStats
      liftIO $ forever $ do
        ((_, srv@(SMPServer (h :| _) _ _), _), _thVersion, sessionId, ts) <- atomically $ readTBQueue msgQ
        forM ts $ \(ntfId, t) -> case t of
          STUnexpectedError e -> logError $ "SMP client unexpected error: " <> tshow e -- uncorrelated response, should not happen
          STResponse {} -> pure () -- it was already reported as timeout error
          STEvent msgOrErr -> do
            let smpQueue = SMPQueueNtf srv ntfId
            case msgOrErr of
              Right (SMP.NMSG nmsgNonce encNMsgMeta) -> do
                ntfTs <- getSystemTime
                updatePeriodStats (activeSubs stats) ntfId
                let newNtf = PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}
                    srvHost_ = if isOwnServer ca srv then Just (safeDecodeUtf8 $ strEncode h) else Nothing
                addTokenLastNtf st newNtf >>= \case
                  Right (tkn, lastNtfs) -> do
                    atomically $ writeTBQueue pushQ (srvHost_, tkn, PNMessage lastNtfs)
                    incNtfStat_ stats ntfReceived
                    mapM_ (`incServerStat` ntfReceivedOwn stats) srvHost_
                  Left AUTH -> do
                    incNtfStat_ stats ntfReceivedAuth
                    mapM_ (`incServerStat` ntfReceivedAuthOwn stats) srvHost_
                  Left _ -> pure ()
              Right SMP.END ->
                whenM (atomically $ activeClientSession' ca sessionId srv) $
                  void $ updateSrvSubStatus st smpQueue NSEnd
              Right SMP.DELD ->
                void $ updateSrvSubStatus st smpQueue NSDeleted
              Right (SMP.ERR e) -> logError $ "SMP server error: " <> tshow e
              Right _ -> logError "SMP server unexpected response"
              Left e -> logError $ "SMP client error: " <> tshow e

    receiveAgent = do
      st <- asks store
      batchSize <- asks $ subsBatchSize . config
      liftIO $ forever $
        atomically (readTBQueue agentQ) >>= \case
          CAConnected srv serviceId -> do
            let asService = if isJust serviceId then "as service " else ""
            logInfo $ "SMP server reconnected " <> asService <> showServer' srv
          CADisconnected srv nIds -> do
            updated <- batchUpdateSrvSubStatus st srv Nothing nIds NSInactive
            logSubStatus srv "disconnected" (L.length nIds) updated
          CASubscribed srv serviceId nIds -> do
            updated <- batchUpdateSrvSubStatus st srv serviceId nIds NSActive
            let asService = if isJust serviceId then " as service" else ""
            logSubStatus srv ("subscribed" <> asService) (L.length nIds) updated
          CASubError srv errs -> do
            forM_ (L.nonEmpty $ mapMaybe (\(nId, err) -> (nId,) <$> queueSubErrorStatus err) $ L.toList errs) $ \subStatuses -> do
              updated <- batchUpdateSrvSubErrors st srv subStatuses
              logSubErrors srv subStatuses updated
              -- TODO [certs] resubscribe queues with statuses NSErr and NSService
          CAServiceDisconnected srv serviceSub ->
            logNote $ "SMP server service disconnected " <> showService srv serviceSub
          CAServiceSubscribed srv serviceSub@(_, expected) n
            | expected == n -> logNote msg
            | otherwise -> logWarn $ msg <> ", confirmed subs: " <> tshow n
            where
              msg = "SMP server service subscribed " <> showService srv serviceSub
          CAServiceSubError srv serviceSub e ->
            -- Errors that require re-subscribing queues directly are reported as CAServiceUnavailable.
            -- See smpSubscribeService in Simplex.Messaging.Client.Agent
            logError $ "SMP server service subscription error " <> showService srv serviceSub <> ": " <> tshow e
          CAServiceUnavailable srv serviceSub -> do
            logError $ "SMP server service unavailable: " <> showService srv serviceSub
            removeServiceAssociation st srv >>= \case
              Right (srvId, updated) -> do
                logSubStatus srv "removed service association" updated updated
                void $ subscribeSrvSubs ca st batchSize (srv, srvId, Nothing)
              Left e -> logError $ "SMP server update and resubscription error " <> tshow e
      where
        showService srv (serviceId, n) = showServer' srv  <> ", service ID " <> decodeLatin1 (strEncode serviceId) <> ", " <> tshow n <> " subs"

    logSubErrors :: SMPServer -> NonEmpty (SMP.NotifierId, NtfSubStatus) -> Int -> IO ()
    logSubErrors srv subs updated = forM_ (L.group $ L.sort $ L.map snd subs) $ \ss -> do
      logError $ "SMP server subscription errors " <> showServer' srv <> ": " <> tshow (L.head ss) <> " (" <> tshow (length ss) <> " errors, " <> tshow updated <> " subs updated)"

    queueSubErrorStatus :: SMPClientError -> Maybe NtfSubStatus
    queueSubErrorStatus = \case
      PCEProtocolError AUTH -> Just NSAuth
      -- TODO [certs] we could allow making individual subscriptions within service session to handle SERVICE error.
      -- This would require full stack changes in SMP server, SMP client and SMP service agent.
      PCEProtocolError SERVICE -> Just NSService
      PCEProtocolError e -> updateErr "SMP error " e
      PCEResponseError e -> updateErr "ResponseError " e
      PCEUnexpectedResponse r -> updateErr "UnexpectedResponse " r
      PCETransportError e -> updateErr "TransportError " e
      PCECryptoError e -> updateErr "CryptoError " e
      PCEIncompatibleHost -> Just $ NSErr "IncompatibleHost"
      PCEServiceUnavailable -> Just NSService -- this error should not happen on individual subscriptions
      PCEResponseTimeout -> Nothing
      PCENetworkError -> Nothing
      PCEIOError _ -> Nothing
      where
        -- Note on moving to PostgreSQL: the idea of logging errors without e is removed here
        updateErr :: Show e => ByteString -> e -> Maybe NtfSubStatus
        updateErr errType e = Just $ NSErr $ errType <> bshow e

logSubStatus :: SMPServer -> T.Text -> Int -> Int -> IO ()
logSubStatus srv event n updated =
  logInfo $ "SMP server " <> event <> " " <> showServer' srv <> " (" <> tshow n <> " subs, " <> tshow updated <> " subs updated)"

showServer' :: SMPServer -> Text
showServer' = decodeLatin1 . strEncode . host

ntfPush :: NtfPushServer -> M ()
ntfPush s@NtfPushServer {pushQ} = forever $ do
  (srvHost_, tkn@NtfTknRec {ntfTknId, token = t@(APNSDeviceToken pp _), tknStatus}, ntf) <- atomically (readTBQueue pushQ)
  liftIO $ logDebug $ "sending push notification to " <> T.pack (show pp)
  st <- asks store
  case ntf of
    PNVerification _ ->
      liftIO (deliverNotification st pp tkn ntf) >>= \case
        Right _ -> do
          void $ liftIO $ setTknStatusConfirmed st tkn
          incNtfStatT t ntfVrfDelivered
        Left _ -> incNtfStatT t ntfVrfFailed
    PNCheckMessages -> do
      liftIO (deliverNotification st pp tkn ntf) >>= \case
        Right _ -> do
          void $ liftIO $ updateTokenCronSentAt st ntfTknId . systemSeconds =<< getSystemTime
          incNtfStatT t ntfCronDelivered
        Left _ -> incNtfStatT t ntfCronFailed
    PNMessage {} -> checkActiveTkn tknStatus $ do
      stats <- asks serverStats
      liftIO $ updatePeriodStats (activeTokens stats) ntfTknId
      liftIO (deliverNotification st pp tkn ntf) >>= \case
        Left _ -> do
          incNtfStatT t ntfFailed
          liftIO $ mapM_ (`incServerStat` ntfFailedOwn stats) srvHost_
        Right () -> do
          incNtfStatT t ntfDelivered
          liftIO $ mapM_ (`incServerStat` ntfDeliveredOwn stats) srvHost_

  where
    checkActiveTkn :: NtfTknStatus -> M () -> M ()
    checkActiveTkn status action
      | status == NTActive = action
      | otherwise = liftIO $ logError "bad notification token status"
    deliverNotification :: NtfPostgresStore -> PushProvider -> NtfTknRec -> PushNotification -> IO (Either PushProviderError ())
    deliverNotification st pp tkn@NtfTknRec {ntfTknId} ntf = do
      deliver <- getPushClient s pp
      runExceptT (deliver tkn ntf) >>= \case
        Right _ -> pure $ Right ()
        Left e -> case e of
          PPConnection _ -> retryDeliver
          PPRetryLater -> retryDeliver
          PPCryptoError _ -> err e
          PPResponseError {} -> err e
          PPTokenInvalid r -> do
            void $ updateTknStatus st tkn $ NTInvalid $ Just r
            err e
          PPPermanentError -> err e
          PPInvalidPusher -> err e
      where
        retryDeliver :: IO (Either PushProviderError ())
        retryDeliver = do
          deliver <- newPushClient s pp
          runExceptT (deliver tkn ntf) >>= \case
            Right _ -> pure $ Right ()
            Left e -> case e of
              PPTokenInvalid r -> do
                void $ updateTknStatus st tkn $ NTInvalid $ Just r
                err e
              _ -> err e
        err e = logError ("Push provider error (" <> tshow pp <> ", " <> tshow ntfTknId <> "): " <> tshow e) $> Left e

periodicNtfsThread :: NtfPushServer -> M ()
periodicNtfsThread NtfPushServer {pushQ} = do
  st <- asks store
  ntfsInterval <- asks $ periodicNtfsInterval . config
  let interval = 1000000 * ntfsInterval
  liftIO $ forever $ do
    threadDelay interval
    now <- systemSeconds <$> getSystemTime
    cnt <- withPeriodicNtfTokens st now $ \tkn -> atomically $ writeTBQueue pushQ (Nothing, tkn, PNCheckMessages)
    logNote $ "Scheduled periodic notifications: " <> tshow cnt

runNtfClientTransport :: Transport c => THandleNTF c 'TServer -> M ()
runNtfClientTransport th@THandle {params} = do
  qSize <- asks $ clientQSize . config
  ts <- liftIO getSystemTime
  c <- liftIO $ newNtfServerClient qSize params ts
  s <- asks subscriber
  ps <- asks pushServer
  expCfg <- asks $ inactiveClientExpiration . config
  st <- asks store
  raceAny_ ([liftIO $ send th c, client c s ps, liftIO $ receive st th c] <> disconnectThread_ c expCfg)
    `finally` liftIO (clientDisconnected c)
  where
    disconnectThread_ c (Just expCfg) = [liftIO $ disconnectTransport th (rcvActiveAt c) (sndActiveAt c) expCfg (pure True)]
    disconnectThread_ _ _ = []

clientDisconnected :: NtfServerClient -> IO ()
clientDisconnected NtfServerClient {connected} = atomically $ writeTVar connected False

receive :: Transport c => NtfPostgresStore -> THandleNTF c 'TServer -> NtfServerClient -> IO ()
receive st th@THandle {params = THandleParams {thAuth}} NtfServerClient {rcvQ, sndQ, rcvActiveAt} = forever $ do
  ts <- L.toList <$> tGetServer th
  atomically . (writeTVar rcvActiveAt $!) =<< getSystemTime
  (errs, cmds) <- partitionEithers <$> mapM cmdAction ts
  write sndQ errs
  write rcvQ cmds
  where
    cmdAction = \case
      Left (corrId, entId, e) -> do
        logError $ "invalid client request: " <> tshow e
        pure $ Left (corrId, entId, NRErr e)
      Right t@(_, _, (corrId, entId, _)) ->
        verified =<< verifyNtfTransmission st thAuth t
        where
          verified = \case
            VRVerified req -> pure $ Right req
            VRFailed e -> do
              logError "unauthorized client request"
              pure $ Left (corrId, entId, NRErr e)
    write q = mapM_ (atomically . writeTBQueue q) . L.nonEmpty

send :: Transport c => THandleNTF c 'TServer -> NtfServerClient -> IO ()
send h@THandle {params} NtfServerClient {sndQ, sndActiveAt} = forever $ do
  ts <- atomically $ readTBQueue sndQ
  void $ tPut h $ L.map (\t -> Right (Nothing, encodeTransmission params t)) ts
  atomically . (writeTVar sndActiveAt $!) =<< getSystemTime

data VerificationResult = VRVerified NtfRequest | VRFailed ErrorType

verifyNtfTransmission :: NtfPostgresStore -> Maybe (THandleAuth 'TServer) -> SignedTransmission NtfCmd -> IO VerificationResult
verifyNtfTransmission st thAuth (tAuth, authorized, (corrId, entId, cmd)) = case cmd of
  NtfCmd SToken c@(TNEW tkn@(NewNtfTkn _ k _))
    | verifyCmdAuthorization thAuth tAuth authorized corrId k ->
        result <$> findNtfTokenRegistration st tkn
    | otherwise -> pure $ VRFailed AUTH
    where
      result = \case
        Right (Just t@NtfTknRec {tknVerifyKey})
          -- keys will be the same because of condition in `findNtfTokenRegistration`
          | k == tknVerifyKey -> VRVerified $ tknCmd t c
          | otherwise -> VRFailed AUTH
        Right Nothing -> VRVerified (NtfReqNew corrId (ANE SToken tkn))
        Left e -> VRFailed e
  NtfCmd SToken c -> either err verify <$> getNtfToken st entId
    where
      verify t = verifyToken t $ tknCmd t c
  NtfCmd SSubscription c@(SNEW sub@(NewNtfSub tknId smpQueue _)) ->
    either err verify <$> findNtfSubscription st tknId smpQueue
    where
      verify (t, s_) = verifyToken t $ case s_ of
        Nothing -> NtfReqNew corrId (ANE SSubscription sub)
        Just s -> subCmd s c
  NtfCmd SSubscription PING -> pure $ VRVerified $ NtfReqPing corrId entId
  NtfCmd SSubscription c -> either err verify <$> getNtfSubscription st entId
    where
      verify (t, s) = verifyToken t $ subCmd s c
  where
    tknCmd t c = NtfReqCmd SToken (NtfTkn t) (corrId, entId, c)
    subCmd s c = NtfReqCmd SSubscription (NtfSub s) (corrId, entId, c)
    verifyToken :: NtfTknRec -> NtfRequest -> VerificationResult
    verifyToken NtfTknRec {tknVerifyKey} r
      | verifyCmdAuthorization thAuth tAuth authorized corrId tknVerifyKey = VRVerified r
      | otherwise = VRFailed AUTH
    err = \case -- signature verification for AUTH errors mitigates timing attacks for existence checks
      AUTH -> dummyVerifyCmd thAuth tAuth authorized corrId `seq` VRFailed AUTH
      e -> VRFailed e

client :: NtfServerClient -> NtfSubscriber -> NtfPushServer -> M ()
client NtfServerClient {rcvQ, sndQ} ns@NtfSubscriber {smpAgent = ca} NtfPushServer {pushQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= mapM processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: NtfRequest -> M (Transmission NtfResponse)
    processCommand = \case
      NtfReqNew corrId (ANE SToken newTkn@(NewNtfTkn token _ dhPubKey)) -> (corrId,NoEntity,) <$> do
        logDebug "TNEW - new token"
        (srvDhPubKey, srvDhPrivKey) <- atomically . C.generateKeyPair =<< asks random
        let dhSecret = C.dh' dhPubKey srvDhPrivKey
        tknId <- getId
        regCode <- getRegCode
        ts <- liftIO $ getSystemDate
        let tkn = mkNtfTknRec tknId newTkn srvDhPrivKey dhSecret regCode ts
        withNtfStore (`addNtfToken` tkn) $ \_ -> do
          atomically $ writeTBQueue pushQ (Nothing, tkn, PNVerification regCode)
          incNtfStatT token ntfVrfQueued
          incNtfStatT token tknCreated
          pure $ NRTknId tknId srvDhPubKey
      NtfReqCmd SToken (NtfTkn tkn@NtfTknRec {token, ntfTknId, tknStatus, tknRegCode, tknDhSecret, tknDhPrivKey}) (corrId, tknId, cmd) -> do
        (corrId,tknId,) <$> case cmd of
          TNEW (NewNtfTkn _ _ dhPubKey) -> do
            logDebug "TNEW - registered token"
            let dhSecret = C.dh' dhPubKey tknDhPrivKey
            -- it is required that DH secret is the same, to avoid failed verifications if notification is delaying
            if
              | tknDhSecret /= dhSecret -> pure $ NRErr AUTH
              | allowTokenVerification tknStatus -> sendVerification
              | otherwise -> withNtfStore (\st -> updateTknStatus st tkn NTRegistered) $ \_ -> sendVerification
            where
              sendVerification = do
                atomically $ writeTBQueue pushQ (Nothing, tkn, PNVerification tknRegCode)
                incNtfStatT token ntfVrfQueued
                pure $ NRTknId ntfTknId $ C.publicKey tknDhPrivKey
          TVFY code -- this allows repeated verification for cases when client connection dropped before server response
            | allowTokenVerification tknStatus && tknRegCode == code -> do
                logDebug "TVFY - token verified"
                withNtfStore (`setTokenActive` tkn) $ \_ -> NROk <$ incNtfStatT token tknVerified
            | otherwise -> do
                logDebug "TVFY - incorrect code or token status"
                pure $ NRErr AUTH
          TCHK -> do
            logDebug "TCHK"
            pure $ NRTkn tknStatus
          TRPL token' -> do
            logDebug "TRPL - replace token"
            regCode <- getRegCode
            let tkn' = tkn {token = token', tknStatus = NTRegistered, tknRegCode = regCode}
            withNtfStore (`replaceNtfToken` tkn') $ \_ -> do
              atomically $ writeTBQueue pushQ (Nothing, tkn', PNVerification regCode)
              incNtfStatT token ntfVrfQueued
              incNtfStatT token tknReplaced
              pure NROk
          TDEL -> do
            logDebug "TDEL"
            withNtfStore (`deleteNtfToken` tknId) $ \ss -> do
              forM_ ss $ \(smpServer, nIds) -> do
                atomically $ removeActiveSubs ca smpServer nIds
                atomically $ removePendingSubs ca smpServer nIds
              incNtfStatT token tknDeleted
              pure NROk
          TCRN 0 -> do
            logDebug "TCRN 0"
            withNtfStore (\st -> updateTknCronInterval st ntfTknId 0) $ \_ -> pure NROk
          TCRN int
            | int < 20 -> pure $ NRErr QUOTA
            | otherwise -> do
                logDebug "TCRN"
                withNtfStore (\st -> updateTknCronInterval st ntfTknId int) $ \_ -> pure NROk
      NtfReqNew corrId (ANE SSubscription newSub@(NewNtfSub _ (SMPQueueNtf srv nId) nKey)) -> do
        logDebug "SNEW - new subscription"
        subId <- getId
        let sub = mkNtfSubRec subId newSub
        resp <-
          withNtfStore (`addNtfSubscription` sub) $ \case
            (srvId, True) -> do
              st <- asks store
              liftIO $ subscribeNtfs ns st srv srvId (subId, (nId, nKey))
              incNtfStat subCreated
              pure $ NRSubId subId
            (_, False) -> pure $ NRErr AUTH
        pure (corrId, NoEntity, resp)
      NtfReqCmd SSubscription (NtfSub NtfSubRec {ntfSubId, smpQueue = SMPQueueNtf {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
        (corrId,subId,) <$> case cmd of
          SNEW (NewNtfSub _ _ notifierKey) -> do
            logDebug "SNEW - existing subscription"
            pure $
              if notifierKey == registeredNKey
                then NRSubId ntfSubId
                else NRErr AUTH
          SCHK -> do
            logDebug "SCHK"
            pure $ NRSub subStatus
          SDEL -> do
            logDebug "SDEL"
            withNtfStore (`deleteNtfSubscription` subId) $ \_ -> do
              atomically $ removeActiveSub ca smpServer notifierId
              atomically $ removePendingSub ca smpServer notifierId
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

withNtfStore :: (NtfPostgresStore -> IO (Either ErrorType a)) -> (a -> M NtfResponse) -> M NtfResponse
withNtfStore stAction continue = do
  st <- asks store
  liftIO (stAction st) >>= \case
    Left e -> pure $ NRErr e
    Right a -> continue a

incNtfStatT :: DeviceToken -> (NtfServerStats -> IORef Int) -> M ()
incNtfStatT (APNSDeviceToken PPApnsNull _) _ = pure ()
incNtfStatT _ statSel = incNtfStat statSel
{-# INLINE incNtfStatT #-}

incNtfStat :: (NtfServerStats -> IORef Int) -> M ()
incNtfStat statSel = asks serverStats >>= liftIO . (`incNtfStat_` statSel)
{-# INLINE incNtfStat #-}

incNtfStat_ :: NtfServerStats -> (NtfServerStats -> IORef Int) -> IO ()
incNtfStat_ stats statSel = atomicModifyIORef'_ (statSel stats) (+ 1)
{-# INLINE incNtfStat_ #-}

restoreServerLastNtfs :: NtfSTMStore -> FilePath -> IO ()
restoreServerLastNtfs st f =
  whenM (doesFileExist f) $ do
    logNote $ "restoring last notifications from file " <> T.pack f
    runExceptT (liftIO (B.readFile f) >>= mapM restoreNtf . B.lines) >>= \case
      Left e -> do
        logError . T.pack $ "error restoring last notifications: " <> e
        exitFailure
      Right _ -> do
        renameFile f $ f <> ".bak"
        logNote "last notifications restored"
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
      logNote $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logNote "server stats saved"

restoreServerStats :: M ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logNote $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d -> do
          s <- asks serverStats
          liftIO $ setNtfServerStats s d
          renameFile f $ f <> ".bak"
          logNote "server stats restored"
        Left e -> do
          logNote $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
