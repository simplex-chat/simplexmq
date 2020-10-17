{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

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

testSMPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
testSMPClient host port client = do
  threadDelay 1000 -- TODO hack: thread delay for SMP server to start
  runTCPClient host port $ \h -> do
    line <- getLn h
    if line == "Welcome to SMP"
      then client h
      else error "not connected"

testPort :: ServiceName
testPort = "5000"

testHost :: HostName
testHost = "localhost"

cfg :: Config
cfg =
  Config
    { tcpPort = testPort,
      queueSize = 1,
      connIdBytes = 12,
      msgIdBytes = 6
    }

runSmpTest :: (MonadUnliftIO m, MonadRandom m) => (Handle -> m a) -> m a
runSmpTest test =
  E.bracket
    (forkIO $ runSMPServer cfg)
    (liftIO . killThread)
    \_ -> testSMPClient "localhost" testPort test

smpServerTest :: [RawTransmission] -> IO [RawTransmission]
smpServerTest commands = runSmpTest \h -> mapM (sendReceive h) commands
  where
    sendReceive :: Handle -> RawTransmission -> IO RawTransmission
    sendReceive h t = tPutRaw h t >> either (error "bad transmission") id <$> tGetRaw h
