{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Transport.KeepAlive where

import qualified Data.Aeson.TH as J
import Foreign.C (CInt (..))
import Network.Socket
import Simplex.Messaging.Parsers (defaultJSON)

data KeepAliveOpts = KeepAliveOpts
  { keepIdle :: Int,
    keepIntvl :: Int,
    keepCnt :: Int
  }
  deriving (Eq, Show)

defaultKeepAliveOpts :: KeepAliveOpts
defaultKeepAliveOpts =
  KeepAliveOpts
    { keepIdle = 30,
      keepIntvl = 15,
      keepCnt = 4
    }

_SOL_TCP :: CInt
_SOL_TCP = 6

#if defined(mingw32_HOST_OS)
-- Windows

-- The values are copied from windows::Win32::Networking::WinSock
-- https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Networking/WinSock/index.html

_TCP_KEEPIDLE :: CInt
_TCP_KEEPIDLE = 3

_TCP_KEEPINTVL :: CInt
_TCP_KEEPINTVL = 17

_TCP_KEEPCNT :: CInt
_TCP_KEEPCNT = 16

#elif defined(darwin_HOST_OS)
-- macOS
foreign import capi "netinet/tcp.h value TCP_KEEPALIVE" _TCP_KEEPIDLE :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

#elif defined(openbsd_HOST_OS)
-- OpenBSD

-- OpenBSD does not support TCP_KEEPIDLE, TCP_KEEPINTVL, and TCP_KEEPCNT.
-- Only SO_KEEPALIVE can be configured here.

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {} = do
  setSocketOption sock KeepAlive 1
  -- Additional parameters cannot be set on OpenBSD,
  -- keep-alive behavior is controlled by the system.

#else
-- Linux or other Unix-like systems

foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" _TCP_KEEPIDLE :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPIDLE) keepIdle
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPINTVL) keepIntvl
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPCNT) keepCnt
#endif

$(J.deriveJSON defaultJSON ''KeepAliveOpts)
