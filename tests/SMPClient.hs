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

smpServerTest :: [Transmission] -> IO [Transmission]
smpServerTest toSend =
  E.bracket
    (forkIO $ runSMPServer "5000")
    killThread
    ( const $
        runSMPClient "localhost" "5000" $ \h ->
          mapM (sendReceive h) toSend
    )
  where
    sendReceive :: Handle -> Transmission -> IO Transmission
    sendReceive h (signature, (connId, cmd)) = do
      putLn h signature
      putLn h connId
      putLn h $ serializeCommand cmd
      signature' <- getLn h
      connId' <- getLn h
      cmd' <- parseCommand <$> getLn h
      return (signature', (connId', cmd'))
