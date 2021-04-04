{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPClient where

import Control.Monad (void)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import Network.Socket
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "5000"

teshKeyHashStr :: B.ByteString
teshKeyHashStr = "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="

teshKeyHash :: Maybe KeyHash
teshKeyHash = Just "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="

testSMPClient :: MonadUnliftIO m => (THandle -> m a) -> m a
testSMPClient client = do
  threadDelay 250_000 -- TODO hack: thread delay for SMP server to start
  runTCPClient testHost testPort $ \h ->
    liftIO (runExceptT $ clientHandshake h teshKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = testPort,
      tbqSize = 1,
      queueIdBytes = 12,
      msgIdBytes = 6
    }

withSmpServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ServiceName -> (ThreadId -> m a) -> m a
withSmpServerThreadOn port =
  E.bracket
    (forkIOWithUnmask ($ runSMPServer cfg {tcpPort = port}))
    (liftIO . killThread)

withSmpServerOn :: (MonadUnliftIO m, MonadRandom m) => ServiceName -> m a -> m a
withSmpServerOn port = withSmpServerThreadOn port . const

withSmpServer :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpServer = withSmpServerOn testPort

runSmpTest :: (MonadUnliftIO m, MonadRandom m) => (THandle -> m a) -> m a
runSmpTest test = withSmpServer $ testSMPClient test

runSmpTestN :: forall m a. (MonadUnliftIO m, MonadRandom m) => Int -> ([THandle] -> m a) -> m a
runSmpTestN nClients test = withSmpServer $ run nClients []
  where
    run :: Int -> [THandle] -> m a
    run 0 hs = test hs
    run n hs = testSMPClient $ \h -> run (n - 1) (h : hs)

smpServerTest :: RawTransmission -> IO RawTransmission
smpServerTest cmd = runSmpTest $ \h -> tPutRaw h cmd >> tGetRaw h

smpTest :: (THandle -> IO ()) -> Expectation
smpTest test' = runSmpTest test' `shouldReturn` ()

smpTestN :: Int -> ([THandle] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: (THandle -> THandle -> IO ()) -> Expectation
smpTest2 test' = smpTestN 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: (THandle -> THandle -> THandle -> IO ()) -> Expectation
smpTest3 test' = smpTestN 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

tPutRaw :: THandle -> RawTransmission -> IO ()
tPutRaw h (sig, corrId, queueId, command) = do
  let t = B.intercalate " " [corrId, queueId, command]
  void $ tPut h (C.Signature sig, t)

tGetRaw :: THandle -> IO RawTransmission
tGetRaw h = do
  Right t <- tGetParse h
  return t
