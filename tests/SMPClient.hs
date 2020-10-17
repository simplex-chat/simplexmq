{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPClient where

import Control.Monad.IO.Unlift
import Crypto.Random
import Env.STM
import Network.Socket
import Server
import Transmission
import Transport
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
    if line == "Welcome to SMP"
      then client h
      else error "not connected"

cfg :: Config
cfg =
  Config
    { tcpPort = testPort,
      queueSize = 1,
      connIdBytes = 12,
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
    sendReceive h t = tPutRaw h t >> either (error "bad transmission") id <$> tGetRaw h
