{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.KeepAlive where

import Foreign.C (CInt (..))
import Network.Socket

_SOL_TCP :: CInt
_SOL_TCP = 6

#if defined(darwin_HOST_OS)
foreign import capi "netinet/tcp.h value TCP_KEEPALIVE" _TCP_KEEPIDLE :: CInt
#else
foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" _TCP_KEEPIDLE :: CInt
#endif

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

data KeepAliveOpts = KeepAliveOpts
  { keepIdle :: Int,
    keepIntvl :: Int,
    keepCnt :: Int
  }

defaultKeepAliveOpts :: KeepAliveOpts
defaultKeepAliveOpts =
  KeepAliveOpts
    { keepIdle = 30,
      keepIntvl = 15,
      keepCnt = 4
    }

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPIDLE) keepIdle
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPINTVL) keepIntvl
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPCNT) keepCnt
