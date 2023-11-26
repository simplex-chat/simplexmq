{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Notifications.Server.Main where

import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Client (ProtocolClientConfig (..))
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), pattern NtfServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), defaultTransportServerConfig)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

ntfServerVersion :: String
ntfServerVersion = "1.6.4"

defaultSMPBatchDelay :: Int
defaultSMPBatchDelay = 10000

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
    serverVersion = "SMP notifications server v" <> ntfServerVersion
    defaultServerPort = "443"
    executableName = "ntf-server"
    storeLogFilePath = combine logPath "ntf-server-store.log"
    initializeServer InitOptions {enableStoreLog, signAlgorithm, ip, fqdn} = do
      clearDirIfExists cfgPath
      clearDirIfExists logPath
      createDirectoryIfMissing True cfgPath
      createDirectoryIfMissing True logPath
      let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
      fp <- createServerX509 cfgPath x509cfg
      let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
          srv = ProtoServerWithAuth (NtfServer [THDomainName host] "" (C.KeyHash fp)) Nothing
      writeFile iniFile $ iniFileContent host
      putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `" <> executableName <> " start` to start server."
      warnCAPrivateKeyFile cfgPath x509cfg
      printServiceInfo serverVersion srv
      where
        iniFileContent host =
          "[STORE_LOG]\n\
          \# The server uses STM memory for persistence,\n\
          \# that will be lost on restart (e.g., as with redis).\n\
          \# This option enables saving memory to append only log,\n\
          \# and restoring it when the server is started.\n\
          \# Log is compacted on start (deleted objects are removed).\n"
            <> ("enable: " <> onOff enableStoreLog <> "\n\n")
            <> "log_stats: off\n\n\
               \[TRANSPORT]\n\
               \# host is only used to print server address on start\n"
            <> ("host: " <> host <> "\n")
            <> ("port: " <> defaultServerPort <> "\n")
            <> "log_tls_errors: off\n\
               \# delay between command batches sent to SMP relays (microseconds), 0 to disable\n"
            <> ("smp_batch_delay: " <> show defaultSMPBatchDelay <> "\n")
            <> "websockets: off\n"
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@NtfServerConfig {transports, storeLogFile} = serverConfig
          srv = ProtoServerWithAuth (NtfServer [THDomainName host] (if port == "443" then "" else port) (C.KeyHash fp)) Nothing
      printServiceInfo serverVersion srv
      printServerConfig transports storeLogFile
      runNtfServer cfg
      where
        enableStoreLog = settingIsOn "STORE_LOG" "enable" ini
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        smpBatchDelay = readIniDefault defaultSMPBatchDelay "TRANSPORT" "smp_batch_delay" ini
        batchDelay = if smpBatchDelay <= 0 then Nothing else Just smpBatchDelay
        serverConfig =
          NtfServerConfig
            { transports = iniTransports ini,
              subIdBytes = 24,
              regCodeBytes = 32,
              clientQSize = 64,
              subQSize = 512,
              pushQSize = 1048,
              smpAgentCfg = defaultSMPClientAgentConfig {smpCfg = (smpCfg defaultSMPClientAgentConfig) {batchDelay}},
              apnsConfig = defaultAPNSPushClientConfig,
              subsBatchSize = 900,
              inactiveClientExpiration = Nothing,
              storeLogFile = enableStoreLog $> storeLogFilePath,
              caCertificateFile = c caCrtFile,
              privateKeyFile = c serverKeyFile,
              certificateFile = c serverCrtFile,
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "ntf-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "ntf-server-stats.log",
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini
                  }
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
