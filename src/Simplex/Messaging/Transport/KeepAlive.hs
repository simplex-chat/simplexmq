{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Transport.KeepAlive where

import Foreign.C (CInt (..))
import Network.Socket

foreign import capi "netinet/tcp.h value TCP_KEEPCNT" tcpKeepCnt :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPIDLE" tcpKeepIdle :: CInt

foreign import capi "netinet/tcp.h value TCP_KEEPINTVL" tcpKeepIntvl :: CInt

foreign import capi "netinet/tcp.h value SOL_TCP" solTcp :: CInt

data KeepAliveOpts = KeepAliveOpts
  { keepCnt :: CInt,
    keepIdle :: CInt,
    keepIntvl :: CInt
  }

defaultKeepAlive :: KeepAliveOpts
defaultKeepAlive =
  KeepAliveOpts
    { keepCnt = 2,
      keepIdle = 30,
      keepIntvl = 15
    }

setSocketKeepAlive :: Socket -> KeepAliveOpts -> IO ()
setSocketKeepAlive sock KeepAliveOpts {keepCnt, keepIdle, keepIntvl} = do
  setSocketOption sock KeepAlive 1
  -- putStrLn $ "solTcp: " <> show solTcp
  -- putStrLn $ "tcpKeepCnt: " <> show tcpKeepCnt
  -- putStrLn $ "tcpKeepIdle: " <> show tcpKeepIdle
  -- putStrLn $ "tcpKeepIntvl: " <> show tcpKeepIntvl
  setSockOpt sock (SockOpt solTcp tcpKeepCnt) keepCnt
  setSockOpt sock (SockOpt solTcp tcpKeepIdle) keepIdle
  setSockOpt sock (SockOpt solTcp tcpKeepIntvl) keepIntvl
