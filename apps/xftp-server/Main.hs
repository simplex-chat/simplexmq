module Main where

import Control.Logger.Simple
import Simplex.FileTransfer.Server.Main (xftpServerCLI_)
import Simplex.Messaging.Server.CLI (getEnvPath)
import Simplex.Messaging.Server.Web (serveStaticFiles)
import XFTP.Web (xftpGenerateSite)

defaultCfgPath :: FilePath
defaultCfgPath = "/etc/opt/simplex-xftp"

defaultLogPath :: FilePath
defaultLogPath = "/var/opt/simplex-xftp"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug -- change to LogError in production
  cfgPath <- getEnvPath "XFTP_SERVER_CFG_PATH" defaultCfgPath
  logPath <- getEnvPath "XFTP_SERVER_LOG_PATH" defaultLogPath
  withGlobalLogging logCfg $ xftpServerCLI_ xftpGenerateSite serveStaticFiles cfgPath logPath
