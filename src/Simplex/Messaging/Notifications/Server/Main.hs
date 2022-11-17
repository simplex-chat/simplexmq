{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Main where

import Data.Functor (($>))
import Data.Ini (readIniFile)
import Data.Maybe (fromMaybe)
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Server.CLI
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

ntfServerCLI :: FilePath -> FilePath -> IO ()
ntfServerCLI cfgPath logPath =
  getCliCommand' (cliCommandP cfgPath logPath iniFile) serverVersion >>= \case
    Init opts ->
      doesFileExist iniFile >>= \case
        True -> exitError $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `" <> executableName <> " start`."
        _ -> initializeServer opts
    Start ->
      doesFileExist iniFile >>= \case
        True -> readIniFile iniFile >>= either exitError runServer
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `" <> executableName <> " init`."
    Delete -> do
      confirmOrExit "WARNING: deleting the server will make all queues inaccessible, because the server identity (certificate fingerprint) will change.\nTHIS CANNOT BE UNDONE!"
      deleteDirIfExists cfgPath
      deleteDirIfExists logPath
      putStrLn "Deleted configuration and log files"
  where
    iniFile = combine cfgPath "ntf-server.ini"
    serverVersion = "SMP notifications server v1.2.0"
    defaultServerPort = "443"
    executableName = "ntf-server"
    storeLogFilePath = combine logPath "ntf-server-store.log"
    initializeServer InitOptions {enableStoreLog, signAlgorithm, ip, fqdn} = do
      deleteDirIfExists cfgPath
      deleteDirIfExists logPath
      createDirectoryIfMissing True cfgPath
      createDirectoryIfMissing True logPath
      let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
      fp <- createServerX509 cfgPath x509cfg
      writeFile iniFile iniFileContent
      putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `" <> executableName <> " start` to start server."
      printServiceInfo serverVersion fp
      warnCAPrivateKeyFile cfgPath x509cfg
      where
        iniFileContent =
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
               \websockets: off\n"
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      printServiceInfo serverVersion fp
      let cfg@NtfServerConfig {transports, storeLogFile} = serverConfig
      printServerConfig transports storeLogFile
      runNtfServer cfg
      where
        enableStoreLog = settingIsOn "STORE_LOG" "enable" ini
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        serverConfig =
          NtfServerConfig
            { transports = iniTransports ini,
              subIdBytes = 24,
              regCodeBytes = 32,
              clientQSize = 16,
              subQSize = 64,
              pushQSize = 128,
              smpAgentCfg = defaultSMPClientAgentConfig,
              apnsConfig = defaultAPNSPushClientConfig,
              inactiveClientExpiration = Nothing,
              storeLogFile = enableStoreLog $> storeLogFilePath,
              resubscribeDelay = 50000, -- 50ms
              caCertificateFile = c caCrtFile,
              privateKeyFile = c serverKeyFile,
              certificateFile = c serverCrtFile,
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "ntf-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "ntf-server-stats.log"
            }

data CliCommand
  = Init InitOptions
  | Start
  | Delete

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName
  }
  deriving (Show)

cliCommandP :: FilePath -> FilePath -> FilePath -> Parser CliCommand
cliCommandP cfgPath logPath iniFile =
  hsubparser
    ( command "init" (info (Init <$> initP) (progDesc $ "Initialize server - creates " <> cfgPath <> " and " <> logPath <> " directories and configuration files"))
        <> command "start" (info (pure Start) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
        <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
    )
  where
    initP :: Parser InitOptions
    initP =
      InitOptions
        <$> switch
          ( long "store-log"
              <> short 'l'
              <> help "Enable store log for persistence"
          )
        <*> option
          (maybeReader readMaybe)
          ( long "sign-algorithm"
              <> short 'a'
              <> help "Signature algorithm used for TLS certificates: ED25519, ED448"
              <> value ED448
              <> showDefault
              <> metavar "ALG"
          )
        <*> strOption
          ( long "ip"
              <> help
                "Server IP address, used as Common Name for TLS online certificate if FQDN is not supplied"
              <> value "127.0.0.1"
              <> showDefault
              <> metavar "IP"
          )
        <*> (optional . strOption)
          ( long "fqdn"
              <> short 'n'
              <> help "Server FQDN used as Common Name for TLS online certificate"
              <> showDefault
              <> metavar "FQDN"
          )
