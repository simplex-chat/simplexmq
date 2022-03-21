{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.KeepAlive where

import Foreign.C (CInt (..))
import Network.Socket

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

defaultKeepAliveOpts :: KeepAliveOpts
defaultKeepAliveOpts =
  KeepAliveOpts
    { keepCnt = 4,
      keepIdle = 30,
      keepIntvl = 15
    }

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
  setSocketOption sock (SockOpt solTcp tcpKeepCnt) keepCnt
  setSocketOption sock (SockOpt solTcp tcpKeepIdle) keepIdle
  setSocketOption sock (SockOpt solTcp tcpKeepIntvl) keepIntvl
