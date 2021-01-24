{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Network.Socket
import System.IO
import Util

main :: IO ()
main = do
  putStrLn "listening to 5000..."
  runTCPServer pong

pong :: Handle -> IO ()
pong h = forever $ do
  line <- getLn h
  print line
  putLn h "pong"

runTCPServer :: (Handle -> IO ()) -> IO ()
runTCPServer server =
  bracket startTCPServer close $ \sock -> forever $ do
    h <- acceptTCPConn sock
    putStrLn "client connected"
    forkFinally (server h) $ \_ -> do
      hClose h
      putStrLn "client disconnected"

startTCPServer :: IO Socket
startTCPServer = withSocketsDo $ resolve >>= open
  where
    resolve = do
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) Nothing (Just "5000")
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock

acceptTCPConn :: Socket -> IO Handle
acceptTCPConn sock = do
  (conn, _) <- accept sock
  getSocketHandle conn
