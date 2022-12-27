{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
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
import Simplex.Messaging.Version
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

testSMPClient :: (Transport c, MonadUnliftIO m, MonadFail m) => (THandle c -> m a) -> m a
testSMPClient client = do
  Right useHost <- pure $ chooseTransportHost defaultNetworkConfig testHost
  runTransportClient defaultTransportClientConfig useHost testPort (Just testKeyHash) $ \h ->
    liftIO (runExceptT $ smpClientHandshake h testKeyHash supportedSMPServerVRange) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfgV2 :: ServerConfig
cfgV2 = cfg {smpServerVRange = mkVersionRange 1 2}

cfg :: ServerConfig
cfg =
  ServerConfig
    { transports = undefined,
      tbqSize = 10,
      serverTbqSize = 10,
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
      smpServerVRange = supportedSMPServerVRange,
      logTLSErrors = True
    }

withSmpServerStoreMsgLogOnV2 :: ATransport -> ServiceName -> (ThreadId -> IO a) -> IO a
withSmpServerStoreMsgLogOnV2 t = withSmpServerConfigOn t cfgV2 {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile}

withSmpServerStoreMsgLogOn :: ATransport -> ServiceName -> (ThreadId -> IO a) -> IO a
withSmpServerStoreMsgLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerStoreLogOn :: ATransport -> ServiceName -> (ThreadId -> IO a) -> IO a
withSmpServerStoreLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, serverStatsBackupFile = Just testServerStatsBackupFile}

withSmpServerConfigOn :: ATransport -> ServerConfig -> ServiceName -> (ThreadId -> IO a) -> IO a
withSmpServerConfigOn t cfg' port' =
  serverBracket
    (\started -> runSMPServerBlocking started cfg' {transports = [(port', t)]})
    (pure ())

withSmpServerThreadOn :: ATransport -> ServiceName -> (ThreadId -> IO a) -> IO a
withSmpServerThreadOn t = withSmpServerConfigOn t cfg

serverBracket :: MonadUnliftIO m => (TMVar Bool -> m ()) -> m () -> (ThreadId -> m a) -> m a
serverBracket process afterProcess f = do
  started <- newEmptyTMVarIO
  E.bracket
    (forkIOWithUnmask ($ process started))
    (\t -> killThread t >> afterProcess >> waitFor started "stop")
    (\t -> waitFor started "start" >> f t)
  where
    waitFor started s =
      5_000_000 `timeout` atomically (takeTMVar started) >>= \case
        Nothing -> error $ "server did not " <> s
        _ -> pure ()

withSmpServerOn :: ATransport -> ServiceName -> IO a -> IO a
withSmpServerOn t port' = withSmpServerThreadOn t port' . const

withSmpServer :: ATransport -> IO a -> IO a
withSmpServer t = withSmpServerOn t testPort

runSmpTest :: forall c a. Transport c => (THandle c -> IO a) -> IO a
runSmpTest test = withSmpServer (transport @c) $ testSMPClient test

runSmpTestN :: forall c a. Transport c => Int -> ([THandle c] -> IO a) -> IO a
runSmpTestN nClients test = withSmpServer (transport @c) $ run nClients []
  where
    run :: Int -> [THandle c] -> IO a
    run 0 hs = test hs
    run n hs = testSMPClient $ \h -> run (n - 1) (h : hs)

smpServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe C.ASignature, ByteString, ByteString, smp) ->
  IO (Maybe C.ASignature, ByteString, ByteString, BrokerMsg)
smpServerTest _ t = runSmpTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' h (sig, corrId, queueId, smp) = do
      let t' = smpEncode (sessionId (h :: THandle c), corrId, queueId, smp)
      [Right ()] <- tPut h [(sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

smpTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> Expectation
smpTest _ test' = runSmpTest test' `shouldReturn` ()

smpTestN :: Transport c => Int -> ([THandle c] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: Transport c => TProxy c -> (THandle c -> THandle c -> IO ()) -> Expectation
smpTest2 _ test' = smpTestN 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: Transport c => TProxy c -> (THandle c -> THandle c -> THandle c -> IO ()) -> Expectation
smpTest3 _ test' = smpTestN 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpTest4 :: Transport c => TProxy c -> (THandle c -> THandle c -> THandle c -> THandle c -> IO ()) -> Expectation
smpTest4 _ test' = smpTestN 4 _test
  where
    _test [h1, h2, h3, h4] = test' h1 h2 h3 h4
    _test _ = error "expected 4 handles"
