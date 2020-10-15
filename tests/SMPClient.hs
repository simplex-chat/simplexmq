{-# LANGUAGE BlockArguments #-}

module SMPClient where

import Control.Monad.IO.Unlift
import Network.Socket
import Numeric.Natural
import Server
import Transmission
import Transport
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.IO

testSMPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
testSMPClient host port client = do
  threadDelay 1 -- TODO hack: thread delay for SMP server to start
  runTCPClient host port $ \h -> do
    line <- getLn h
    if line == "Welcome to SMP"
      then client h
      else error "not connected"

testPort :: ServiceName
testPort = "5000"

testHost :: HostName
testHost = "localhost"

queueSize :: Natural
queueSize = 2

type TestTransmission = (Signature, ConnId, String)

runSmpTest :: MonadUnliftIO m => (Handle -> m a) -> m a
runSmpTest test =
  E.bracket
    (forkIO $ runSMPServer testPort queueSize)
    (liftIO . killThread)
    \_ -> testSMPClient "localhost" testPort test

smpServerTest :: [TestTransmission] -> IO [TestTransmission]
smpServerTest commands = runSmpTest \h -> mapM (sendReceive h) commands
  where
    sendReceive :: Handle -> TestTransmission -> IO TestTransmission
    sendReceive h t = tPutRaw h t >> tGetRaw h
