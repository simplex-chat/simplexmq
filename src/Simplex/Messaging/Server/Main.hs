{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Main where

import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding (encodeUtf8)
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defaultInactiveClientExpiration, defaultMessageExpiration)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (simplexMQVersion, supportedSMPServerVRange)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

smpServerCLI :: FilePath -> FilePath -> IO ()
smpServerCLI cfgPath logPath =
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
    iniFile = combine cfgPath "smp-server.ini"
    serverVersion = "SMP server v" <> simplexMQVersion
    defaultServerPort = "5223"
    executableName = "smp-server"
    storeLogFilePath = combine logPath "smp-server-store.log"
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
          \# Log is compacted on start (deleted objects are removed).\n"
            <> ("enable: " <> (if enableStoreLog then "on" else "off") <> "\n")
            <> "# Undelivered messages are optionally saved and restored when the server restarts,\n\
               \# they are preserved in the .bak file until the next restart.\n"
            <> ("restore_messages: " <> (if enableStoreLog then "on" else "off") <> "\n")
            <> "log_stats: off\n\n"
            <> "[AUTH]\n"
            <> "# Set new_queues option to off to completely prohibit creating new messaging queues.\n"
            <> "# This can be useful when you want to decommission the server, but not all connections are switched yet.\n"
            <> "new_queues: on\n\n"
            <> "# Use create_password option to enable basic auth to create new messaging queues.\n"
            <> "# The password should be used as part of server address in client configuration:\n"
            <> "# smp://fingerprint:password@host1,host2\n"
            <> "# The password will not be shared with the connecting contacts, you must share it only\n"
            <> "# with the users who you want to allow creating messaging queues on your server.\n"
            <> "# create_password: password to create new queues (any printable ASCII characters without whitespace, '@', ':' and '/')\n\n"
            <> "[TRANSPORT]\n"
            <> ("port: " <> defaultServerPort <> "\n")
            <> "websockets: off\n\n"
            <> "[INACTIVE_CLIENTS]\n\
               \# TTL and interval to check inactive clients\n\
               \disconnect: off\n"
            <> ("# ttl: " <> show (ttl defaultInactiveClientExpiration) <> "\n")
            <> ("# check_interval: " <> show (checkInterval defaultInactiveClientExpiration) <> "\n")
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      printServiceInfo serverVersion fp
      let cfg@ServerConfig {transports, storeLogFile, inactiveClientExpiration} = serverConfig
      printServerConfig transports storeLogFile
      putStrLn $ case inactiveClientExpiration of
        Just ExpirationConfig {ttl, checkInterval} -> "expiring clients inactive for " <> show ttl <> " seconds every " <> show checkInterval <> " seconds"
        _ -> "not expiring inactive clients"
      putStrLn $
        "creating new queues "
          <> if allowNewQueues cfg
            then maybe "allowed" (const "requires basic auth") $ newQueueBasicAuth cfg
            else "NOT allowed"
      runSMPServer cfg
      where
        enableStoreLog = settingIsOn "STORE_LOG" "enable" ini
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        serverConfig =
          ServerConfig
            { transports = iniTransports ini,
              tbqSize = 16,
              serverTbqSize = 64,
              msgQueueQuota = 128,
              queueIdBytes = 24,
              msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
              caCertificateFile = c caCrtFile,
              privateKeyFile = c serverKeyFile,
              certificateFile = c serverCrtFile,
              storeLogFile = enableStoreLog $> storeLogFilePath,
              storeMsgsFile =
                let messagesPath = combine logPath "smp-server-messages.log"
                 in case iniOnOff "STORE_LOG" "restore_messages" ini of
                      Just True -> Just messagesPath
                      Just False -> Nothing
                      -- if the setting is not set, it is enabled when store log is enabled
                      _ -> enableStoreLog $> messagesPath,
              -- allow creating new queues by default
              allowNewQueues = fromMaybe True $ iniOnOff "AUTH" "new_queues" ini,
              newQueueBasicAuth = case lookupValue "AUTH" "create_password" ini of
                Right auth -> either error Just . strDecode $ encodeUtf8 auth
                _ -> Nothing,
              messageExpiration = Just defaultMessageExpiration,
              inactiveClientExpiration =
                settingIsOn "INACTIVE_CLIENTS" "disconnect" ini
                  $> ExpirationConfig
                    { ttl = readStrictIni "INACTIVE_CLIENTS" "ttl" ini,
                      checkInterval = readStrictIni "INACTIVE_CLIENTS" "check_interval" ini
                    },
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "smp-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "smp-server-stats.log",
              smpServerVRange = supportedSMPServerVRange
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
