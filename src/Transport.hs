{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module Transport where

import Network.Socket
import Polysemy
import Polysemy.Reader
import Polysemy.Resource
import System.IO

data Transport h m a where
  TReadLn :: h -> Transport h m String
  TWriteLn :: h -> String -> Transport h m ()

makeSem ''Transport

type TCPTransport = Transport Handle

startTCPServer :: String -> IO Socket
startTCPServer port = withSocketsDo $ do
  let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
  addr <- head <$> getAddrInfo (Just hints) Nothing (Just port)
  sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
  setSocketOption sock ReuseAddr 1
  withFdSocket sock setCloseOnExecIfNeeded
  bind sock $ addrAddress addr
  listen sock 1024
  return sock

acceptTCPConn :: Socket -> IO Handle
acceptTCPConn sock = do
  (conn, peer) <- accept sock
  putStrLn $ "Accepted connection from " ++ show peer
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h universalNewlineMode
  hSetBuffering h LineBuffering
  return h

runTCPTransportIO :: Member (Embed IO) r => Sem (TCPTransport ': r) a -> Sem r a
runTCPTransportIO = interpret $ \case
  TReadLn h -> embed $ hGetLine h
  TWriteLn h str -> embed $ hPutStr h $ str ++ "\r\n"
