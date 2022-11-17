{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Main where

import Data.Functor (($>))
import Data.Ini (lookupValue)
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), defaultX509Config, protocolServerCLI)
import System.FilePath (combine)

ntfServerCLI :: FilePath -> FilePath -> IO ()
ntfServerCLI cfgPath logPath = protocolServerCLI (ntfServerCLIConfig cfgPath logPath) runNtfServer

ntfServerCLIConfig :: FilePath -> FilePath -> ServerCLIConfig NtfServerConfig
ntfServerCLIConfig cfgPath logPath =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "ntf-server.ini",
          storeLogFile = combine logPath "ntf-server-store.log",
          x509cfg = defaultX509Config,
          defaultServerPort = "443",
          executableName = "ntf-server",
          serverVersion = "SMP notifications server v1.2.0",
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
