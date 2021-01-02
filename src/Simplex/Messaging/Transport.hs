{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport where

import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket
import System.IO
import System.IO.Error
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import qualified UnliftIO.IO as IO

startTCPServer :: MonadIO m => ServiceName -> m Socket
startTCPServer port = liftIO . withSocketsDo $ resolve >>= open
  where
    resolve = do
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) Nothing (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock

runTCPServer :: MonadUnliftIO m => ServiceName -> (Handle -> m ()) -> m ()
runTCPServer port server =
  E.bracket (startTCPServer port) (liftIO . close) $ \sock -> forever $ do
    h <- acceptTCPConn sock
    forkFinally (server h) (const $ IO.hClose h)

acceptTCPConn :: MonadIO m => Socket -> m Handle
acceptTCPConn sock = liftIO $ do
  (conn, _) <- accept sock
  getSocketHandle conn

startTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> m Handle
startTCPClient host port =
  liftIO . withSocketsDo $
    resolve >>= foldM tryOpen (Left err) >>= either E.throwIO return
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: Exception e => Either e Handle -> AddrInfo -> IO (Either e Handle)
    tryOpen h@(Right _) _ = return h
    tryOpen (Left _) addr = E.try $ open addr

    open :: AddrInfo -> IO Handle
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port = E.bracket (startTCPClient host port) IO.hClose

getSocketHandle :: MonadIO m => Socket -> m Handle
getSocketHandle conn = liftIO $ do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

putLn :: MonadIO m => Handle -> ByteString -> m ()
putLn h = liftIO . hPutStrLn h . B.unpack

getLn :: MonadIO m => Handle -> m ByteString
getLn h = B.pack <$> liftIO (hGetLine h)

getBytes :: MonadIO m => Handle -> Int -> m ByteString
getBytes h = liftIO . B.hGet h

infixl 4 <$$>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap
