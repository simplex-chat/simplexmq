module Main where

import Control.Logger.Simple
import Simplex.Messaging.Server.Main

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex"

logPath :: FilePath
logPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug
  withGlobalLogging logCfg $ smpServerCLI cfgPath logPath
