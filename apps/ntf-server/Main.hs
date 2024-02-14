module Main where

import Control.Logger.Simple
import Simplex.Messaging.Server.CLI (getEnvPath)
import Simplex.Messaging.Notifications.Server.Main

defaultCfgPath :: FilePath
defaultCfgPath = "/etc/opt/simplex-notifications"

defaultLogPath :: FilePath
defaultLogPath = "/var/opt/simplex-notifications"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug -- change to LogError in production
  cfgPath <- getEnvPath "NTF_SERVER_CFG_PATH" defaultCfgPath
  logPath <- getEnvPath "NTF_SERVER_LOG_PATH" defaultLogPath
  withGlobalLogging logCfg $ ntfServerCLI cfgPath logPath
