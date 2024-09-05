{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPClient where

import Control.Monad.Except (runExceptT)
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import Simplex.Messaging.Client (ProtocolClientConfig (..), chooseTransportHost, defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import qualified Simplex.Messaging.Transport.Client as Client
import Simplex.Messaging.Transport.Server
import qualified Simplex.Messaging.Transport.Server as Server
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal
import System.Environment (lookupEnv)
import System.Info (os)
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar)
import UnliftIO.Timeout (timeout)
import Util

testHost :: NonEmpty TransportHost
testHost = "localhost"

testPort :: ServiceName
testPort = "5001"

testPort2 :: ServiceName
testPort2 = "5002"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

testStoreLogFile :: FilePath
testStoreLogFile = "tests/tmp/smp-server-store.log"

testStoreLogFile2 :: FilePath
testStoreLogFile2 = "tests/tmp/smp-server-store.log.2"

testDataLogFile :: FilePath
testDataLogFile = "tests/tmp/smp-server-data.log"

testStoreMsgsFile :: FilePath
testStoreMsgsFile = "tests/tmp/smp-server-messages.log"

testStoreMsgsFile2 :: FilePath
testStoreMsgsFile2 = "tests/tmp/smp-server-messages.log.2"

testServerStatsBackupFile :: FilePath
testServerStatsBackupFile = "tests/tmp/smp-server-stats.log"

xit' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit' d = if os == "linux" then skip "skipped on Linux" . it d else it d

xit'' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit'' d t = do
  ci <- runIO $ lookupEnv "CI"
  (if ci == Just "true" then skip "skipped on CI" . it d else it d) t

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
    runExceptT (smpClientHandshake h Nothing testKeyHash vr) >>= \case
      Right th -> client th
      Left e -> error $ show e
  where
    clientALPN
      | authCmdsSMPVersion `isCompatible` vr = Just supportedSMPHandshakes
      | otherwise = Nothing

cfg :: ServerConfig
cfg =
  ServerConfig
    { transports = [],
      smpHandshakeTimeout = 60000000,
      tbqSize = 1,
      msgQueueQuota = 4,
      queueIdBytes = 24,
      msgIdBytes = 24,
      storeLogFile = Nothing,
      dataLogFile = Nothing,
      storeMsgsFile = Nothing,
      allowNewQueues = True,
      newQueueBasicAuth = Nothing,
      controlPortUserAuth = Nothing,
      controlPortAdminAuth = Nothing,
      messageExpiration = Just defaultMessageExpiration,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/smp-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      pendingENDInterval = 500000,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt",
      smpServerVRange = supportedServerSMPRelayVRange,
      transportConfig = defaultTransportServerConfig {Server.alpn = Just supportedSMPHandshakes},
      controlPort = Nothing,
      smpAgentCfg = defaultSMPClientAgentConfig {persistErrorInterval = 1}, -- seconds
      allowSMPProxy = False,
      serverClientConcurrency = 2,
      information = Nothing
    }

cfgV7 :: ServerConfig
cfgV7 = cfg {smpServerVRange = mkVersionRange batchCmdsSMPVersion authCmdsSMPVersion}

cfgV8 :: ServerConfig
cfgV8 = cfg {smpServerVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion}

cfgVPrev :: ServerConfig
cfgVPrev = cfg {smpServerVRange = prevRange $ smpServerVRange cfg}

prevRange :: VersionRange v -> VersionRange v
prevRange vr = vr {maxVersion = max (minVersion vr) (prevVersion $ maxVersion vr)}

prevVersion :: Version v -> Version v
prevVersion (Version v) = Version (v - 1)

proxyCfg :: ServerConfig
proxyCfg =
  cfg
    { allowSMPProxy = True,
      smpAgentCfg = smpAgentCfg' {smpCfg = (smpCfg smpAgentCfg') {agreeSecret = True}}
    }
  where
    smpAgentCfg' = smpAgentCfg cfg

proxyVRangeV8 :: VersionRangeSMP
proxyVRangeV8 = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion

withSmpServerStoreMsgLogOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreMsgLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerStoreLogOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, dataLogFile = Just testDataLogFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerConfigOn :: HasCallStack => ATransport -> ServerConfig -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerConfigOn t cfg' port' =
  serverBracket
    (\started -> runSMPServerBlocking started cfg' {transports = [(port', t)]})
    (threadDelay 10000)

withSmpServerThreadOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerThreadOn t = withSmpServerConfigOn t cfg

serverBracket :: HasCallStack => (TMVar Bool -> IO ()) -> IO () -> (HasCallStack => ThreadId -> IO a) -> IO a
serverBracket process afterProcess f = do
  started <- newEmptyTMVarIO
  E.bracket
    (forkIOWithUnmask ($ process started))
    (\t -> killThread t >> afterProcess >> waitFor started "stop")
    (\t -> waitFor started "start" >> f t >>= \r -> r <$ threadDelay 100000)
  where
    waitFor started s =
      5_000_000 `timeout` atomically (takeTMVar started) >>= \case
        Nothing -> error $ "server did not " <> s
        _ -> pure ()

withSmpServerOn :: HasCallStack => ATransport -> ServiceName -> IO a -> IO a
withSmpServerOn t port' = withSmpServerThreadOn t port' . const

withSmpServer :: HasCallStack => ATransport -> IO a -> IO a
withSmpServer t = withSmpServerOn t testPort

withSmpServerProxy :: HasCallStack => ATransport -> IO a -> IO a
withSmpServerProxy t = withSmpServerConfigOn t proxyCfg testPort . const

runSmpTest :: forall c a. (HasCallStack, Transport c) => (HasCallStack => THandleSMP c 'TClient -> IO a) -> IO a
runSmpTest test = withSmpServer (transport @c) $ testSMPClient test

runSmpTestN :: forall c a. (HasCallStack, Transport c) => Int -> (HasCallStack => [THandleSMP c 'TClient] -> IO a) -> IO a
runSmpTestN = runSmpTestNCfg cfg supportedClientSMPRelayVRange

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
smpServerTest _ t = runSmpTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' :: THandleSMP c 'TClient -> (Maybe TransmissionAuth, ByteString, ByteString, smp) -> IO ()
    tPut' h@THandle {params = THandleParams {sessionId, implySessId}} (sig, corrId, queueId, smp) = do
      let t' = if implySessId then smpEncode (corrId, queueId, smp) else smpEncode (sessionId, corrId, queueId, smp)
      [Right ()] <- tPut h [Right (sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, EntityId qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

smpTest :: (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest _ test' = runSmpTest test' `shouldReturn` ()

smpTestN :: (HasCallStack, Transport c) => Int -> (HasCallStack => [THandleSMP c 'TClient] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest2 = smpTest2Cfg cfg supportedClientSMPRelayVRange

smpTest2Cfg :: forall c. (HasCallStack, Transport c) => ServerConfig -> VersionRangeSMP -> TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest2Cfg srvCfg clntVR _ test' = runSmpTestNCfg srvCfg clntVR 2 _test `shouldReturn` ()
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest3 _ test' = smpTestN 3 _test
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpTest4 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> THandleSMP c 'TClient -> IO ()) -> Expectation
smpTest4 _ test' = smpTestN 4 _test
  where
    _test :: HasCallStack => [THandleSMP c 'TClient] -> IO ()
    _test [h1, h2, h3, h4] = test' h1 h2 h3 h4
    _test _ = error "expected 4 handles"

unexpected :: (HasCallStack, Show a) => a -> Expectation
unexpected r = expectationFailure $ "unexpected response " <> show r
