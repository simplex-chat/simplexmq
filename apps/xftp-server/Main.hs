module Main where

import Control.Logger.Simple
import Simplex.FileTransfer.Server.Main

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex-xftp"

logPath :: FilePath
logPath = "/var/opt/simplex-xftp"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug -- change to LogError in production
  withGlobalLogging logCfg $ xftpServerCLI cfgPath logPath
