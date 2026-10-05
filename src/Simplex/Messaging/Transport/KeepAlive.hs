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
import Control.Monad (when)
import Foreign.C (CInt (..))
import Network.Socket
import Simplex.Messaging.Parsers (defaultJSON)

data KeepAliveOpts = KeepAliveOpts
  { keepIdle :: Int,
    keepIntvl :: Int,
    keepCnt :: Int,
    -- | A connection with unacknowledged data gets no keep-alive probes, so the OS fails it only when it
    -- gives up retransmitting - ~15 minutes on Linux and Android. When this is set such a connection is
    -- failed after the keep-alive detection time instead. Absent or False - the OS default.
    unackedDataTimeout :: Maybe Bool
  }
  deriving (Eq, Show)

-- seconds after which a connection with no response to the probes is reported as failed
keepAliveDetectionTime :: KeepAliveOpts -> Int
keepAliveDetectionTime KeepAliveOpts {keepIdle, keepIntvl, keepCnt} = keepIdle + keepIntvl * keepCnt

defaultKeepAliveOpts :: KeepAliveOpts
defaultKeepAliveOpts =
  KeepAliveOpts
    { keepIdle = 30,
      keepIntvl = 15,
      keepCnt = 4,
      unackedDataTimeout = Nothing
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

#else
-- Mac/Linux

#if defined(darwin_HOST_OS)
foreign import capi "netinet/tcp.h value TCP_KEEPALIVE" _TCP_KEEPIDLE :: CInt

foreign import capi "netinet/tcp.h value TCP_RXT_CONNDROPTIME" _TCP_RXT_CONNDROPTIME :: CInt
#else
foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" _TCP_KEEPIDLE :: CInt

foreign import capi "netinet/tcp.h value TCP_USER_TIMEOUT" _TCP_USER_TIMEOUT :: CInt
#endif

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" _TCP_KEEPINTVL :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" _TCP_KEEPCNT :: CInt

#endif

-- | seconds
setSocketUnackedDataTimeout :: Socket -> Int -> IO ()
#if defined(mingw32_HOST_OS)
setSocketUnackedDataTimeout _ _ = pure ()
#elif defined(darwin_HOST_OS)
setSocketUnackedDataTimeout sock = setSocketOption sock (SockOpt _SOL_TCP _TCP_RXT_CONNDROPTIME)
#else
setSocketUnackedDataTimeout sock t = setSocketOption sock (SockOpt _SOL_TCP _TCP_USER_TIMEOUT) (t * 1000) -- TCP_USER_TIMEOUT is in milliseconds
#endif

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock ka@KeepAliveOpts {keepCnt, keepIdle, keepIntvl, unackedDataTimeout} = do
  setSocketOption sock KeepAlive 1
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPIDLE) keepIdle
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPINTVL) keepIntvl
  setSocketOption sock (SockOpt _SOL_TCP _TCP_KEEPCNT) keepCnt
  when (unackedDataTimeout == Just True) $ setSocketUnackedDataTimeout sock $ keepAliveDetectionTime ka

$(J.deriveJSON defaultJSON ''KeepAliveOpts)
