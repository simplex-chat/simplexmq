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
import Control.Monad.IO.Unlift
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Network.Socket
import Simplex.Messaging.Client (chooseTransportHost, defaultNetworkConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Version (VersionRange, mkVersionRange)
import System.Environment (lookupEnv)
import System.Info (os)
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar)
import UnliftIO.Timeout (timeout)

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

testStoreMsgsFile :: FilePath
testStoreMsgsFile = "tests/tmp/smp-server-messages.log"

testServerStatsBackupFile :: FilePath
testServerStatsBackupFile = "tests/tmp/smp-server-stats.log"

xit' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit' = if os == "linux" then xit else it

xit'' :: (HasCallStack, Example a) => String -> a -> SpecWith (Arg a)
xit'' d t = do
  ci <- runIO $ lookupEnv "CI"
  (if ci == Just "true" then xit else it) d t

testSMPClient :: (Transport c, MonadUnliftIO m, MonadFail m) => (THandle c -> m a) -> m a
testSMPClient = testSMPClientVR supportedClientSMPRelayVRange

testSMPClientVR :: (Transport c, MonadUnliftIO m, MonadFail m) => VersionRange -> (THandle c -> m a) -> m a
testSMPClientVR vr client = do
  Right useHost <- pure $ chooseTransportHost defaultNetworkConfig testHost
  runTransportClient defaultTransportClientConfig Nothing useHost testPort (Just testKeyHash) $ \h -> do
    g <- liftIO C.newRandom
    ks <- atomically $ C.generateKeyPair g
    liftIO (runExceptT $ smpClientHandshake h ks testKeyHash vr) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: ServerConfig
cfg =
  ServerConfig
    { transports = undefined,
      smpHandshakeTimeout = 60000000,
      tbqSize = 1,
      -- serverTbqSize = 1,
      msgQueueQuota = 4,
      queueIdBytes = 24,
      msgIdBytes = 24,
      storeLogFile = Nothing,
      storeMsgsFile = Nothing,
      allowNewQueues = True,
      newQueueBasicAuth = Nothing,
      messageExpiration = Just defaultMessageExpiration,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/smp-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt",
      smpServerVRange = supportedServerSMPRelayVRange,
      transportConfig = defaultTransportServerConfig,
      controlPort = Nothing
    }

cfgV8 :: ServerConfig
cfgV8 = cfg {smpServerVRange = mkVersionRange 4 authEncryptCmdsSMPVersion}

withSmpServerStoreMsgLogOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreMsgLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerStoreLogOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerStoreLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerConfigOn :: HasCallStack => ATransport -> ServerConfig -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerConfigOn t cfg' port' =
  serverBracket
    (\started -> runSMPServerBlocking started cfg' {transports = [(port', t)]})
    (pure ())

withSmpServerThreadOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
withSmpServerThreadOn t = withSmpServerConfigOn t cfg

serverBracket :: (HasCallStack, MonadUnliftIO m) => (TMVar Bool -> m ()) -> m () -> (HasCallStack => ThreadId -> m a) -> m a
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

withSmpServerV8 :: HasCallStack => ATransport -> IO a -> IO a
withSmpServerV8 t = withSmpServerConfigOn t cfgV8 testPort . const

runSmpTest :: forall c a. (HasCallStack, Transport c) => (HasCallStack => THandle c -> IO a) -> IO a
runSmpTest test = withSmpServer (transport @c) $ testSMPClient test

runSmpTestN :: forall c a. (HasCallStack, Transport c) => Int -> (HasCallStack => [THandle c] -> IO a) -> IO a
runSmpTestN = runSmpTestNCfg cfg supportedClientSMPRelayVRange

runSmpTestNCfg :: forall c a. (HasCallStack, Transport c) => ServerConfig -> VersionRange -> Int -> (HasCallStack => [THandle c] -> IO a) -> IO a
runSmpTestNCfg srvCfg clntVR nClients test = withSmpServerConfigOn (transport @c) srvCfg testPort $ \_ -> run nClients []
  where
    run :: Int -> [THandle c] -> IO a
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
    tPut' :: THandle c -> (Maybe TransmissionAuth, ByteString, ByteString, smp) -> IO ()
    tPut' h (sig, corrId, queueId, smp) = do
      let t' = smpEncode (corrId, queueId, smp)
      [Right ()] <- tPut h [Right (sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

smpTest :: (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandle c -> IO ()) -> Expectation
smpTest _ test' = runSmpTest test' `shouldReturn` ()

smpTestN :: (HasCallStack, Transport c) => Int -> (HasCallStack => [THandle c] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandle c -> THandle c -> IO ()) -> Expectation
smpTest2 = smpTest2Cfg cfg supportedClientSMPRelayVRange

smpTest2Cfg :: forall c. (HasCallStack, Transport c) => ServerConfig -> VersionRange -> TProxy c -> (HasCallStack => THandle c -> THandle c -> IO ()) -> Expectation
smpTest2Cfg srvCfg clntVR _ test' = runSmpTestNCfg srvCfg clntVR 2 _test `shouldReturn` ()
  where
    _test :: HasCallStack => [THandle c] -> IO ()
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandle c -> THandle c -> THandle c -> IO ()) -> Expectation
smpTest3 _ test' = smpTestN 3 _test
  where
    _test :: HasCallStack => [THandle c] -> IO ()
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpTest4 :: forall c. (HasCallStack, Transport c) => TProxy c -> (HasCallStack => THandle c -> THandle c -> THandle c -> THandle c -> IO ()) -> Expectation
smpTest4 _ test' = smpTestN 4 _test
  where
    _test :: HasCallStack => [THandle c] -> IO ()
    _test [h1, h2, h3, h4] = test' h1 h2 h3 h4
    _test _ = error "expected 4 handles"

unexpected :: (HasCallStack, Show a) => a -> Expectation
unexpected r = expectationFailure $ "unexpected response " <> show r
