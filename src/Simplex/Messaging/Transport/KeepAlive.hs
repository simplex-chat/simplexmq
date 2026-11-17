{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Transport.KeepAlive
  ( KeepAliveOpts (..),
    defaultKeepAliveOpts,
    setSocketKeepAlive,
  ) where

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
_TCP_KEEPIDLE :: CInt
_TCP_KEEPIDLE = 3
_TCP_KEEPINTVL :: CInt
_TCP_KEEPINTVL = 17
_TCP_KEEPCNT :: CInt
_TCP_KEEPCNT = 16

#elif defined(darwin_HOST_OS)
-- macOS (Darwin)
foreign import capi "netinet/tcp.h value TCP_KEEPALIVE" _TCP_KEEPIDLE :: CInt
foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt
foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

#elif defined(openbsd_HOST_OS)
-- OpenBSD: These constants are not directly available via setsockopt in the same way.
-- We define dummy values to satisfy compilation, but note that these options may be ignored or unsupported.
_TCP_KEEPIDLE :: CInt
_TCP_KEEPIDLE = 0 -- Dummy value; OpenBSD does not support per-socket keepalive tuning via TCP_* options
_TCP_KEEPINTVL :: CInt
_TCP_KEEPINTVL = 0
_TCP_KEEPCNT :: CInt
_TCP_KEEPCNT = 0

#else
-- Linux and other Unix-like systems (FreeBSD, NetBSD, etc.)
foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" _TCP_KEEPIDLE :: CInt
foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt
foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

#endif

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
#if defined(openbsd_HOST_OS)
  -- On OpenBSD, these options are typically ignored. We skip them to avoid errors.
#else
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPIDLE) keepIdle
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPINTVL) keepIntvl
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPCNT) keepCnt
#endif

$(J.deriveJSON defaultJSON ''KeepAliveOpts)
