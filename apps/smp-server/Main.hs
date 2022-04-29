{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Logger.Simple
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), protocolServerCLI)
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defaultInactiveClientExpiration, defaultMessageExpiration)
import Simplex.Messaging.Transport (simplexMQVersion)
import System.FilePath (combine)

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex"

logPath :: FilePath
logPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogInfo
  withGlobalLogging logCfg $ protocolServerCLI smpServerCLIConfig runSMPServer

smpServerCLIConfig :: ServerCLIConfig ServerConfig
smpServerCLIConfig =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "smp-server.ini",
          storeLogFile = combine logPath "smp-server-store.log",
          caKeyFile = combine cfgPath "ca.key",
          caCrtFile,
          serverKeyFile,
          serverCrtFile,
          fingerprintFile = combine cfgPath "fingerprint",
          defaultServerPort = "5223",
          executableName = "smp-server",
          serverVersion = "SMP server v" <> simplexMQVersion,
          mkServerConfig = \storeLogFile transports ->
            ServerConfig
              { transports,
                tbqSize = 16,
                serverTbqSize = 64,
                msgQueueQuota = 128,
                queueIdBytes = 24,
                msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
                caCertificateFile = caCrtFile,
                privateKeyFile = serverKeyFile,
                certificateFile = serverCrtFile,
                storeLogFile,
                allowNewQueues = True,
                messageExpiration = Just defaultMessageExpiration,
                inactiveClientExpiration = Just defaultInactiveClientExpiration,
                logStatsInterval = Just 86400, -- seconds
                logStatsStartTime = 0 -- seconds from 00:00 UTC
              }
        }
