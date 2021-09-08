{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
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
testPort = "5000"

testPort2 :: ServiceName
testPort2 = "5001"

testKeyHashStr :: B.ByteString
testKeyHashStr = "KXNE1m2E1m0lm92WGKet9CL6+lO742Vy5G6nsrkvgs8="

testBlockSize :: Maybe Int
testBlockSize = Just 8192

testKeyHash :: Maybe C.KeyHash
testKeyHash = Just "KXNE1m2E1m0lm92WGKet9CL6+lO742Vy5G6nsrkvgs8="

testStoreLogFile :: FilePath
testStoreLogFile = "tests/tmp/smp-server-store.log"

testSMPClient :: (Transport c, MonadUnliftIO m) => (THandle c -> m a) -> m a
testSMPClient client =
  runTransportClient testHost testPort $ \h ->
    liftIO (runExceptT $ clientHandshake h testBlockSize testKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: ServerConfig
cfg =
  ServerConfig
    { transports = undefined,
      tbqSize = 1,
      msgQueueQuota = 4,
      queueIdBytes = 12,
      msgIdBytes = 6,
      storeLog = Nothing,
      blockSize = 8192,
      serverPrivateKey =
        -- full RSA private key (only for tests)
        "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\
        \TmKzSAw7iVWwEUZR/PeiEKazqrpp9VU="
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

smpServerTest :: forall c. Transport c => TProxy c -> RawTransmission -> IO RawTransmission
smpServerTest _ cmd = runSmpTest $ \(h :: THandle c) -> tPutRaw h cmd >> tGetRaw h

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

tPutRaw :: Transport c => THandle c -> RawTransmission -> IO ()
tPutRaw h (sig, corrId, queueId, command) = do
  let t = B.intercalate " " [corrId, queueId, command]
  void $ tPut h (C.Signature sig, t)

tGetRaw :: Transport c => THandle c -> IO RawTransmission
tGetRaw h = do
  ("", (CorrId corrId, qId, Right cmd)) <- tGet fromServer h
  pure ("", corrId, encode qId, serializeCommand cmd)
