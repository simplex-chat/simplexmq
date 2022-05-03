{-# LANGUAGE NamedFieldPuns #-}

module Main where

import Control.Logger.Simple
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..), defaultInactiveClientExpiration)
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), protocolServerCLI)
import System.FilePath (combine)

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex-notifications"

logPath :: FilePath
logPath = "/var/opt/simplex-notifications"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug -- change to LogError in production
  withGlobalLogging logCfg $ protocolServerCLI ntfServerCLIConfig runNtfServer

ntfServerCLIConfig :: ServerCLIConfig NtfServerConfig
ntfServerCLIConfig =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "ntf-server.ini",
          storeLogFile = combine logPath "ntf-server-store.log",
          caKeyFile = combine cfgPath "ca.key",
          caCrtFile,
          serverKeyFile,
          serverCrtFile,
          fingerprintFile = combine cfgPath "fingerprint",
          defaultServerPort = "443",
          executableName = "ntf-server",
          serverVersion = "SMP notifications server v0.1.0",
          mkServerConfig = \_storeLogFile transports ->
            NtfServerConfig
              { transports,
                subIdBytes = 24,
                regCodeBytes = 32,
                clientQSize = 16,
                subQSize = 64,
                pushQSize = 128,
                smpAgentCfg = defaultSMPClientAgentConfig,
                apnsConfig = defaultAPNSPushClientConfig,
                inactiveClientExpiration = Just defaultInactiveClientExpiration,
                caCertificateFile = caCrtFile,
                privateKeyFile = serverKeyFile,
                certificateFile = serverCrtFile
              }
        }
