module Main where

import Control.Concurrent
import qualified Control.Exception as E
import Control.Monad
import Network.Socket
import System.IO

main = do
  putStrLn $ "Listening on port " ++ port
  runTCPServer Nothing port talk

port :: String
port = "5223"

runTCPServer :: Maybe HostName -> ServiceName -> (Handle -> IO ()) -> IO ()
runTCPServer mhost port server = withSocketsDo $ do
  let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
  addr : _ <- getAddrInfo (Just hints) mhost (Just port)
  E.bracket (open addr) close loop
  where
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock $ setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock
    loop sock = forever $ do
      (conn, peer) <- accept sock
      putStrLn $ "Accepted connection from " ++ show peer
      h <- socketToHandle conn ReadWriteMode
      hSetBinaryMode h True
      hSetBuffering h LineBuffering
      hPutStrLn h "Welcome\r"
      forkFinally (server h) (const $ hClose h)

talk :: Handle -> IO ()
talk h = do
  line <- hGetLine h
  if line == "end"
    then hPutStrLn h "Bye\r"
    else do
      hPutStrLn h (show (2 * (read line :: Integer)) ++ "\r")
      talk h
