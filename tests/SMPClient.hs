{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPClient where

import Control.Monad (void)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Base64 (encode)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.Socket
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server (runSMPServerBlocking)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (openReadStoreLog)
import Simplex.Messaging.Transport
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

testKeyHashStr :: ByteString
testKeyHashStr = "9VjLsOY5ZvB4hoglNdBzJFAUi/vP4GkZnJFahQOXV20="

testBlockSize :: Int
testBlockSize = 16 * 1024 -- TODO move to Protocol

testKeyHash :: Maybe C.KeyHash
testKeyHash = Just "9VjLsOY5ZvB4hoglNdBzJFAUi/vP4GkZnJFahQOXV20="

testStoreLogFile :: FilePath
testStoreLogFile = "tests/tmp/smp-server-store.log"

testSMPClient :: (Transport c, MonadUnliftIO m) => (THandle c -> m a) -> m a
testSMPClient client =
  runTransportClient testHost testPort testKeyHash $ \h ->
    liftIO (runExceptT $ clientHandshake h testBlockSize) >>= \case
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
      storeLog = Nothing,
      blockSize = testBlockSize,
      caCertificateFile = "tests/fixtures/ca.crt",
      serverPrivateKeyFile = "tests/fixtures/server.key",
      serverCertificateFile = "tests/fixtures/server.crt"
    }

withSmpServerStoreLogOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
withSmpServerStoreLogOn t port client = do
  s <- liftIO $ openReadStoreLog testStoreLogFile
  serverBracket
    (\started -> runSMPServerBlocking started cfg {transports = [(port, t)], storeLog = Just s})
    (pure ())
    client

withSmpServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
withSmpServerThreadOn t port =
  serverBracket
    (\started -> runSMPServerBlocking started cfg {transports = [(port, t)]})
    (pure ())

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
withSmpServerOn t port = withSmpServerThreadOn t port . const

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

smpServerTest :: forall c. Transport c => TProxy c -> SignedRawTransmission -> IO SignedRawTransmission
smpServerTest _ t = runSmpTest $ \(h :: THandle c) -> tPutRaw h t >> tGetRaw h

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

tPutRaw :: Transport c => THandle c -> SignedRawTransmission -> IO ()
tPutRaw h@THandle {sessionId} (sig, corrId, queueId, command) = do
  let t = B.unwords [sessionId, corrId, queueId, command]
  void $ tPut h (sig, t)

tGetRaw :: Transport c => THandle c -> IO SignedRawTransmission
tGetRaw h = do
  (Nothing, _, (CorrId corrId, qId, Right cmd)) <- tGet fromServer h
  pure (Nothing, corrId, encode qId, serializeCommand cmd)
