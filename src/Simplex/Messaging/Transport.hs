{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport where

import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Set (Set)
import qualified Data.Set as S
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket
import System.IO
import System.IO.Error
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import qualified UnliftIO.IO as IO
import UnliftIO.STM

runTCPServer :: MonadUnliftIO m => ServiceName -> (Handle -> m ()) -> TMVar Bool -> m ()
runTCPServer port server started = do
  clients <- newTVarIO S.empty
  E.bracket
    ( do
        sock <- liftIO $ startTCPServer port
        atomically $ putTMVar started True
        return sock
    )
    (liftIO . closeServer clients)
    \sock -> forever $ do
      h <- liftIO $ acceptTCPConn sock
      tid <- forkFinally (server h) (const $ IO.hClose h)
      atomically . modifyTVar clients $ S.insert tid
  where
    closeServer :: TVar (Set ThreadId) -> Socket -> IO ()
    closeServer clients sock = readTVarIO clients >>= mapM_ killThread >> close sock

startTCPServer :: ServiceName -> IO Socket
startTCPServer port = withSocketsDo $ resolve >>= open
  where
    resolve =
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
       in head <$> getAddrInfo (Just hints) Nothing (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock

acceptTCPConn :: Socket -> IO Handle
acceptTCPConn sock = accept sock >>= getSocketHandle . fst

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port client = do
  h <- liftIO $ startTCPClient host port
  client h `E.finally` IO.hClose h

startTCPClient :: HostName -> ServiceName -> IO Handle
startTCPClient host port =
  withSocketsDo $
    resolve >>= foldM tryOpen (Left err) >>= either E.throwIO return -- replace fold with recursion
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: Exception e => Either e Handle -> AddrInfo -> IO (Either e Handle)
    tryOpen (Left _) addr = E.try $ open addr
    tryOpen h _ = return h

    open :: AddrInfo -> IO Handle
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

getSocketHandle :: Socket -> IO Handle
getSocketHandle conn = do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

putLn :: Handle -> ByteString -> IO ()
putLn h = B.hPut h . (<> "\r\n")

getLn :: Handle -> IO ByteString
getLn h = trim_cr <$> B.hGetLine h
  where
    trim_cr "" = ""
    trim_cr s = if B.last s == '\r' then B.init s else s
