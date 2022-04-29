{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPClient where

import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Network.Socket
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.KeepAlive
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar)
import UnliftIO.Timeout (timeout)

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "5001"

testPort2 :: ServiceName
testPort2 = "5002"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

testStoreLogFile :: FilePath
testStoreLogFile = "tests/tmp/smp-server-store.log"

testSMPClient :: (Transport c, MonadUnliftIO m) => (THandle c -> m a) -> m a
testSMPClient client =
  runTransportClient testHost testPort (Just testKeyHash) (Just defaultKeepAliveOpts) $ \h ->
    liftIO (runExceptT $ smpClientHandshake h testKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: ServerConfig
cfg =
  ServerConfig
    { transports = undefined,
      tbqSize = 1,
      serverTbqSize = 1,
      msgQueueQuota = 4,
      queueIdBytes = 24,
      msgIdBytes = 24,
      storeLogFile = Nothing,
      allowNewQueues = True,
      messageExpiration = Just defaultMessageExpiration,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withSmpServerStoreLogOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
withSmpServerStoreLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile}

withSmpServerConfigOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServerConfig -> ServiceName -> (ThreadId -> m a) -> m a
withSmpServerConfigOn t cfg' port' =
  serverBracket
    (\started -> runSMPServerBlocking started cfg' {transports = [(port', t)]})
    (pure ())

withSmpServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
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

withSmpServerOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> m a -> m a
withSmpServerOn t port' = withSmpServerThreadOn t port' . const

withSmpServer :: (MonadUnliftIO m, MonadRandom m) => ATransport -> m a -> m a
withSmpServer t = withSmpServerOn t testPort

runSmpTest :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => (THandle c -> m a) -> m a
runSmpTest test = withSmpServer (transport @c) $ testSMPClient test

runSmpTestN :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => Int -> ([THandle c] -> m a) -> m a
runSmpTestN nClients test = withSmpServer (transport @c) $ run nClients []
  where
    run :: Int -> [THandle c] -> m a
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
      Right () <- tPut h (sig, t')
      pure ()
    tGet' h = do
      (Nothing, _, (CorrId corrId, qId, Right cmd)) <- tGet h
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
