{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent
import Control.Exception
import Control.Monad
import GHC.IO.Exception
import Network.Socket
import System.IO
import System.IO.Error
import Util

main :: IO ()
main = runTCPClient "localhost" "5000" ping

ping :: Handle -> IO ()
ping h = do
  putStrLn "connected to server"
  forever $ do
    putLn h "ping"
    threadDelay 1000000
    line <- getLn h
    print line

runTCPClient :: HostName -> ServiceName -> (Handle -> IO a) -> IO a
runTCPClient host port client = do
  h <- startTCPClient host port
  client h `finally` hClose h

startTCPClient :: HostName -> ServiceName -> IO Handle
startTCPClient host port =
  withSocketsDo $
    resolve >>= foldM tryOpen (Left err) >>= either throwIO return
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: Exception e => Either e Handle -> AddrInfo -> IO (Either e Handle)
    tryOpen h@(Right _) _ = return h
    tryOpen (Left _) addr = try $ open addr

    open :: AddrInfo -> IO Handle
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock
