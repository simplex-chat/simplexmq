{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPClient where

import Control.Monad.IO.Unlift
import Crypto.Random
import Network.Socket
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.Transmission
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.IO

testHost :: HostName
testHost = "localhost"

testPort :: ServiceName
testPort = "5000"

testSMPClient :: MonadUnliftIO m => (Handle -> m a) -> m a
testSMPClient client = do
  threadDelay 5000 -- TODO hack: thread delay for SMP server to start
  runTCPClient testHost testPort $ \h -> do
    line <- getLn h
    if line == "Welcome to SMP v0.2.0"
      then client h
      else error "not connected"

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = testPort,
      tbqSize = 1,
      queueIdBytes = 12,
      msgIdBytes = 6
    }

withSmpServer :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpServer = E.bracket (forkIO $ runSMPServer cfg) (liftIO . killThread) . const

runSmpTest :: (MonadUnliftIO m, MonadRandom m) => (Handle -> m a) -> m a
runSmpTest test = withSmpServer $ testSMPClient test

runSmpTestN :: forall m a. (MonadUnliftIO m, MonadRandom m) => Int -> ([Handle] -> m a) -> m a
runSmpTestN nClients test = withSmpServer $ run [] nClients
  where
    run :: [Handle] -> Int -> m a
    run hs 0 = test hs
    run hs n = testSMPClient $ \h -> run (h : hs) (n - 1)

smpServerTest :: [RawTransmission] -> IO [RawTransmission]
smpServerTest commands = runSmpTest \h -> mapM (sendReceive h) commands
  where
    sendReceive :: Handle -> RawTransmission -> IO RawTransmission
    sendReceive h t = tPutRaw h t >> tGetRaw h

smpTest :: (Handle -> IO ()) -> Expectation
smpTest test' = runSmpTest test' `shouldReturn` ()

smpTestN :: Int -> ([Handle] -> IO ()) -> Expectation
smpTestN n test' = runSmpTestN n test' `shouldReturn` ()

smpTest2 :: (Handle -> Handle -> IO ()) -> Expectation
smpTest2 test' = smpTestN 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpTest3 :: (Handle -> Handle -> Handle -> IO ()) -> Expectation
smpTest3 test' = smpTestN 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"
