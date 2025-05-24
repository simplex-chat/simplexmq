module Main where

import Control.Logger.Simple
import Simplex.Messaging.Server.CLI (getEnvPath)
import Simplex.Messaging.Server.Main
import qualified Static

defaultCfgPath :: FilePath
defaultCfgPath = "/etc/opt/simplex"

defaultLogPath :: FilePath
defaultLogPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  cfgPath <- getEnvPath "SMP_SERVER_CFG_PATH" defaultCfgPath
  logPath <- getEnvPath "SMP_SERVER_LOG_PATH" defaultLogPath
  withGlobalLogging logCfg $ smpServerCLI_ Static.generateSite Static.serveStaticFiles Static.attachStaticFiles cfgPath logPath
