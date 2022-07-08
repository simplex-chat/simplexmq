{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Main where

import Control.Logger.Simple
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
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
          serverVersion = "SMP notifications server v1.0.0-rc.1",
          mkIniFile = \enableStoreLog defaultServerPort ->
            "[STORE_LOG]\n\
            \# The server uses STM memory for persistence,\n\
            \# that will be lost on restart (e.g., as with redis).\n\
            \# This option enables saving memory to append only log,\n\
            \# and restoring it when the server is started.\n\
            \# Log is compacted on start (deleted objects are removed).\n\
            \# The messages are not logged.\n"
              <> ("enable: " <> (if enableStoreLog then "on" else "off") <> "\n\n")
              <> "[TRANSPORT]\n\
                 \port: "
              <> defaultServerPort
              <> "\n\
                 \websockets: off\n",
          mkServerConfig = \storeLogFile transports _ ->
            NtfServerConfig
              { transports,
                subIdBytes = 24,
                regCodeBytes = 32,
                clientQSize = 16,
                subQSize = 64,
                pushQSize = 128,
                smpAgentCfg = defaultSMPClientAgentConfig,
                apnsConfig = defaultAPNSPushClientConfig,
                inactiveClientExpiration = Nothing,
                storeLogFile,
                resubscribeDelay = 50000, -- 50ms
                caCertificateFile = caCrtFile,
                privateKeyFile = serverKeyFile,
                certificateFile = serverCrtFile
              }
        }
