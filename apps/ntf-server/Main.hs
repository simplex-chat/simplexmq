{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Logger.Simple
import Data.Functor (($>))
import Data.Ini (lookupValue)
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
          serverVersion = "SMP notifications server v1.1.2",
          mkIniFile = \enableStoreLog defaultServerPort ->
            "[STORE_LOG]\n\
            \# The server uses STM memory for persistence,\n\
            \# that will be lost on restart (e.g., as with redis).\n\
            \# This option enables saving memory to append only log,\n\
            \# and restoring it when the server is started.\n\
            \# Log is compacted on start (deleted objects are removed).\n\
            \enable: "
              <> (if enableStoreLog then "on" else "off")
              <> "\n\
                 \log_stats: off\n\n\
                 \[TRANSPORT]\n\
                 \port: "
              <> defaultServerPort
              <> "\n\
                 \websockets: off\n",
          mkServerConfig = \storeLogFile transports ini ->
            let settingIsOn section name = if lookupValue section name ini == Right "on" then Just () else Nothing
                logStats = settingIsOn "STORE_LOG" "log_stats"
             in NtfServerConfig
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
                    certificateFile = serverCrtFile,
                    logStatsInterval = logStats $> 86400, -- seconds
                    logStatsStartTime = 0, -- seconds from 00:00 UTC
                    serverStatsLogFile = combine logPath "ntf-server-stats.daily.log",
                    serverStatsBackupFile = logStats $> combine logPath "ntf-server-stats.log"
                  }
        }
