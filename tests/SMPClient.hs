{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPClient where

import Control.Logger.Simple (LogLevel (..))
import Control.Monad.Except (runExceptT)
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client (ProtocolClientConfig (..), chooseTransportHost, defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import qualified Simplex.Messaging.Transport.Client as Client
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal
import System.Environment (lookupEnv)
import System.Info (os)
import Test.Hspec hiding (fit, it)
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM (TMVar, atomically, newEmptyTMVarIO, putTMVar, takeTMVar)
import UnliftIO.Timeout (timeout)
import Util

#if defined(dbServerPostgres)
import Database.PostgreSQL.Simple (defaultConnectInfo)
#endif

#if defined(dbPostgres) || defined(dbServerPostgres)
import Database.PostgreSQL.Simple (ConnectInfo (..))
import Simplex.Messaging.Agent.Store.Postgres.Util (createDBAndUserIfNotExists, dropDatabaseAndUser)
#endif

testHost :: NonEmpty TransportHost
testHost = "localhost"

testHost2 :: NonEmpty TransportHost
testHost2 = "127.0.0.1"

testPort :: ServiceName
testPort = "5001"

testPort2 :: ServiceName
testPort2 = "5002"

ntfTestPort :: ServiceName
ntfTestPort = "6001"

ntfTestPort2 :: ServiceName
ntfTestPort2 = "6002"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

testStoreLogFile :: FilePath
testStoreLogFile = "tests/tmp/smp-server-store.log"

testStoreLogFile2 :: FilePath
testStoreLogFile2 = "tests/tmp/smp-server-store.log.2"

testStoreDBOpts :: DBOpts
testStoreDBOpts =
  DBOpts
    { connstr = testServerDBConnstr,
      schema = "smp_server",
      poolSize = 3,
      createSchema = True
    }

testStoreDBOpts2 :: DBOpts
testStoreDBOpts2 = testStoreDBOpts {schema = "smp_server2"}

testServerDBConnstr :: ByteString
testServerDBConnstr = "postgresql://test_server_user@/test_server_db"

#if defined(dbServerPostgres)
testServerDBConnectInfo :: ConnectInfo
testServerDBConnectInfo =
  defaultConnectInfo {
    connectUser = "test_server_user",
    connectDatabase = "test_server_db"
  }
#endif

testStoreMsgsFile :: FilePath
testStoreMsgsFile = "tests/tmp/smp-server-messages.log"

testStoreMsgsFile2 :: FilePath
testStoreMsgsFile2 = "tests/tmp/smp-server-messages.log.2"

testStoreMsgsDir :: FilePath
testStoreMsgsDir = "tests/tmp/messages"

testStoreMsgsDir2 :: FilePath
testStoreMsgsDir2 = "tests/tmp/messages.2"

testStoreNtfsFile :: FilePath
testStoreNtfsFile = "tests/tmp/smp-server-ntfs.log"

testStoreNtfsFile2 :: FilePath
testStoreNtfsFile2 = "tests/tmp/smp-server-ntfs.log.2"

testPrometheusMetricsFile :: FilePath
testPrometheusMetricsFile = "tests/tmp/smp-server-metrics.txt"

testServerStatsBackupFile :: FilePath
testServerStatsBackupFile = "tests/tmp/smp-server-stats.log"

xit' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit' d = if os == "linux" then skip "skipped on Linux" . it d else it d

xit'' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit'' d = skipOnCI . it d

skipOnCI :: SpecWith a -> SpecWith a
skipOnCI t =
  runIO (lookupEnv "CI") >>= \case
    Just "true" -> skip "skipped on CI" t
    _ -> t

testSMPClient :: Transport c => (THandleSMP c 'TClient -> IO a) -> IO a
testSMPClient = testSMPClientVR supportedClientSMPRelayVRange

testSMPClientVR :: Transport c => VersionRangeSMP -> (THandleSMP c 'TClient -> IO a) -> IO a
testSMPClientVR vr client = do
  Right useHost <- pure $ chooseTransportHost defaultNetworkConfig testHost
  testSMPClient_ useHost testPort vr client

testSMPClient_ :: Transport c => TransportHost -> ServiceName -> VersionRangeSMP -> (THandleSMP c 'TClient -> IO a) -> IO a
testSMPClient_ host port vr client = do
  let tcConfig = defaultTransportClientConfig {Client.alpn = clientALPN}
  runTransportClient tcConfig Nothing host port (Just testKeyHash) $ \h ->
    runExceptT (smpClientHandshake h Nothing testKeyHash vr False) >>= \case
      Right th -> client th
      Left e -> error $ show e
  where
    clientALPN
      | authCmdsSMPVersion `isCompatible` vr = Just supportedSMPHandshakes
      | otherwise = Nothing

cfg :: ServerConfig
cfg = cfgMS (ASType SQSMemory SMSJournal)

cfgJ2 :: ServerConfig
cfgJ2 = journalCfg cfg testStoreLogFile2 testStoreMsgsDir2

cfgJ2QS :: SQSType s -> ServerConfig
cfgJ2QS = \case
  SQSMemory -> journalCfg (cfgMS $ ASType SQSMemory SMSJournal) testStoreLogFile2 testStoreMsgsDir2
  SQSPostgres -> journalCfgDB (cfgMS $ ASType SQSPostgres SMSJournal) testStoreDBOpts2 testStoreMsgsDir2

journalCfg :: ServerConfig -> FilePath -> FilePath -> ServerConfig
journalCfg cfg' storeLogFile storeMsgsPath = cfg' {serverStoreCfg = ASSCfg SQSMemory SMSJournal SSCMemoryJournal {storeLogFile, storeMsgsPath}}

journalCfgDB :: ServerConfig -> DBOpts -> FilePath -> ServerConfig
journalCfgDB cfg' dbOpts storeMsgsPath' =
  let storeCfg = PostgresStoreCfg {dbOpts, dbStoreLogPath = Nothing, confirmMigrations = MCYesUp, deletedTTL = 86400}
   in cfg' {serverStoreCfg = ASSCfg SQSPostgres SMSJournal SSCDatabaseJournal {storeCfg, storeMsgsPath'}}

cfgMS :: AStoreType -> ServerConfig
cfgMS msType =
  ServerConfig
    { transports = [],
      smpHandshakeTimeout = 60000000,
      tbqSize = 1,
      msgQueueQuota = 4,
      maxJournalMsgCount = 5,
      maxJournalStateLines = 2,
      queueIdBytes = 24,
      msgIdBytes = 24,
      serverStoreCfg = serverStoreConfig msType,
      storeNtfsFile = Nothing,
      allowNewQueues = True,
      newQueueBasicAuth = Nothing,
      controlPortUserAuth = Nothing,
      controlPortAdminAuth = Nothing,
      messageExpiration = Just defaultMessageExpiration,
      expireMessagesOnStart = True,
      idleQueueInterval = defaultIdleQueueInterval,
      notificationExpiration = defaultNtfExpiration,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/tmp/smp-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      prometheusInterval = Nothing,
      prometheusMetricsFile = testPrometheusMetricsFile,
      pendingENDInterval = 500000,
      ntfDeliveryInterval = 200000,
      smpCredentials =
        ServerCredentials
          { caCertificateFile = Just "tests/fixtures/ca.crt",
            privateKeyFile = "tests/fixtures/server.key",
            certificateFile = "tests/fixtures/server.crt"
          },
      httpCredentials = Nothing,
      smpServerVRange = supportedServerSMPRelayVRange,
      transportConfig = defaultTransportServerConfig,
      controlPort = Nothing,
      smpAgentCfg = defaultSMPClientAgentConfig {persistErrorInterval = 1}, -- seconds
      allowSMPProxy = False,
      serverClientConcurrency = 2,
      information = Nothing,
      startOptions = defaultStartOptions
    }

defaultStartOptions :: StartOptions
defaultStartOptions = StartOptions {maintenance = False, compactLog = False, logLevel = LogError, skipWarnings = False, confirmMigrations = MCYesUp}

serverStoreConfig :: AStoreType -> AServerStoreCfg
serverStoreConfig = serverStoreConfig_ False

serverStoreConfig_ :: Bool -> AStoreType -> AServerStoreCfg
serverStoreConfig_ useDbStoreLog = \case
  ASType SQSMemory SMSMemory ->
    ASSCfg SQSMemory SMSMemory $ SSCMemory $ Just StorePaths {storeLogFile = testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile}
  ASType SQSMemory SMSJournal ->
    ASSCfg SQSMemory SMSJournal $ SSCMemoryJournal {storeLogFile = testStoreLogFile, storeMsgsPath = testStoreMsgsDir}
  ASType SQSPostgres SMSJournal ->
    let dbStoreLogPath = if useDbStoreLog then Just testStoreLogFile else Nothing
        storeCfg = PostgresStoreCfg {dbOpts = testStoreDBOpts, dbStoreLogPath, confirmMigrations = MCYesUp, deletedTTL = 86400}
     in ASSCfg SQSPostgres SMSJournal SSCDatabaseJournal {storeCfg, storeMsgsPath' = testStoreMsgsDir}

cfgV7 :: ServerConfig
cfgV7 = cfg {smpServerVRange = mkVersionRange minServerSMPRelayVersion authCmdsSMPVersion}

cfgV8 :: AStoreType -> ServerConfig
cfgV8 msType = (cfgMS msType) {smpServerVRange = mkVersionRange minServerSMPRelayVersion sendingProxySMPVersion}

cfgVPrev :: AStoreType -> ServerConfig
cfgVPrev msType = (cfgMS msType) {smpServerVRange = prevRange $ smpServerVRange cfg}

prevRange :: VersionRange v -> VersionRange v
prevRange vr = vr {maxVersion = max (minVersion vr) (prevVersion $ maxVersion vr)}

prevVersion :: Version v -> Version v
prevVersion (Version v) = Version (v - 1)

proxyCfg :: ServerConfig
proxyCfg = proxyCfgMS (ASType SQSMemory SMSJournal)

proxyCfgMS :: AStoreType -> ServerConfig
proxyCfgMS msType =
  (cfgMS msType)
    { allowSMPProxy = True,
      smpAgentCfg = smpAgentCfg' {smpCfg = (smpCfg smpAgentCfg') {agreeSecret = True, proxyServer = True, serverVRange = supportedProxyClientSMPRelayVRange}}
    }
  where
    smpAgentCfg' = smpAgentCfg cfg

proxyCfgJ2 :: ServerConfig
proxyCfgJ2 = journalCfg proxyCfg testStoreLogFile2 testStoreMsgsDir2

proxyCfgJ2QS :: SQSType s -> ServerConfig
proxyCfgJ2QS = \case
  SQSMemory -> journalCfg (proxyCfgMS $ ASType SQSMemory SMSJournal) testStoreLogFile2 testStoreMsgsDir2
  SQSPostgres -> journalCfgDB (proxyCfgMS $ ASType SQSPostgres SMSJournal) testStoreDBOpts2 testStoreMsgsDir2

proxyVRangeV8 :: VersionRangeSMP
proxyVRangeV8 = mkVersionRange minServerSMPRelayVersion sendingProxySMPVersion

withSmpServerStoreMsgLogOn :: HasCallStack => (ATransport, AStoreType) -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreMsgLogOn (t, msType) =
  withSmpServerConfigOn t (cfgMS msType) {storeNtfsFile = Just testStoreNtfsFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerStoreLogOn :: HasCallStack => (ATransport, AStoreType) -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreLogOn (t, msType) = withSmpServerConfigOn t (cfgMS msType) {serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerConfigOn :: HasCallStack => ATransport -> ServerConfig -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerConfigOn t cfg' port' =
  serverBracket
    (\started -> runSMPServerBlocking started cfg' {transports = [(port', t, False)]} Nothing)
    (threadDelay 10000)

withSmpServerThreadOn :: HasCallStack => (ATransport, AStoreType) -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerThreadOn (t, msType) = withSmpServerConfigOn t (cfgMS msType)

serverBracket :: HasCallStack => (TMVar Bool -> IO ()) -> IO () -> (HasCallStack => ThreadId -> IO a) -> IO a
serverBracket process afterProcess f = do
  started <- newEmptyTMVarIO
  E.bracket
    (forkIOWithUnmask (\unmask -> unmask (process started) `E.catchAny` handleStartError started))
    (\t -> killThread t >> afterProcess >> waitFor started "stop")
    (\t -> waitFor started "start" >> f t >>= \r -> r <$ threadDelay 100000)
  where
    -- it putTMVar is called twise to unlock both parts of the bracket in case of start failure
    handleStartError started e = do
      atomically $ putTMVar started False
      atomically $ putTMVar started False
      E.throwIO e
    waitFor started s =
      5_000_000 `timeout` atomically (takeTMVar started) >>= \case
        Nothing -> error $ "server did not " <> s
        _ -> pure ()

withSmpServerOn :: HasCallStack => (ATransport, AStoreType) -> ServiceName -> IO a -> IO a
withSmpServerOn ps port' = withSmpServerThreadOn ps port' . const

withSmpServer :: HasCallStack => (ATransport, AStoreType) -> IO a -> IO a
withSmpServer ps = withSmpServerOn ps testPort

withSmpServerProxy :: HasCallStack => (ATransport, AStoreType) -> IO a -> IO a
withSmpServerProxy (t, msType) = withSmpServerConfigOn t (proxyCfgMS msType) testPort . const

withSmpServers2 :: HasCallStack => (ATransport, AStoreType) -> IO a -> IO a
withSmpServers2 ps@(t, ASType qs _ms) = withSmpServer ps . withSmpServerConfigOn t (cfgJ2QS qs) testPort2 . const

withSmpServersProxy2 :: HasCallStack => (ATransport, AStoreType) -> IO a -> IO a
withSmpServersProxy2 ps@(t, ASType qs _ms) = withSmpServerProxy ps . withSmpServerConfigOn t (proxyCfgJ2QS qs) testPort2 . const

runSmpTest :: forall c a. (HasCallStack, Transport c) => AStoreType -> (HasCallStack => THandleSMP c 'TClient -> IO a) -> IO a
runSmpTest msType test = withSmpServerConfigOn (transport @c) (cfgMS msType) testPort $ \_ -> testSMPClient test

runSmpTestN :: forall c a. (HasCallStack, Transport c) => AStoreType -> Int -> (HasCallStack => [THandleSMP c 'TClient] -> IO a) -> IO a
runSmpTestN msType = runSmpTestNCfg (cfgMS msType) supportedClientSMPRelayVRange

runSmpTestNCfg :: forall c a. (HasCallStack, Transport c) => ServerConfig -> VersionRangeSMP -> Int -> (HasCallStack => [THandleSMP c 'TClient] -> IO a) -> IO a
runSmpTestNCfg srvCfg clntVR nClients test = withSmpServerConfigOn (transport @c) srvCfg testPort $ \_ -> run nClients []
  where
    run :: Int -> [THandleSMP c 'TClient] -> IO a
    run 0 hs = test hs
    run n hs = testSMPClientVR clntVR $ \h -> run (n - 1) (h : hs)

smpServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe TransmissionAuth, ByteString, ByteString, smp) ->
  IO (Maybe TransmissionAuth, ByteString, ByteString, BrokerMsg)
smpServerTest _ t = runSmpTest (ASType SQSMemory SMSJournal) $ \h -> tPut' h t >> tGet' h
  where
    tPut' :: THandleSMP c 'TClient -> (Maybe TransmissionAuth, ByteString, ByteString, smp) -> IO ()
    tPut' h@THandle {params = THandleParams {sessionId, implySessId}} (sig, corrId, queueId, smp) = do
      let t' = if implySessId then smpEncode (corrId, queueId, smp) else smpEncode (sessionId, corrId, queueId, smp)
      [Right ()] <- tPut h [Right (sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, EntityId qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

smpTest :: (HasCallStack, Transport c) => TProxy c -> AStoreType -> (HasCallStack => THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest _ msType test' = runSmpTest msType test' `shouldReturn` ()

smpTest' :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest' = (`smpTest` ASType SQSMemory SMSJournal)

smpTestN :: (HasCallStack, Transport c) => AStoreType -> Int -> (HasCallStack => [THandleSMP c 'TClient] -> IO ()) -> Expectation
smpTestN msType n test' = runSmpTestN msType n test' `shouldReturn` ()

smpTest2' :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest2' = (`smpTest2` ASType SQSMemory SMSJournal)

smpTest2 :: forall c. (HasCallStack, Transport c) => TProxy c -> AStoreType -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest2 t msType = smpTest2Cfg (cfgMS msType) supportedClientSMPRelayVRange t

smpTest2Cfg :: forall c. (HasCallStack, Transport c) => ServerConfig -> VersionRangeSMP -> TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest2Cfg srvCfg clntVR _ test' = runSmpTestNCfg srvCfg clntVR 2 _test `shouldReturn` ()
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: forall c. (HasCallStack, Transport c) => TProxy c -> AStoreType -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest3 _ msType test' = smpTestN msType 3 _test
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpTest4 :: forall c. (HasCallStack, Transport c) => TProxy c -> AStoreType -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest4 _ msType test' = smpTestN msType 4 _test
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2, h3, h4] = test' h1 h2 h3 h4
    _test _ = error "expected 4 handles"

unexpected :: (HasCallStack, Show a) => a -> Expectation
unexpected r = expectationFailure $ "unexpected response " <> show r

#if defined(dbPostgres) || defined(dbServerPostgres)
postgressBracket :: ConnectInfo -> IO a -> IO a
postgressBracket connInfo =
  E.bracket_
    (dropDatabaseAndUser connInfo >> createDBAndUserIfNotExists connInfo)
    (dropDatabaseAndUser connInfo)
#endif
