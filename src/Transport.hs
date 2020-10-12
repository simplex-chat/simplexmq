{-# LANGUAGE FlexibleContexts #-}

module Transport where

import Control.Monad.IO.Class
import Control.Monad.Reader
import EnvSTM
import Network.Socket
import System.IO

startTCPServer :: (MonadReader Env m, MonadIO m) => m Socket
startTCPServer = do
  port <- asks tcpPort
  liftIO . withSocketsDo $ do
    let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
    addr <- head <$> getAddrInfo (Just hints) Nothing (Just port)
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    withFdSocket sock setCloseOnExecIfNeeded
    bind sock $ addrAddress addr
    listen sock 1024
    return sock

acceptTCPConn :: MonadIO m => Socket -> m Handle
acceptTCPConn sock = liftIO $ do
  (conn, peer) <- accept sock
  putStrLn $ "Accepted connection from " ++ show peer
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h universalNewlineMode
  hSetBuffering h LineBuffering
  return h

putLn :: MonadIO m => Handle -> String -> m ()
putLn h = liftIO . hPutStrLn h

getLn :: MonadIO m => Handle -> m String
getLn = liftIO . hGetLine
