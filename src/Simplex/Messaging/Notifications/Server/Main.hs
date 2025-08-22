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

import Control.Logger.Simple (setLogLevel)
import Control.Monad ((<$!>))
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as T
import Network.Socket (HostName, ServiceName)
import Options.Applicative
import Simplex.Messaging.Agent.Store.Postgres (checkSchemaExists)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SMPWebPortServers (..), SocksMode (..), defaultNetworkConfig, textToHostMode)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (NtfTokenId)
import Simplex.Messaging.Notifications.Server (runNtfServer, restoreServerLastNtfs)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..), defaultInactiveClientExpiration)
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Notifications.Server.Store (newNtfSTMStore)
import Simplex.Messaging.Notifications.Server.Store.Postgres (exportNtfDbStore, importNtfSTMStore, newNtfDbStore)
import Simplex.Messaging.Notifications.Server.StoreLog (readWriteNtfSTMStore)
import Simplex.Messaging.Notifications.Transport (alpnSupportedNTFHandshakes, supportedServerNTFVRange)
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), pattern NtfServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Main (strParse)
import Simplex.Messaging.Server.Main.Init (iniDbOpts)
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Server.StoreLog (closeStoreLog)
import Simplex.Messaging.Transport (ASrvTransport)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.HTTP2 (httpALPN)
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials (..), mkTransportServerConfig)
import Simplex.Messaging.Util (eitherToMaybe, ifM, tshow)
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
      lastNtfsExists <- doesFileExist defaultLastNtfsFile
      case cmd of
        SCImport skipTokens
          | schemaExists && (storeLogExists || lastNtfsExists) -> exitConfigureNtfStore connstr schema
          | schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " already exists in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | not storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file does not exist."
              exitFailure
          | not lastNtfsExists -> do
              putStrLn $ defaultLastNtfsFile <> " file does not exist."
              exitFailure
          | otherwise -> do
              storeLogFile <- getRequiredStoreLogFile ini
              confirmOrExit
                ("WARNING: store log file " <> storeLogFile <> " will be compacted and imported to PostrgreSQL database: " <> B.unpack connstr <> ", schema: " <> B.unpack schema)
                "Notification server store not imported"
              stmStore <- newNtfSTMStore
              sl <- readWriteNtfSTMStore True storeLogFile stmStore
              closeStoreLog sl
              restoreServerLastNtfs stmStore defaultLastNtfsFile
              let storeCfg = PostgresStoreCfg {dbOpts = dbOpts {createSchema = True}, dbStoreLogPath = Nothing, confirmMigrations = MCConsole, deletedTTL = iniDeletedTTL ini}
              ps <- newNtfDbStore storeCfg
              (tCnt, sCnt, nCnt, serviceCnt) <- importNtfSTMStore ps stmStore skipTokens
              renameFile storeLogFile $ storeLogFile <> ".bak"
              putStrLn $ "Import completed: " <> show tCnt <> " tokens, " <> show sCnt <> " subscriptions, " <> show serviceCnt <> " service associations, " <> show nCnt <> " last token notifications."
              putStrLn "Configure database options in INI file."
        SCExport
          | schemaExists && storeLogExists -> exitConfigureNtfStore connstr schema
          | not schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " does not exist in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file already exists."
              exitFailure
          | lastNtfsExists -> do
              putStrLn $ defaultLastNtfsFile <> " file already exists."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: PostrgreSQL database schema " <> B.unpack schema <> " (database: " <> B.unpack connstr <> ") will be exported to store log file " <> storeLogFilePath)
                "Notification server store not imported"
              let storeCfg = PostgresStoreCfg {dbOpts, dbStoreLogPath = Just storeLogFilePath, confirmMigrations = MCConsole, deletedTTL = iniDeletedTTL ini}
              st <- newNtfDbStore storeCfg
              (tCnt, sCnt, nCnt) <- exportNtfDbStore st defaultLastNtfsFile
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
    serverVersion = "SMP notifications server v" <> simplexmqVersionCommit
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
            <> "# Database connection settings for PostgreSQL database.\n"
            <> iniDbOpts dbOptions defaultNtfDBOpts
            <> "Time to retain deleted entities in the database, days.\n"
            <> ("# db_deleted_ttl: " <> tshow defaultDeletedTTL <> "\n\n")
            <> "log_stats: off\n\n\
               \# Log interval for real-time Prometheus metrics\n\
               \# prometheus_interval: 60\n\
               \\n\
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
               \# User service subscriptions with server certificate\n\n\
               \# use_service_credentials: off\n\n\
               \[INACTIVE_CLIENTS]\n\
               \# TTL and interval to check inactive clients\n\
               \disconnect: off\n"
            <> ("# ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
            <> ("# check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration) <> "\n")
    enableStoreLog' = settingIsOn "STORE_LOG" "enable"
    runServer startOptions ini = do
      setLogLevel $ logLevel startOptions
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@NtfServerConfig {transports} = serverConfig
          srv = ProtoServerWithAuth (NtfServer [THDomainName host] (if port == "443" then "" else port) (C.KeyHash fp)) Nothing
      printServiceInfo serverVersion srv
      printNtfServerConfig transports dbStoreConfig
      runNtfServer cfg
      where
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        dbStoreLogPath = enableStoreLog' ini $> storeLogFilePath
        dbStoreConfig =
          PostgresStoreCfg
            { dbOpts = iniDBOptions ini defaultNtfDBOpts,
              dbStoreLogPath,
              confirmMigrations = MCYesUp,
              deletedTTL = iniDeletedTTL ini
            }
        serverConfig =
          NtfServerConfig
            { transports = iniTransports ini,
              controlPort = either (const Nothing) (Just . T.unpack) $ lookupValue "TRANSPORT" "control_port" ini,
              controlPortAdminAuth = either error id <$!> strDecodeIni "AUTH" "control_port_admin_password" ini,
              controlPortUserAuth = either error id <$!> strDecodeIni "AUTH" "control_port_user_password" ini,
              subIdBytes = 24,
              regCodeBytes = 32,
              clientQSize = 64,
              pushQSize = 32768,
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
                                smpWebPortServers = SWPOff,
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
              dbStoreConfig,
              ntfCredentials =
                ServerCredentials
                  { caCertificateFile = Just $ c caCrtFile,
                    privateKeyFile = c serverKeyFile,
                    certificateFile = c serverCrtFile
                  },
              useServiceCreds = fromMaybe False $ iniOnOff "SUBSCRIBER" "use_service_credentials" ini,
              periodicNtfsInterval = 5 * 60, -- 5 minutes
              logStatsInterval = logStats $> 86400, -- seconds
              logStatsStartTime = 0, -- seconds from 00:00 UTC
              serverStatsLogFile = combine logPath "ntf-server-stats.daily.log",
              serverStatsBackupFile = logStats $> combine logPath "ntf-server-stats.log",
              prometheusInterval = eitherToMaybe $ read . T.unpack <$> lookupValue "STORE_LOG" "prometheus_interval" ini,
              prometheusMetricsFile = combine logPath "ntf-server-metrics.txt",
              ntfServerVRange = supportedServerNTFVRange,
              transportConfig =
                mkTransportServerConfig
                  (fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini)
                  (Just $ alpnSupportedNTFHandshakes <> httpALPN)
                  False,
              startOptions
            }
    iniDeletedTTL ini = readIniDefault (86400 * defaultDeletedTTL) "STORE_LOG" "db_deleted_ttl" ini
    defaultLastNtfsFile = combine logPath "ntf-server-last-notifications.log"
    exitConfigureNtfStore connstr schema = do
      putStrLn $ "Error: both " <> storeLogFilePath <> " file and " <> B.unpack schema <> " schema are present (database: " <> B.unpack connstr <> ")."
      putStrLn "Configure notification server storage."
      exitFailure

printNtfServerConfig :: [(ServiceName, ASrvTransport, AddHTTP)] -> PostgresStoreCfg -> IO ()
printNtfServerConfig transports PostgresStoreCfg {dbOpts = DBOpts {connstr, schema}, dbStoreLogPath} = do
  B.putStrLn $ "PostgreSQL database: " <> connstr <> ", schema: " <> schema
  printServerConfig "NTF" transports dbStoreLogPath

data CliCommand
  = Init InitOptions
  | OnlineCert CertOptions
  | Start StartOptions
  | Delete
  | Database StoreCmd DBOpts

data StoreCmd = SCImport (Set NtfTokenId) | SCExport

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
    { connstr = "postgresql://ntf@/ntf_server_store",
      schema = "ntf_server",
      poolSize = 10,
      createSchema = False
    }

-- time to retain deleted tokens and subscriptions in the database (days), for debugging
defaultDeletedTTL :: Int64
defaultDeletedTTL = 21

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
        ( command "import" (info (SCImport <$> skipTokensP) (progDesc $ "Import store logs into a new PostgreSQL database schema"))
            <> command "export" (info (pure SCExport) (progDesc $ "Export PostgreSQL database schema to store logs"))
        )
    skipTokensP :: Parser (Set NtfTokenId)
    skipTokensP =
      option
        strParse
          ( long "skip-tokens"
              <> help "Skip tokens during import"
              <> value S.empty
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
