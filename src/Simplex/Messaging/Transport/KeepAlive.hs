{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Transport.KeepAlive where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Foreign.C (CInt (..))
import Network.Socket
import qualified Network.TLS as T

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" tcpKeepCnt :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" tcpKeepIntvl :: CInt

#if defined(darwin_HOST_OS)
foreign import capi "netinet/tcp.h value TCP_KEEPALIVE" tcpKeepIdle :: CInt
foreign import capi "netinet/in.h value IPPROTO_TCP" solTcp :: CInt
#else
foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" tcpKeepIdle :: CInt
foreign import capi "netinet/tcp.h value SOL_TCP" solTcp :: CInt
#endif

data KeepAliveOpts = KeepAliveOpts
  { keepCnt :: Int,
    keepIdle :: Int,
    keepIntvl :: Int
  }

defaultKeepAlive :: KeepAliveOpts
defaultKeepAlive =
  KeepAliveOpts
    { keepCnt = 4,
      keepIdle = 60,
      keepIntvl = 30
    }

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
  setSocketOption sock (SockOpt solTcp tcpKeepCnt) keepCnt
  setSocketOption sock (SockOpt solTcp tcpKeepIdle) keepIdle
  setSocketOption sock (SockOpt solTcp tcpKeepIntvl) keepIntvl

data KeepAliveThread = KeepAliveThread
  { threadId :: ThreadId,
    dataTs :: TVar SystemTime
  }

startKeepAlive :: T.Context -> IO KeepAliveThread
startKeepAlive cxt = do
  dataTs <- newTVarIO =<< getSystemTime
  threadId <- forkIO . forever $ do
    threadDelay 30000000
    ts' <- getSystemTime
    doPing <- atomically $ do
      ts <- readTVar dataTs
      let ping = systemSeconds ts' - systemSeconds ts >= 30
      when ping $ writeTVar dataTs ts'
      pure ping
    when doPing $ putStrLn "*** ping ***" >> T.sendData cxt ""
  pure KeepAliveThread {threadId, dataTs}

touchKeepAlive :: KeepAliveThread -> IO ()
touchKeepAlive KeepAliveThread {dataTs} = atomically . writeTVar dataTs =<< getSystemTime

stopKeepAlive :: KeepAliveThread -> IO ()
stopKeepAlive KeepAliveThread {threadId} = killThread threadId
