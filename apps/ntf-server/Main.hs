module Main where

import Control.Logger.Simple
import Simplex.Messaging.Notifications.Server.Main

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex-notifications"

logPath :: FilePath
logPath = "/var/opt/simplex-notifications"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug -- change to LogError in production
  withGlobalLogging logCfg $ ntfServerCLI cfgPath logPath
