module Main where

import Control.Logger.Simple
import Data.Maybe
import Simplex.Messaging.Server.Main
import System.Environment

defaultCfgPath :: FilePath
defaultCfgPath = "/etc/opt/simplex"

defaultLogPath :: FilePath
defaultLogPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug
  cfgPath <- lookupEnv "SMP_SERVER_CFG_PATH"
  logPath <- lookupEnv "SMP_SERVER_LOG_PATH"
  withGlobalLogging logCfg $
    smpServerCLI (fromMaybe defaultCfgPath cfgPath) (fromMaybe defaultLogPath logPath)
