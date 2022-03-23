module Simplex.Messaging.Notifications.Server.Env where

import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C

data NtfServerConfig = NtfServerConfig
  { tcpPort :: ServiceName,
    cmdSignAlg :: C.SignAlg,
    connIdBytes :: Int,
    tbqSize :: Natural,
    smpCfg :: SMPClientConfig,
    reconnectInterval :: RetryInterval,
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }
