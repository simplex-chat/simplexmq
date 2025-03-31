{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.FileTransfer.Server.Main where

import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Network.Socket (HostName)
import Options.Applicative
import Simplex.FileTransfer.Chunks
import Simplex.FileTransfer.Description (FileSize (..))
import Simplex.FileTransfer.Server (runXFTPServer)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..), defFileExpirationHours, defaultFileExpiration, defaultInactiveClientExpiration)
import Simplex.FileTransfer.Transport (supportedFileServerVRange)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), pattern XFTPServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (ServerCredentials (..), TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (safeDecodeUtf8, tshow)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

xftpServerCLI :: FilePath -> FilePath -> IO ()
xftpServerCLI cfgPath logPath = do
  getCliCommand' (cliCommandP cfgPath logPath iniFile) serverVersion >>= \case
    Init opts ->
      doesFileExist iniFile >>= \case
        True -> exitError $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `" <> executableName <> " start`."
        _ -> initializeServer opts
    OnlineCert certOpts ->
      doesFileExist iniFile >>= \case
        True -> genOnline cfgPath certOpts
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `" <> executableName <> " init`."
    Start ->
      doesFileExist iniFile >>= \case
        True -> readIniFile iniFile >>= either exitError runServer
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `" <> executableName <> " init`."
    Delete -> do
      confirmOrExit
        "WARNING: deleting the server will make all queues inaccessible, because the server identity (certificate fingerprint) will change.\nTHIS CANNOT BE UNDONE!"
        "Server NOT deleted"
      deleteDirIfExists cfgPath
      deleteDirIfExists logPath
      putStrLn "Deleted configuration and log files"
  where
    iniFile = combine cfgPath "file-server.ini"
    serverVersion = "SimpleX XFTP server v" <> simplexMQVersion
    defaultServerPort = "443"
    executableName = "file-server"
    storeLogFilePath = combine logPath "file-server-store.log"
    initializeServer InitOptions {enableStoreLog, signAlgorithm, ip, fqdn, filesPath, fileSizeQuota} = do
      clearDirIfExists cfgPath
      clearDirIfExists logPath
      createDirectoryIfMissing True cfgPath
      createDirectoryIfMissing True logPath
      let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
      fp <- createServerX509 cfgPath x509cfg
      let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
          srv = ProtoServerWithAuth (XFTPServer [THDomainName host] "" (C.KeyHash fp)) Nothing
      T.writeFile iniFile $ iniFileContent host
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
            <> "# Expire files after the specified number of hours.\n"
            <> ("expire_files_hours: " <> tshow defFileExpirationHours <> "\n\n")
            <> "log_stats: off\n\
               \\n\
               \[AUTH]\n\
               \# Set new_files option to off to completely prohibit uploading new files.\n\
               \# This can be useful when you want to decommission the server, but still allow downloading the existing files.\n\
               \new_files: on\n\
               \\n\
               \# Use create_password option to enable basic auth to upload new files.\n\
               \# The password should be used as part of server address in client configuration:\n\
               \# xftp://fingerprint:password@host1,host2\n\
               \# The password will not be shared with file recipients, you must share it only\n\
               \# with the users who you want to allow uploading files to your server.\n\
               \# create_password: password to upload files (any printable ASCII characters without whitespace, '@', ':' and '/')\n\
               \\n\
               \# control_port_admin_password:\n\
               \# control_port_user_password:\n\
               \\n\
               \[TRANSPORT]\n\
               \# host is only used to print server address on start\n"
            <> ("host: " <> T.pack host <> "\n")
            <> ("port: " <> T.pack defaultServerPort <> "\n")
            <> "log_tls_errors: off\n\
               \# control_port: 5226\n\
               \\n\
               \[FILES]\n"
            <> ("path: " <> T.pack filesPath <> "\n")
            <> ("storage_quota: " <> safeDecodeUtf8 (strEncode fileSizeQuota) <> "\n")
            <> "\n\
               \[INACTIVE_CLIENTS]\n\
               \# TTL and interval to check inactive clients\n\
               \disconnect: off\n"
            <> ("# ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
            <> ("# check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration) <> "\n")
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = fromRight "<hostnames>" $ T.unpack <$> lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          srv = ProtoServerWithAuth (XFTPServer [THDomainName host] (if port == "443" then "" else port) (C.KeyHash fp)) Nothing
      printServiceInfo serverVersion srv
      printXFTPConfig serverConfig
      runXFTPServer serverConfig
      where
        enableStoreLog = settingIsOn "STORE_LOG" "enable" ini
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        printXFTPConfig XFTPServerConfig {allowNewFiles, newFileBasicAuth, xftpPort, storeLogFile, fileExpiration, inactiveClientExpiration} = do
          putStrLn $ case storeLogFile of
            Just f -> "Store log: " <> f
            _ -> "Store log disabled."
          putStrLn $ case fileExpiration of
            Just ExpirationConfig {ttl} -> "expiring files after " <> showTTL ttl
            _ -> "not expiring files"
          putStrLn $ case inactiveClientExpiration of
            Just ExpirationConfig {ttl, checkInterval} -> "expiring clients inactive for " <> show ttl <> " seconds every " <> show checkInterval <> " seconds"
            _ -> "not expiring inactive clients"
          putStrLn $
            "Uploading new files "
              <> if allowNewFiles
                then maybe "allowed." (const "requires password.") newFileBasicAuth
                else "NOT allowed."
          putStrLn $ "Listening on port " <> xftpPort <> "..."

        serverConfig =
          XFTPServerConfig
            { xftpPort = T.unpack $ strictIni "TRANSPORT" "port" ini,
              controlPort = either (const Nothing) (Just . T.unpack) $ lookupValue "TRANSPORT" "control_port" ini,
              fileIdSize = 16,
              storeLogFile = enableStoreLog $> storeLogFilePath,
              filesPath = T.unpack $ strictIni "FILES" "path" ini,
              fileSizeQuota = either error unFileSize <$> strDecodeIni "FILES" "storage_quota" ini,
              allowedChunkSizes = serverChunkSizes,
              allowNewFiles = fromMaybe True $ iniOnOff "AUTH" "new_files" ini,
              newFileBasicAuth = either error id <$> strDecodeIni "AUTH" "create_password" ini,
              controlPortAdminAuth = either error id <$> strDecodeIni "AUTH" "control_port_admin_password" ini,
              controlPortUserAuth = either error id <$> strDecodeIni "AUTH" "control_port_user_password" ini,
              fileExpiration =
                Just
                  defaultFileExpiration
                    { ttl = 3600 * readIniDefault defFileExpirationHours "STORE_LOG" "expire_files_hours" ini
                    },
              fileTimeout = 5 * 60 * 1000000, -- 5 mins to send 4mb chunk
              inactiveClientExpiration =
                settingIsOn "INACTIVE_CLIENTS" "disconnect" ini
                  $> ExpirationConfig
                    { ttl = readStrictIni "INACTIVE_CLIENTS" "ttl" ini,
                      checkInterval = readStrictIni "INACTIVE_CLIENTS" "check_interval" ini
                    },
              xftpCredentials =
                ServerCredentials
                  { caCertificateFile = Just $ c caCrtFile,
                    privateKeyFile = c serverKeyFile,
                    certificateFile = c serverCrtFile
                  },
              xftpServerVRange = supportedFileServerVRange,
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "file-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "file-server-stats.log",
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini
                  },
              responseDelay = 0
            }

data CliCommand
  = Init InitOptions
  | OnlineCert CertOptions
  | Start
  | Delete

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName,
    filesPath :: FilePath,
    fileSizeQuota :: FileSize Int64
  }
  deriving (Show)

cliCommandP :: FilePath -> FilePath -> FilePath -> Parser CliCommand
cliCommandP cfgPath logPath iniFile =
  hsubparser
    ( command "init" (info (Init <$> initP) (progDesc $ "Initialize server - creates " <> cfgPath <> " and " <> logPath <> " directories and configuration files"))
        <> command "cert" (info (OnlineCert <$> certOptionsP) (progDesc $ "Generate new online TLS server credentials (configuration: " <> iniFile <> ")"))
        <> command "start" (info (pure Start) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
        <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
    )
  where
    initP :: Parser InitOptions
    initP = do
      enableStoreLog <-
        flag' False
          ( long "disable-store-log"
              <> help "Disable store log for persistence (enabled by default)"
          )
          <|> flag True True
            ( long "store-log"
                <> short 'l'
                <> help "Enable store log for persistence (DEPRECATED, enabled by default)"
            )
      signAlgorithm <-
        option
          (maybeReader readMaybe)
          ( long "sign-algorithm"
              <> short 'a'
              <> help "Signature algorithm used for TLS certificates: ED25519, ED448"
              <> value ED448
              <> showDefault
              <> metavar "ALG"
          )
      ip <-
        strOption
          ( long "ip"
              <> help
                "Server IP address, used as Common Name for TLS online certificate if FQDN is not supplied"
              <> value "127.0.0.1"
              <> showDefault
              <> metavar "IP"
          )
      fqdn <-
        (optional . strOption)
          ( long "fqdn"
              <> short 'n'
              <> help "Server FQDN used as Common Name for TLS online certificate"
              <> showDefault
              <> metavar "FQDN"
          )
      filesPath <-
        strOption
          ( long "path"
              <> short 'p'
              <> help "Path to the directory to store files"
              <> metavar "PATH"
          )
      fileSizeQuota <-
        strOption
          ( long "quota"
              <> short 'q'
              <> help "File storage quota (e.g. 100gb)"
              <> metavar "QUOTA"
          )
      pure InitOptions {enableStoreLog, signAlgorithm, ip, fqdn, filesPath, fileSizeQuota}
