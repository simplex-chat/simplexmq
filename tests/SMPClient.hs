{-# LANGUAGE BlockArguments #-}

module SMPClient where

import Control.Concurrent
import qualified Control.Exception as E
import Network.Socket
import Server
import System.IO
import Transmission
import Transport

runSMPClient :: HostName -> ServiceName -> (Handle -> IO a) -> IO a
runSMPClient host port client = withSocketsDo $ do
  threadDelay 1 -- TODO hack: thread delay for SMP server to start
  addr <- resolve
  E.bracket (open addr) hClose $ \h -> do
    line <- getLn h
    if line == "Welcome to SMP"
      then client h
      else error "not connected"
  where
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) (Just host) (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

testPort :: ServiceName
testPort = "5000"

testHost :: HostName
testHost = "localhost"

type TestTransmission = (Signature, ConnId, String)

smpServerTest :: [TestTransmission] -> IO [TestTransmission]
smpServerTest toSend =
  E.bracket
    (forkIO $ runSMPServer testPort)
    killThread
    \_ -> runSMPClient
      "localhost"
      testPort
      \h -> mapM (sendReceive h) toSend
  where
    sendReceive :: Handle -> TestTransmission -> IO TestTransmission
    sendReceive h t = do
      tPutRaw h t
      tGetRaw h
