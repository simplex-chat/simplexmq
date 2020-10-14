{-# LANGUAGE BlockArguments #-}

module SMPClient where

import Control.Monad
import Control.Monad.IO.Unlift
import Network.Socket
import Numeric.Natural
import Server
import Transmission
import Transport
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.IO

startTCPClient :: MonadIO m => HostName -> ServiceName -> m Handle
startTCPClient host port = liftIO . withSocketsDo $ do
  threadDelay 1 -- TODO hack: thread delay for SMP server to start
  addr <- resolve
  open addr
  where
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) (Just host) (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port client = do
  E.bracket (startTCPClient host port) (liftIO . hClose) client

runSMPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runSMPClient host port client =
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
    \_ -> runSMPClient "localhost" testPort test

smpServerTest :: [TestTransmission] -> IO [TestTransmission]
smpServerTest commands = runSmpTest \h -> mapM (sendReceive h) commands
  where
    sendReceive :: Handle -> TestTransmission -> IO TestTransmission
    sendReceive h t = tPutRaw h t >> tGetRaw h
