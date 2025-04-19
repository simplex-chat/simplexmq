{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Notifications.Server.Main where

import Control.Monad ((<$!>))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as T
import Network.Socket (HostName)
import Numeric.Natural (Natural)
import Options.Applicative
import Simplex.Messaging.Agent.Store.Postgres (checkSchemaExists)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SocksMode (..), defaultNetworkConfig, textToHostMode)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..), defaultInactiveClientExpiration)
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Notifications.Server.Store (newNtfSTMStore)
import Simplex.Messaging.Notifications.Server.Store.Postgres (NtfPostgresStoreCfg (..), exportNtfDbStore, importNtfSTMStore, newNtfDbStore)
import Simplex.Messaging.Notifications.Server.StoreLog (readWriteNtfSTMStore)
import Simplex.Messaging.Notifications.Transport (supportedServerNTFVRange)
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), pattern NtfServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM (StartOptions)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Main.Init (optDisabled')
import Simplex.Messaging.Server.StoreLog (closeStoreLog)
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (ServerCredentials (..), TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (ifM, safeDecodeUtf8, tshow)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Exit (exitFailure)
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
    OnlineCert certOpts -> withIniFile $ \_ -> genOnline cfgPath certOpts
    Start opts -> withIniFile $ runServer opts
    Delete -> do
      confirmOrExit
        "WARNING: deleting the server will make all queues inaccessible, because the server identity (certificate fingerprint) will change.\nTHIS CANNOT BE UNDONE!"
        "Server NOT deleted"
      deleteDirIfExists cfgPath
      deleteDirIfExists logPath
      putStrLn "Deleted configuration and log files"
    Database cmd dbOpts@DBOpts {connstr, schema} -> withIniFile $ \ini -> do
      schemaExists <- checkSchemaExists connstr schema
      storeLogExists <- doesFileExist storeLogFilePath
      case cmd of
        SCImport
          | schemaExists && storeLogExists -> exitConfigureNtfStore connstr schema
          | schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " already exists in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | not storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file does not exist."
              exitFailure
          | otherwise -> do
              storeLogFile <- getRequiredStoreLogFile ini
              -- TODO [ntfdb] get and read file with last notifications
              confirmOrExit
                ("WARNING: store log file " <> storeLogFile <> " will be compacted and imported to PostrgreSQL database: " <> B.unpack connstr <> ", schema: " <> B.unpack schema)
                "Notification server store not imported"
              stmStore <- newNtfSTMStore
              sl <- readWriteNtfSTMStore storeLogFile stmStore
              closeStoreLog sl
              let storeCfg = NtfPostgresStoreCfg {dbOpts = dbOpts {createSchema = True}, dbStoreLogPath = Nothing, confirmMigrations = MCConsole, tokenNtfsTTL = iniTokenNtfsTTL ini}
              ps <- newNtfDbStore storeCfg
              (tCnt, sCnt, nCnt) <- importNtfSTMStore ps stmStore
              renameFile storeLogFile $ storeLogFile <> ".bak"
              -- TODO [ntfdb] rename file with last notifications
              putStrLn $ "Import completed: " <> show tCnt <> " tokens, " <> show sCnt <> " subscriptions, " <> show nCnt <> " last token notifications."
              putStrLn "Configure database options in INI file."
        SCExport
          | schemaExists && storeLogExists -> exitConfigureNtfStore connstr schema
          | not schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " does not exist in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file already exists."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: PostrgreSQL database schema " <> B.unpack schema <> " (database: " <> B.unpack connstr <> ") will be exported to store log file " <> storeLogFilePath)
                "Notification server store not imported"
              let storeCfg = NtfPostgresStoreCfg {dbOpts, dbStoreLogPath = Just storeLogFilePath, confirmMigrations = MCConsole, tokenNtfsTTL = iniTokenNtfsTTL ini}
              st <- newNtfDbStore storeCfg
              (tCnt, sCnt, nCnt) <- exportNtfDbStore st storeLogFilePath
              putStrLn $ "Export completed: " <> show tCnt <> " tokens, " <> show sCnt <> " subscriptions, " <> show nCnt <> " last token notifications."
  where
    withIniFile a =
      doesFileExist iniFile >>= \case
        True -> readIniFile iniFile >>= either exitError a
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `" <> executableName <> " init`."
    getRequiredStoreLogFile ini = do
      case enableStoreLog' ini $> storeLogFilePath of
        Just storeLogFile -> do
          ifM
            (doesFileExist storeLogFile)
            (pure storeLogFile)
            (putStrLn ("Store log file " <> storeLogFile <> " not found") >> exitFailure)
        Nothing -> putStrLn "Store log disabled, see `[STORE_LOG] enable`" >> exitFailure
    iniFile = combine cfgPath "ntf-server.ini"
    serverVersion = "SMP notifications server v" <> simplexMQVersion
    defaultServerPort = "443"
    executableName = "ntf-server"
    storeLogFilePath = combine logPath "ntf-server-store.log"
    initializeServer InitOptions {enableStoreLog, dbOptions, signAlgorithm, ip, fqdn} = do
      clearDirIfExists cfgPath
      clearDirIfExists logPath
      createDirectoryIfMissing True cfgPath
      createDirectoryIfMissing True logPath
      let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
      fp <- createServerX509 cfgPath x509cfg
      let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
          srv = ProtoServerWithAuth (NtfServer [THDomainName host] "" (C.KeyHash fp)) Nothing
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
            <> "# Database connection settings for PostgreSQL database (`store_queues: database`).\n"
            <> (optDisabled' (connstr == defaultNtfDBConnStr) <> "db_connection: " <> safeDecodeUtf8 connstr <> "\n")
            <> (optDisabled' (schema == defaultNtfDBSchema) <> "db_schema: " <> safeDecodeUtf8 schema <> "\n")
            <> (optDisabled' (poolSize == defaultNtfDBPoolSize) <> "db_pool_size: " <> tshow poolSize <> "\n\n")
            <> "# Last notifications are optionally saved and restored when the server restarts,\n\
               \# they are preserved in the .bak file until the next restart.\n"
            <> ("restore_last_notifications: " <> onOff enableStoreLog <> "\n\n")
            <> "log_stats: off\n\n\
               \[AUTH]\n\
               \# control_port_admin_password:\n\
               \# control_port_user_password:\n\
               \\n\
               \[TRANSPORT]\n\
               \# Host is only used to print server address on start.\n\
               \# You can specify multiple server ports.\n"
            <> ("host: " <> T.pack host <> "\n")
            <> ("port: " <> T.pack defaultServerPort <> "\n")
            <> "log_tls_errors: off\n\n\
               \# Use `websockets: 443` to run websockets server in addition to plain TLS.\n\
               \websockets: off\n\n\
               \# control_port: 5227\n\
               \\n\
               \[SUBSCRIBER]\n\
               \# Network configuration for notification server client.\n\
               \# `host_mode` can be 'public' (default) or 'onion'.\n\
               \# It defines prefferred hostname for destination servers with multiple hostnames.\n\
               \# host_mode: public\n\
               \# required_host_mode: off\n\n\
               \# SOCKS proxy port for subscribing to SMP servers.\n\
               \# You may need a separate instance of SOCKS proxy for incoming single-hop requests.\n\
               \# socks_proxy: localhost:9050\n\n\
               \# `socks_mode` can be 'onion' for SOCKS proxy to be used for .onion destination hosts only (default)\n\
               \# or 'always' to be used for all destination hosts (can be used if it is an .onion server).\n\
               \# socks_mode: onion\n\n\
               \# The domain suffixes of the relays you operate (space-separated) to count as separate proxy statistics.\n\
               \# own_server_domains: \n\n\
               \[INACTIVE_CLIENTS]\n\
               \# TTL and interval to check inactive clients\n\
               \disconnect: off\n"
            <> ("# ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
            <> ("# check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration) <> "\n")
        DBOpts {connstr, schema, poolSize} = dbOptions
    enableStoreLog' = settingIsOn "STORE_LOG" "enable"
    runServer startOptions ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@NtfServerConfig {transports} = serverConfig
          srv = ProtoServerWithAuth (NtfServer [THDomainName host] (if port == "443" then "" else port) (C.KeyHash fp)) Nothing
      printServiceInfo serverVersion srv
      -- TODO [ntfdb] get storeLogFile from NtfPostgresStoreCfg
      -- printServerConfig transports storeLogFile
      runNtfServer cfg
      where
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        -- TODO [ntfdb] remove?
        -- restoreLastNtfsFile path = case iniOnOff "STORE_LOG" "restore_last_notifications" ini of
        --   Just True -> Just path
        --   Just False -> Nothing
        --   -- if the setting is not set, it is enabled when store log is enabled
        --   _ -> enableStoreLog $> path
        serverConfig =
          NtfServerConfig
            { transports = iniTransports ini,
              controlPort = either (const Nothing) (Just . T.unpack) $ lookupValue "TRANSPORT" "control_port" ini,
              controlPortAdminAuth = either error id <$!> strDecodeIni "AUTH" "control_port_admin_password" ini,
              controlPortUserAuth = either error id <$!> strDecodeIni "AUTH" "control_port_user_password" ini,
              subIdBytes = 24,
              regCodeBytes = 32,
              clientQSize = 64,
              subQSize = 512,
              pushQSize = 16384,
              smpAgentCfg =
                defaultSMPClientAgentConfig
                  { smpCfg =
                      (smpCfg defaultSMPClientAgentConfig)
                        { networkConfig =
                            defaultNetworkConfig
                              { socksProxy = either error id <$!> strDecodeIni "SUBSCRIBER" "socks_proxy" ini,
                                socksMode = maybe SMOnion (either error id) $! strDecodeIni "SUBSCRIBER" "socks_mode" ini,
                                hostMode = either (const HMPublic) (either error id . textToHostMode) $ lookupValue "SUBSCRIBER" "host_mode" ini,
                                requiredHostMode = fromMaybe False $ iniOnOff "SUBSCRIBER" "required_host_mode" ini,
                                smpPingInterval = 60_000_000 -- 1 minute
                              }
                        },
                    ownServerDomains = either (const []) (map encodeUtf8 . T.words) $ lookupValue "SUBSCRIBER" "own_server_domains" ini,
                    persistErrorInterval = 0 -- seconds
                  },
              apnsConfig = defaultAPNSPushClientConfig,
              subsBatchSize = 900,
              inactiveClientExpiration =
                settingIsOn "INACTIVE_CLIENTS" "disconnect" ini
                  $> ExpirationConfig
                    { ttl = readStrictIni "INACTIVE_CLIENTS" "ttl" ini,
                      checkInterval = readStrictIni "INACTIVE_CLIENTS" "check_interval" ini
                    },
              dbStoreConfig = 
                let dbStoreLogPath = enableStoreLog' ini $> storeLogFilePath
                 in NtfPostgresStoreCfg {dbOpts = iniDBOptions ini, dbStoreLogPath, confirmMigrations = MCYesUp, tokenNtfsTTL = iniTokenNtfsTTL ini},
              ntfCredentials =
                ServerCredentials
                  { caCertificateFile = Just $ c caCrtFile,
                    privateKeyFile = c serverKeyFile,
                    certificateFile = c serverCrtFile
                  },
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "ntf-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "ntf-server-stats.log",
              ntfServerVRange = supportedServerNTFVRange,
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini
                  },
              startOptions
            }

    -- TODO [ntfdb]
    iniDBOptions = undefined
    -- TODO [ntfdb]
    iniTokenNtfsTTL = undefined

    exitConfigureNtfStore connstr schema = do
      putStrLn $ "Error: both " <> storeLogFilePath <> " file and " <> B.unpack schema <> " schema are present (database: " <> B.unpack connstr <> ")."
      putStrLn "Configure notification server storage."
      exitFailure

data CliCommand
  = Init InitOptions
  | OnlineCert CertOptions
  | Start StartOptions
  | Delete
  | Database StoreCmd DBOpts

data StoreCmd = SCImport | SCExport

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    dbOptions :: DBOpts,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName
  }
  deriving (Show)

defaultNtfDBOpts :: DBOpts
defaultNtfDBOpts =
  DBOpts
    { connstr = defaultNtfDBConnStr,
      schema = defaultNtfDBSchema,
      poolSize = defaultNtfDBPoolSize,
      createSchema = False
    }

defaultNtfDBConnStr :: ByteString
defaultNtfDBConnStr = "postgresql://ntf@/ntf_server_store"

defaultNtfDBSchema :: ByteString
defaultNtfDBSchema = "ntf_server"

defaultNtfDBPoolSize :: Natural
defaultNtfDBPoolSize = 10

cliCommandP :: FilePath -> FilePath -> FilePath -> Parser CliCommand
cliCommandP cfgPath logPath iniFile =
  hsubparser
    ( command "init" (info (Init <$> initP) (progDesc $ "Initialize server - creates " <> cfgPath <> " and " <> logPath <> " directories and configuration files"))
        <> command "cert" (info (OnlineCert <$> certOptionsP) (progDesc $ "Generate new online TLS server credentials (configuration: " <> iniFile <> ")"))
        <> command "start" (info (Start <$> startOptionsP) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
        <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
        <> command "database" (info (Database <$> databaseCmdP <*> dbOptsP defaultNtfDBOpts) (progDesc "Import/export notifications server store to/from PostgreSQL database"))
    )
  where
    databaseCmdP =
      hsubparser
        ( command "import" (info (pure SCImport) (progDesc $ "Import store logs into a new PostgreSQL database schema"))
            <> command "export" (info (pure SCExport) (progDesc $ "Export PostgreSQL database schema to store logs"))
        )
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
      dbOptions <- dbOptsP defaultNtfDBOpts
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
      pure InitOptions {enableStoreLog, dbOptions, signAlgorithm, ip, fqdn}
