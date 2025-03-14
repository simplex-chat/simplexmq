{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Server.Main where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Logger.Simple
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlpha, isAscii, toUpper)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.List (find, isPrefixOf)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import qualified Data.Text.IO as T
import Network.Socket (ServiceName)
import Options.Applicative
import Simplex.Messaging.Agent.Protocol (connReqUriP')
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SocksMode (..), defaultNetworkConfig, textToHostMode)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (BasicAuth (..), ProtoServerWithAuth (ProtoServerWithAuth), pattern SMPServer)
import Simplex.Messaging.Server (AttachHTTP, exportMessages, importMessages, printMessageStats, runSMPServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main.Options
import Simplex.Messaging.Server.Main.INI
import Simplex.Messaging.Server.MsgStore.Journal (JournalMsgStore (..), QStoreCfg (..), stmQueueStore)
import Simplex.Messaging.Server.MsgStore.Types (MsgStoreClass (..), SQSType (..), SMSType (..), newMsgStore)
import Simplex.Messaging.Server.StoreLog.ReadWrite (readQueueStore)
import Simplex.Messaging.Transport (ATransport, simplexMQVersion, supportedProxyClientSMPRelayVRange, supportedServerSMPRelayVRange)
import Simplex.Messaging.Transport.Client (TransportHost (..), defaultSocksProxy)
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials (..), TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (eitherToMaybe, ifM)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

#if defined(dbServerPostgres)
import Data.Semigroup (Sum (..))
import Simplex.Messaging.Agent.Store.Postgres (checkSchemaExists)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBOpts (..))
import Simplex.Messaging.Server.MsgStore.Journal (JournalQueue)
import Simplex.Messaging.Server.MsgStore.Types (QSType (..))
import Simplex.Messaging.Server.Main.Postgres
import Simplex.Messaging.Server.MsgStore.Journal (postgresQueueStore)
import Simplex.Messaging.Server.QueueStore.Postgres (PostgresStoreCfg (..), batchInsertQueues, foldQueueRecs)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog (logCreateQueue, openWriteStoreLog)
import System.Directory (renameFile)
#endif

smpServerCLI :: FilePath -> FilePath -> IO ()
smpServerCLI = smpServerCLI_ (\_ _ _ -> pure ()) (\_ -> pure ()) (\_ -> error "attachStaticFiles not available")

smpServerCLI_ ::
  (ServerInformation -> Maybe TransportHost -> FilePath -> IO ()) ->
  (EmbeddedWebParams -> IO ()) ->
  (FilePath -> (AttachHTTP -> IO ()) -> IO ()) ->
  FilePath ->
  FilePath ->
  IO ()
smpServerCLI_ generateSite serveStaticFiles attachStaticFiles cfgPath logPath =
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
    Journal cmd -> withIniFile $ \ini -> do
      msgsDirExists <- doesDirectoryExist storeMsgsJournalDir
      msgsFileExists <- doesFileExist storeMsgsFilePath
      storeLogFile <- getRequiredStoreLogFile ini
      case cmd of
        SCImport
          | msgsFileExists && msgsDirExists -> exitConfigureMsgStorage
          | msgsDirExists -> do
              putStrLn $ storeMsgsJournalDir <> " directory already exists."
              exitFailure
          | not msgsFileExists -> do
              putStrLn $ storeMsgsFilePath <> " file does not exist."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: message log file " <> storeMsgsFilePath <> " will be imported to journal directory " <> storeMsgsJournalDir)
                "Messages not imported"
              ms <- newJournalMsgStore MQStoreCfg
              readQueueStore True (mkQueue ms) storeLogFile $ stmQueueStore ms
              msgStats <- importMessages True ms storeMsgsFilePath Nothing False -- no expiration
              putStrLn "Import completed"
              printMessageStats "Messages" msgStats
              putStrLn $ case readStoreType ini of
                Right (ASType SQSMemory SMSMemory) -> "store_messages set to `memory`, update it to `journal` in INI file"
                Right (ASType _ SMSJournal) -> "store_messages set to `journal`"
                Left e -> e <> ", configure storage correctly"
        SCExport
          | msgsFileExists && msgsDirExists -> exitConfigureMsgStorage
          | msgsFileExists -> do
              putStrLn $ storeMsgsFilePath <> " file already exists."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: journal directory " <> storeMsgsJournalDir <> " will be exported to message log file " <> storeMsgsFilePath)
                "Journal not exported"
              ms <- newJournalMsgStore MQStoreCfg
              readQueueStore True (mkQueue ms) storeLogFile $ stmQueueStore ms
              exportMessages True ms storeMsgsFilePath False
              putStrLn "Export completed"
              putStrLn $ case readStoreType ini of
                Right (ASType SQSMemory SMSMemory) -> "store_messages set to `memory`, start the server."
                Right (ASType SQSMemory SMSJournal) -> "store_messages set to `journal`, update it to `memory` in INI file"
#if defined(dbServerPostgres)
                Right (ASType SQSPostgres SMSJournal) -> "store_messages set to `journal`, store_queues is set to `database`.\nExport queues to store log to use memory storage for messages (`smp-server database export`)."
#endif
                Left e -> e <> ", configure storage correctly"
        SCDelete
          | not msgsDirExists -> do
              putStrLn $ storeMsgsJournalDir <> " directory does not exists."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: journal directory " <> storeMsgsJournalDir <> " will be permanently deleted.\nTHIS CANNOT BE UNDONE!")
                "Messages NOT deleted"
              deleteDirIfExists storeMsgsJournalDir
              putStrLn $ "Deleted all messages in journal " <> storeMsgsJournalDir
#if defined(dbServerPostgres)              
    Database cmd dbOpts@DBOpts {connstr, schema} -> withIniFile $ \ini -> do
      schemaExists <- checkSchemaExists connstr schema
      storeLogExists <- doesFileExist storeLogFilePath
      case cmd of
        SCImport
          | schemaExists && storeLogExists -> exitConfigureQueueStore storeLogFilePath connstr schema
          | schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " already exists in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | not storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file does not exist."
              exitFailure
          | otherwise -> do
              storeLogFile <- getRequiredStoreLogFile ini
              confirmOrExit
                ("WARNING: store log file " <> storeLogFile <> " will be imported to PostrgreSQL database: " <> B.unpack connstr <> ", schema: " <> B.unpack schema)
                "Queue records not imported"
              ms <- newJournalMsgStore MQStoreCfg
              readQueueStore True (mkQueue ms) storeLogFile (queueStore ms)
              queues <- readTVarIO $ loadedQueues $ stmQueueStore ms
              let storeCfg = PostgresStoreCfg {dbOpts = dbOpts {createSchema = True}, dbStoreLogPath = Nothing, confirmMigrations = MCConsole, deletedTTL = iniDeletedTTL ini}
              ps <- newJournalMsgStore $ PQStoreCfg storeCfg
              qCnt <- batchInsertQueues @(JournalQueue 'QSMemory) True queues $ postgresQueueStore ps
              renameFile storeLogFile $ storeLogFile <> ".bak"
              putStrLn $ "Import completed: " <> show qCnt <> " queues"
              putStrLn $ case readStoreType ini of
                Right (ASType SQSMemory SMSMemory) -> "store_messages set to `memory`.\nImport messages to journal to use PostgreSQL database for queues (`smp-server journal import`)"
                Right (ASType SQSMemory SMSJournal) -> "store_queues set to `memory`, update it to `database` in INI file"
                Right (ASType SQSPostgres SMSJournal) -> "store_queues set to `database`, start the server."
                Left e -> e <> ", configure storage correctly"
        SCExport
          | schemaExists && storeLogExists -> exitConfigureQueueStore storeLogFilePath connstr schema
          | not schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " does not exist in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | storeLogExists -> do
              putStrLn $ storeLogFilePath <> " file already exists."
              exitFailure
          | otherwise -> do
              confirmOrExit
                ("WARNING: PostrgreSQL database schema " <> B.unpack schema <> " (database: " <> B.unpack connstr <> ") will be exported to store log file " <> storeLogFilePath)
                "Queue records not exported"
              let storeCfg = PostgresStoreCfg {dbOpts, dbStoreLogPath = Nothing, confirmMigrations = MCConsole, deletedTTL = iniDeletedTTL ini}
              ps <- newJournalMsgStore $ PQStoreCfg storeCfg
              sl <- openWriteStoreLog False storeLogFilePath
              Sum qCnt <- foldQueueRecs True (postgresQueueStore ps) $ \(rId, qr) -> logCreateQueue sl rId qr $> Sum (1 :: Int)
              putStrLn $ "Export completed: " <> show qCnt <> " queues"
              putStrLn $ case readStoreType ini of
                Right (ASType SQSPostgres SMSJournal) -> "store_queues set to `database`, update it to `memory` in INI file."
                Right (ASType SQSMemory _) -> "store_queues set to `memory`, start the server"
                Left e -> e <> ", configure storage correctly"
        SCDelete
          | not schemaExists -> do
              putStrLn $ "Schema " <> B.unpack schema <> " does not exist in PostrgreSQL database: " <> B.unpack connstr
              exitFailure
          | otherwise -> do
              putStrLn $ "Open database: psql " <> B.unpack connstr
              putStrLn $ "Delete schema: DROP SCHEMA " <> B.unpack schema <> " CASCADE;"
#endif
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
    newJournalMsgStore :: QStoreCfg s -> IO (JournalMsgStore s)
    newJournalMsgStore qsCfg =
      let cfg = mkJournalStoreConfig qsCfg storeMsgsJournalDir defaultMsgQueueQuota defaultMaxJournalMsgCount defaultMaxJournalStateLines $ checkInterval defaultMessageExpiration
       in newMsgStore cfg
    iniFile = combine cfgPath "smp-server.ini"
    serverVersion = "SMP server v" <> simplexMQVersion
    executableName = "smp-server"
    storeLogFilePath = combine logPath "smp-server-store.log"
    storeMsgsFilePath = combine logPath "smp-server-messages.log"
    storeMsgsJournalDir = combine logPath "messages"
    storeNtfsFilePath = combine logPath "smp-server-ntfs.log"
    readStoreType :: Ini -> Either String AStoreType
    readStoreType ini = case (iniStoreQueues, iniStoreMessage) of
      ("memory", "memory") -> Right $ ASType SQSMemory SMSMemory
      ("memory", "journal") -> Right $ ASType SQSMemory SMSJournal
#if defined(dbServerPostgres)
      ("database", "journal") -> Right $ ASType SQSPostgres SMSJournal
      ("database", "memory") -> Left "Using PostgreSQL database requires journal memory storage."
#endif
      (q, m) -> Left $ T.unpack $ "Invalid storage settings: store_queues: " <> q <> ", store_messages: " <> m
      where
        iniStoreQueues = fromRight "memory" $ lookupValue "STORE_LOG" "store_queues" ini
        iniStoreMessage = fromRight "memory" $ lookupValue "STORE_LOG" "store_messages" ini
    defaultStaticPath = combine logPath "www"
    enableStoreLog' = settingIsOn "STORE_LOG" "enable"
#if defined(dbServerPostgres)
    enableDbStoreLog' = settingIsOn "STORE_LOG" "db_store_log"
#endif
    initializeServer opts
      | scripted opts = initialize opts
      | otherwise = do
          let InitOptions {ip, fqdn, sourceCode = src', webStaticPath = sp', disableWeb = noWeb'} = opts
          putStrLn "Use `smp-server init -h` for available options."
          checkInitOptions opts
          void $ withPrompt "SMP server will be initialized (press Enter)" getLine
          enableStoreLog <- onOffPrompt "Enable store log to restore queues and messages on server restart" True
          logStats <- onOffPrompt "Enable logging daily statistics" False
          putStrLn "Require a password to create new messaging queues?"
          password <- withPrompt "'r' for random (default), 'n' - no password, or enter password: " serverPassword
          let host = fromMaybe ip fqdn
          host' <- withPrompt ("Enter server FQDN or IP address for certificate (" <> host <> "): ") getLine
          sourceCode' <- withPrompt ("Enter server source code URI (" <> maybe simplexmqSource T.unpack src' <> "): ") getServerSourceCode
          staticPath' <- withPrompt ("Enter path to store generated static site with server information (" <> fromMaybe defaultStaticPath sp' <> "): ") getLine
          initialize
            opts
              { enableStoreLog,
                logStats,
                fqdn = if null host' then fqdn else Just host',
                password,
                sourceCode = (T.pack <$> sourceCode') <|> src' <|> Just (T.pack simplexmqSource),
                webStaticPath = if null staticPath' then sp' else Just staticPath',
                disableWeb = noWeb'
              }
      where
        serverPassword =
          getLine >>= \case
            "" -> pure $ Just SPRandom
            "r" -> pure $ Just SPRandom
            "n" -> pure Nothing
            s ->
              case strDecode $ encodeUtf8 $ T.pack s of
                Right auth -> pure . Just $ ServerPassword auth
                _ -> putStrLn "Invalid password. Only latin letters, digits and symbols other than '@' and ':' are allowed" >> serverPassword
        checkInitOptions InitOptions {sourceCode, serverInfo, operatorCountry, hostingCountry} = do
          let err_
                | isNothing sourceCode && hasServerInfo serverInfo =
                    Just "Error: passing any server information requires passing --source-code"
                | isNothing (operator serverInfo) && isJust operatorCountry =
                    Just "Error: passing --operator-country requires passing --operator"
                | isNothing (hosting serverInfo) && isJust hostingCountry =
                    Just "Error: passing --hosting-country requires passing --hosting"
                | otherwise = Nothing
          forM_ err_ $ \err -> putStrLn err >> exitFailure
        initialize opts'@InitOptions {ip, fqdn, signAlgorithm, password, controlPort, sourceCode} = do
          checkInitOptions opts'
          clearDirIfExists cfgPath
          clearDirIfExists logPath
          createDirectoryIfMissing True cfgPath
          createDirectoryIfMissing True logPath
          let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
          fp <- createServerX509 cfgPath x509cfg
          basicAuth <- mapM createServerPassword password
          controlPortPwds <- forM controlPort $ \_ -> let pwd = decodeLatin1 <$> randomBase64 18 in (,) <$> pwd <*> pwd
          let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
              srv = ProtoServerWithAuth (SMPServer [THDomainName host] "" (C.KeyHash fp)) basicAuth
#if defined(dbServerPostgres)
              dbIniContent = iniDbFileContent opts'
#else
              dbIniContent = ""
#endif
          T.writeFile iniFile $ iniFileContent cfgPath logPath opts' host basicAuth controlPortPwds dbIniContent
          putStrLn $ "Server initialized, please provide additional server information in " <> iniFile <> "."
          putStrLn $ "Run `" <> executableName <> " start` to start server."
          warnCAPrivateKeyFile cfgPath x509cfg
          printServiceInfo serverVersion srv
          printSourceCode sourceCode
          where
            createServerPassword = \case
              ServerPassword s -> pure s
              SPRandom -> BasicAuth <$> randomBase64 32
            randomBase64 n = strEncode <$> (atomically . C.randomBytes n =<< C.newRandom)
            -- iniFileContent host basicAuth controlPortPwds =
            --   informationIniContent opts'
            --     <> "[STORE_LOG]\n\
            --        \# The server uses memory or PostgreSQL database for persisting queue records.\n\
            --        \# Use `enable: on` to use append-only log to preserve and restore queue records on restart.\n\
            --        \# Log is compacted on start (deleted objects are removed).\n"
            --     <> ("enable: " <> onOff enableStoreLog <> "\n\n")
            --     <> "# Queue storage mode: `memory` or `database` (to store queue records in PostgreSQL database).\n\
            --        \# `memory` - in-memory persistence, with optional append-only log (`enable: on`).\n\
            --        \# `database`- PostgreSQL databass (requires `store_messages: journal`).\n\
            --        \store_queues: memory\n\n\
            --        \# Database connection settings for PostgreSQL database (`store_queues: database`).\n"
            --     <> dbOptsIniContent dbOptions
            --     <> "# Write database changes to store log file\n\
            --        \# db_store_log: off\n\n\
            --        \# Time to retain deleted queues in the database, days.\n"
            --     <> ("db_deleted_ttl: " <> tshow defaultDeletedTTL <> "\n\n")
            --     <> "# Message storage mode: `memory` or `journal`.\n\
            --        \store_messages: memory\n\n\
            --        \# When store_messages is `memory`, undelivered messages are optionally saved and restored\n\
            --        \# when the server restarts, they are preserved in the .bak file until the next restart.\n"
            --     <> ("restore_messages: " <> onOff enableStoreLog <> "\n\n")
            --     <> "# Messages and notifications expiration periods.\n"
            --     <> ("expire_messages_days: " <> tshow defMsgExpirationDays <> "\n")
            --     <> "expire_messages_on_start: on\n"
            --     <> ("expire_ntfs_hours: " <> tshow defNtfExpirationHours <> "\n\n")
            --     <> "# Log daily server statistics to CSV file\n"
            --     <> ("log_stats: " <> onOff logStats <> "\n\n")
            --     <> "# Log interval for real-time Prometheus metrics\n\
            --        \# prometheus_interval: 300\n\n\
            --        \[AUTH]\n\
            --        \# Set new_queues option to off to completely prohibit creating new messaging queues.\n\
            --        \# This can be useful when you want to decommission the server, but not all connections are switched yet.\n\
            --        \new_queues: on\n\n\
            --        \# Use create_password option to enable basic auth to create new messaging queues.\n\
            --        \# The password should be used as part of server address in client configuration:\n\
            --        \# smp://fingerprint:password@host1,host2\n\
            --        \# The password will not be shared with the connecting contacts, you must share it only\n\
            --        \# with the users who you want to allow creating messaging queues on your server.\n"
            --     <> ( let noPassword = "password to create new queues and forward messages (any printable ASCII characters without whitespace, '@', ':' and '/')"
            --           in optDisabled basicAuth <> "create_password: " <> maybe noPassword (safeDecodeUtf8 . strEncode) basicAuth
            --        )
            --     <> "\n\n"
            --     <> (optDisabled controlPortPwds <> "control_port_admin_password: " <> maybe "" fst controlPortPwds <> "\n")
            --     <> (optDisabled controlPortPwds <> "control_port_user_password: " <> maybe "" snd controlPortPwds <> "\n")
            --     <> "\n\
            --        \[TRANSPORT]\n\
            --        \# Host is only used to print server address on start.\n\
            --        \# You can specify multiple server ports.\n"
            --     <> ("host: " <> T.pack host <> "\n")
            --     <> ("port: " <> T.pack defaultServerPorts <> "\n")
            --     <> "log_tls_errors: off\n\n\
            --        \# Use `websockets: 443` to run websockets server in addition to plain TLS.\n\
            --        \# This option is deprecated and should be used for testing only.\n\
            --        \# , port 443 should be specified in port above\n\
            --        \websockets: off\n"
            --     <> (optDisabled controlPort <> "control_port: " <> tshow (fromMaybe defaultControlPort controlPort))
            --     <> "\n\n\
            --        \[PROXY]\n\
            --        \# Network configuration for SMP proxy client.\n\
            --        \# `host_mode` can be 'public' (default) or 'onion'.\n\
            --        \# It defines prefferred hostname for destination servers with multiple hostnames.\n\
            --        \# host_mode: public\n\
            --        \# required_host_mode: off\n\n\
            --        \# The domain suffixes of the relays you operate (space-separated) to count as separate proxy statistics.\n"
            --     <> (optDisabled ownDomains <> "own_server_domains: " <> maybe "" (safeDecodeUtf8 . strEncode) ownDomains)
            --     <> "\n\n\
            --        \# SOCKS proxy port for forwarding messages to destination servers.\n\
            --        \# You may need a separate instance of SOCKS proxy for incoming single-hop requests.\n"
            --     <> (optDisabled socksProxy <> "socks_proxy: " <> maybe "localhost:9050" (safeDecodeUtf8 . strEncode) socksProxy)
            --     <> "\n\n\
            --        \# `socks_mode` can be 'onion' for SOCKS proxy to be used for .onion destination hosts only (default)\n\
            --        \# or 'always' to be used for all destination hosts (can be used if it is an .onion server).\n\
            --        \# socks_mode: onion\n\n\
            --        \# Limit number of threads a client can spawn to process proxy commands in parrallel.\n"
            --     <> ("# client_concurrency: " <> tshow defaultProxyClientConcurrency)
            --     <> "\n\n\
            --        \[INACTIVE_CLIENTS]\n\
            --        \# TTL and interval to check inactive clients\n\
            --        \disconnect: on\n"
            --     <> ("ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
            --     <> ("check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration))
            --     <> "\n\n\
            --        \[WEB]\n\
            --        \# Set path to generate static mini-site for server information and qr codes/links\n"
            --     <> ("static_path: " <> T.pack (fromMaybe defaultStaticPath webStaticPath) <> "\n\n")
            --     <> "# Run an embedded server on this port\n\
            --        \# Onion sites can use any port and register it in the hidden service config.\n\
            --        \# Running on a port 80 may require setting process capabilities.\n\
            --        \# http: 8000\n\n\
            --        \# You can run an embedded TLS web server too if you provide port and cert and key files.\n\
            --        \# Not required for running relay on onion address.\n"
            --     <> (webDisabled <> "https: 443\n")
            --     <> (webDisabled <> "cert: " <> T.pack httpsCertFile <> "\n")
            --     <> (webDisabled <> "key: " <> T.pack httpsKeyFile <> "\n")
            --   where
            --     webDisabled = if disableWeb then "# " else ""
    runServer startOptions ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@ServerConfig {information, serverStoreCfg, newQueueBasicAuth, messageExpiration, inactiveClientExpiration} = serverConfig
          sourceCode' = (\ServerPublicInfo {sourceCode} -> sourceCode) <$> information
          srv = ProtoServerWithAuth (SMPServer [THDomainName host] (if port == "5223" then "" else port) (C.KeyHash fp)) newQueueBasicAuth
      printServiceInfo serverVersion srv
      printSourceCode sourceCode'
      printSMPServerConfig transports serverStoreCfg
      checkMsgStoreMode ini iniStoreType
      putStrLn $ case messageExpiration of
        Just ExpirationConfig {ttl} -> "expiring messages after " <> showTTL ttl
        _ -> "not expiring messages"
      putStrLn $ case inactiveClientExpiration of
        Just ExpirationConfig {ttl, checkInterval} -> "expiring clients inactive for " <> show ttl <> " seconds every " <> show checkInterval <> " seconds"
        _ -> "not expiring inactive clients"
      putStrLn $
        "creating new queues "
          <> if allowNewQueues cfg
            then maybe "allowed" (const "requires password") newQueueBasicAuth
            else "NOT allowed"
      -- print information
      let persistence = case serverStoreCfg of
            ASSCfg _ _ (SSCMemory Nothing) -> SPMMemoryOnly
            ASSCfg _ _ (SSCMemory (Just StorePaths {storeMsgsFile})) | isNothing storeMsgsFile -> SPMQueues
            _ -> SPMMessages
      let config =
            ServerPublicConfig
              { persistence,
                messageExpiration = ttl <$> messageExpiration,
                statsEnabled = isJust logStats,
                newQueuesAllowed = allowNewQueues cfg,
                basicAuthEnabled = isJust newQueueBasicAuth
              }
      case webStaticPath' of
        Just path | sharedHTTP -> do
          runWebServer path Nothing ServerInformation {config, information}
          attachStaticFiles path $ \attachHTTP -> do
            logDebug "Allocated web server resources"
            runSMPServer cfg (Just attachHTTP) `finally` logDebug "Releasing web server resources..."
        Just path -> do
          runWebServer path webHttpsParams' ServerInformation {config, information}
          runSMPServer cfg Nothing
        Nothing -> do
          logWarn "No server static path set"
          runSMPServer cfg Nothing
      logDebug "Bye"
      where
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        restoreMessagesFile path = case iniOnOff "STORE_LOG" "restore_messages" ini of
          Just True -> Just path
          Just False -> Nothing
          -- if the setting is not set, it is enabled when store log is enabled
          _ -> enableStoreLog' ini $> path
        transports = iniTransports ini
        sharedHTTP = any (\(_, _, addHTTP) -> addHTTP) transports
        iniStoreType = either error id $! readStoreType ini
        serverConfig =
          ServerConfig
            { transports,
              smpHandshakeTimeout = 120000000,
              tbqSize = 128,
              msgQueueQuota = defaultMsgQueueQuota,
              maxJournalMsgCount = defaultMaxJournalMsgCount,
              maxJournalStateLines = defaultMaxJournalStateLines,
              queueIdBytes = 24,
              msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
              smpCredentials =
                ServerCredentials
                  { caCertificateFile = Just $ c caCrtFile,
                    privateKeyFile = c serverKeyFile,
                    certificateFile = c serverCrtFile
                  },
              httpCredentials = (\WebHttpsParams {key, cert} -> ServerCredentials {caCertificateFile = Nothing, privateKeyFile = key, certificateFile = cert}) <$> webHttpsParams',
              serverStoreCfg = case iniStoreType of
                ASType SQSMemory SMSMemory ->
                  ASSCfg SQSMemory SMSMemory $ SSCMemory $ enableStoreLog' ini $> StorePaths {storeLogFile = storeLogFilePath, storeMsgsFile = restoreMessagesFile storeMsgsFilePath}
                ASType SQSMemory SMSJournal ->
                  ASSCfg SQSMemory SMSJournal $ SSCMemoryJournal {storeLogFile = storeLogFilePath, storeMsgsPath = storeMsgsJournalDir}
#if defined(dbServerPostgres)
                ASType SQSPostgres SMSJournal ->
                  let dbStoreLogPath = enableDbStoreLog' ini $> storeLogFilePath
                      storeCfg = PostgresStoreCfg {dbOpts = iniDBOptions ini, dbStoreLogPath, confirmMigrations = MCYesUp, deletedTTL = iniDeletedTTL ini}
                   in ASSCfg SQSPostgres SMSJournal $ SSCDatabaseJournal {storeCfg, storeMsgsPath' = storeMsgsJournalDir}
#endif
              , storeNtfsFile = restoreMessagesFile storeNtfsFilePath,
              -- allow creating new queues by default
              allowNewQueues = fromMaybe True $ iniOnOff "AUTH" "new_queues" ini,
              newQueueBasicAuth = either error id <$!> strDecodeIni "AUTH" "create_password" ini,
              controlPortAdminAuth = either error id <$!> strDecodeIni "AUTH" "control_port_admin_password" ini,
              controlPortUserAuth = either error id <$!> strDecodeIni "AUTH" "control_port_user_password" ini,
              messageExpiration =
                Just
                  defaultMessageExpiration
                    { ttl = 86400 * readIniDefault defMsgExpirationDays "STORE_LOG" "expire_messages_days" ini
                    },
              expireMessagesOnStart = fromMaybe True $ iniOnOff "STORE_LOG" "expire_messages_on_start" ini,
              idleQueueInterval = defaultIdleQueueInterval,
              notificationExpiration =
                defaultNtfExpiration
                  { ttl = 3600 * readIniDefault defNtfExpirationHours "STORE_LOG" "expire_ntfs_hours" ini
                  },
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
              prometheusInterval = eitherToMaybe $ read . T.unpack <$> lookupValue "STORE_LOG" "prometheus_interval" ini,
              prometheusMetricsFile = combine logPath "smp-server-metrics.txt",
              pendingENDInterval = 15000000, -- 15 seconds
              ntfDeliveryInterval = 3000000, -- 3 seconds
              smpServerVRange = supportedServerSMPRelayVRange,
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini
                  },
              controlPort = eitherToMaybe $ T.unpack <$> lookupValue "TRANSPORT" "control_port" ini,
              smpAgentCfg =
                defaultSMPClientAgentConfig
                  { smpCfg =
                      (smpCfg defaultSMPClientAgentConfig)
                        { serverVRange = supportedProxyClientSMPRelayVRange,
                          agreeSecret = True,
                          proxyServer = True,
                          networkConfig =
                            defaultNetworkConfig
                              { socksProxy = either error id <$!> strDecodeIni "PROXY" "socks_proxy" ini,
                                socksMode = maybe SMOnion (either error id) $! strDecodeIni "PROXY" "socks_mode" ini,
                                hostMode = either (const HMPublic) (either error id . textToHostMode) $ lookupValue "PROXY" "host_mode" ini,
                                requiredHostMode = fromMaybe False $ iniOnOff "PROXY" "required_host_mode" ini
                              }
                        },
                    ownServerDomains = either (const []) textToOwnServers $ lookupValue "PROXY" "own_server_domains" ini,
                    persistErrorInterval = 30 -- seconds
                  },
              allowSMPProxy = True,
              serverClientConcurrency = readIniDefault defaultProxyClientConcurrency "PROXY" "client_concurrency" ini,
              information = serverPublicInfo ini,
              startOptions
            }
        textToOwnServers :: Text -> [ByteString]
        textToOwnServers = map encodeUtf8 . T.words
        runWebServer webStaticPath webHttpsParams si = do
          let onionHost =
                either (const Nothing) (find isOnion) $
                  strDecode @(L.NonEmpty TransportHost) . encodeUtf8 =<< lookupValue "TRANSPORT" "host" ini
              webHttpPort = eitherToMaybe $ read . T.unpack <$> lookupValue "WEB" "http" ini
          generateSite si onionHost webStaticPath
          when (isJust webHttpPort || isJust webHttpsParams) $
            serveStaticFiles EmbeddedWebParams {webStaticPath, webHttpPort, webHttpsParams}
          where
            isOnion = \case THOnionHost _ -> True; _ -> False
        webHttpsParams' =
          eitherToMaybe $ do
            port <- read . T.unpack <$> lookupValue "WEB" "https" ini
            cert <- T.unpack <$> lookupValue "WEB" "cert" ini
            key <- T.unpack <$> lookupValue "WEB" "key" ini
            pure WebHttpsParams {port, cert, key}
        webStaticPath' = eitherToMaybe $ T.unpack <$> lookupValue "WEB" "static_path" ini

    checkMsgStoreMode :: Ini -> AStoreType -> IO ()
    checkMsgStoreMode ini mode = do
      msgsDirExists <- doesDirectoryExist storeMsgsJournalDir
      msgsFileExists <- doesFileExist storeMsgsFilePath
      storeLogExists <- doesFileExist storeLogFilePath
      case mode of
        ASType qs SMSJournal
          | msgsFileExists && msgsDirExists -> exitConfigureMsgStorage
          | msgsFileExists -> do
              putStrLn $ "Error: store_messages is `journal` with " <> storeMsgsFilePath <> " file present."
              putStrLn "Set store_messages to `memory` or use `smp-server journal export` to migrate."
              exitFailure
          | not msgsDirExists ->
              putStrLn $ "store_messages is `journal`, " <> storeMsgsJournalDir <> " directory will be created."
          | otherwise -> case qs of
              SQSMemory ->
                unless (storeLogExists) $ putStrLn $ "store_queues is `memory`, " <> storeLogFilePath <> " file will be created."
#if defined(dbServerPostgres)
              SQSPostgres -> do
                let DBOpts {connstr, schema} = iniDBOptions ini
                schemaExists <- checkSchemaExists connstr schema
                case enableDbStoreLog' ini of
                  Just ()
                    | not schemaExists -> noDatabaseSchema connstr schema
                    | not storeLogExists -> do
                        putStrLn $ "Error: db_store_log is `on`, " <> storeLogFilePath <> " does not exist"
                        exitFailure
                    | otherwise -> pure ()
                  Nothing
                    | storeLogExists && schemaExists -> exitConfigureQueueStore storeLogFilePath connstr schema
                    | storeLogExists -> do
                        putStrLn $ "Error: store_queues is `database` with " <> storeLogFilePath <> " file present."
                        putStrLn "Set store_queues to `memory` or use `smp-server database import` to migrate."
                        exitFailure
                    | not schemaExists -> noDatabaseSchema connstr schema
                    | otherwise -> pure ()
                where
                  noDatabaseSchema connstr schema = do
                    putStrLn $ "Error: store_queues is `database`, create schema " <> B.unpack schema <> " in PostgreSQL database " <> B.unpack connstr
                    exitFailure
#endif
        ASType SQSMemory SMSMemory
          | msgsFileExists && msgsDirExists -> exitConfigureMsgStorage
          | msgsDirExists -> do
              putStrLn $ "Error: store_messages is `memory` with " <> storeMsgsJournalDir <> " directory present."
              putStrLn "Set store_messages to `journal` or use `smp-server journal import` to migrate."
              exitFailure
          | otherwise -> pure ()

    exitConfigureMsgStorage = do
      putStrLn $ "Error: both " <> storeMsgsFilePath <> " file and " <> storeMsgsJournalDir <> " directory are present."
      putStrLn "Configure memory storage."
      exitFailure

data EmbeddedWebParams = EmbeddedWebParams
  { webStaticPath :: FilePath,
    webHttpPort :: Maybe Int,
    webHttpsParams :: Maybe WebHttpsParams
  }

data WebHttpsParams = WebHttpsParams
  { port :: Int,
    cert :: FilePath,
    key :: FilePath
  }

getServerSourceCode :: IO (Maybe String)
getServerSourceCode =
  getLine >>= \case
    "" -> pure Nothing
    s | "https://" `isPrefixOf` s || "http://" `isPrefixOf` s -> pure $ Just s
    _ -> putStrLn "Invalid source code. URI should start from http:// or https://" >> getServerSourceCode

simplexmqSource :: String
simplexmqSource = "https://github.com/simplex-chat/simplexmq"

serverPublicInfo :: Ini -> Maybe ServerPublicInfo
serverPublicInfo ini = serverInfo <$!> infoValue "source_code"
  where
    serverInfo sourceCode =
      ServerPublicInfo
        { sourceCode,
          usageConditions =
            (\conditions -> ServerConditions {conditions, amendments = infoValue "condition_amendments"})
              <$!> infoValue "usage_conditions",
          serverCountry = countryValue "server_country",
          operator = iniEntity "operator" "operator_country",
          website = infoValue "website",
          adminContacts = iniContacts "admin_simplex" "admin_email" "admin_pgp" "admin_pgp_fingerprint",
          complaintsContacts = iniContacts "complaints_simplex" "complaints_email" "complaints_pgp" "complaints_pgp_fingerprint",
          hosting = iniEntity "hosting" "hosting_country",
          hostingType = either error id <$!> strDecodeIni "INFORMATION" "hosting_type" ini
        }
    infoValue name = eitherToMaybe $ lookupValue "INFORMATION" name ini
    iniEntity nameField countryField =
      (\name -> Entity {name, country = countryValue countryField})
        <$!> infoValue nameField
    countryValue field = (either error id . validCountryValue (T.unpack field) . T.unpack) <$!> infoValue field
    iniContacts simplexField emailField pgpKeyUriField pgpKeyFingerprintField =
      let simplex = either error id . parseAll (connReqUriP' Nothing) . encodeUtf8 <$!> eitherToMaybe (lookupValue "INFORMATION" simplexField ini)
          email = infoValue emailField
          pkURI_ = infoValue pgpKeyUriField
          pkFingerprint_ = infoValue pgpKeyFingerprintField
       in case (simplex, email, pkURI_, pkFingerprint_) of
            (Nothing, Nothing, Nothing, _) -> Nothing
            (Nothing, Nothing, _, Nothing) -> Nothing
            (_, _, pkURI, pkFingerprint) -> Just ServerContactAddress {simplex, email, pgp = PGPKey <$> pkURI <*> pkFingerprint}

validCountryValue :: String -> String -> Either String Text
validCountryValue field s
  | length s == 2 && all (\c -> isAscii c && isAlpha c) s = Right $ T.pack $ map toUpper s
  | otherwise = Left $ "Use ISO3166 2-letter code for " <> field

printSourceCode :: Maybe Text -> IO ()
printSourceCode = \case
  Just sourceCode -> T.putStrLn $ "Server source code: " <> sourceCode
  Nothing -> do
    putStrLn "Warning: server source code is not specified."
    putStrLn "Add 'source_code' property to [INFORMATION] section of INI file."

printSMPServerConfig :: [(ServiceName, ATransport, AddHTTP)] -> AServerStoreCfg -> IO ()
printSMPServerConfig transports (ASSCfg _ _ cfg) = case cfg of
  SSCMemory sp_ -> printServerConfig transports $ (\StorePaths {storeLogFile} -> storeLogFile) <$> sp_
  SSCMemoryJournal {storeLogFile} -> printServerConfig transports $ Just storeLogFile
#if defined(dbServerPostgres)
  SSCDatabaseJournal {storeCfg = PostgresStoreCfg {dbOpts = DBOpts {connstr, schema}}} -> do
    B.putStrLn $ "PostgreSQL database: " <> connstr <> ", schema: " <> schema
    printServerTransports transports
#endif

data CliCommand
  = Init InitOptions
  | OnlineCert CertOptions
  | Start StartOptions
  | Delete
  | Journal StoreCmd
#if defined(dbServerPostgres)
  | Database StoreCmd DBOpts
#endif

data StoreCmd = SCImport | SCExport | SCDelete

cliCommandP :: FilePath -> FilePath -> FilePath -> Parser CliCommand
cliCommandP cfgPath logPath iniFile =
  hsubparser
    ( command "init" (info (Init <$> initP) (progDesc $ "Initialize server - creates " <> cfgPath <> " and " <> logPath <> " directories and configuration files"))
        <> command "cert" (info (OnlineCert <$> certOptionsP) (progDesc $ "Generate new online TLS server credentials (configuration: " <> iniFile <> ")"))
        <> command "start" (info (Start <$> startOptionsP) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
        <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
        <> command "journal" (info (Journal <$> journalCmdP) (progDesc "Import/export messages to/from journal storage"))
#if defined(dbServerPostgres)
        <> command "database" (info (Database <$> databaseCmdP <*> dbOptsP) (progDesc "Import/export queues to/from PostgreSQL database storage"))
#endif
    )
  where
    initP :: Parser InitOptions
    initP = do
      enableStoreLog <-
        switch
          ( long "store-log"
              <> short 'l'
              <> help "Enable store log for persistence"
          )
#if defined(dbServerPostgres)
      dbOptions <- dbOptsP
#endif
      logStats <-
        switch
          ( long "daily-stats"
              <> short 's'
              <> help "Enable logging daily server statistics"
          )
      signAlgorithm <-
        option
          (maybeReader readMaybe)
          ( long "sign-algorithm"
              <> short 'a'
              <> help "Signature algorithm used for TLS certificates: ED25519, ED448"
              <> value ED25519
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
              <> metavar "FQDN"
          )
      password <-
        flag' Nothing (long "no-password" <> help "Allow creating new queues without password")
          <|> Just
            <$> option
              parseBasicAuth
              ( long "password"
                  <> metavar "PASSWORD"
                  <> help "Set password to create new messaging queues"
                  <> value SPRandom
              )
      controlPort <-
        flag' (Just defaultControlPort) (long "control-port" <> help ("Enable control port on " <> show defaultControlPort))
          <|> option strParse (long "control-port" <> help "Enable control port" <> metavar "PORT" <> value Nothing)
      socksProxy <-
        flag' (Just defaultSocksProxy) (long "socks-proxy" <> help "Outgoing SOCKS proxy on port 9050")
          <|> option
            strParse
            ( long "socks-proxy"
                <> metavar "PROXY"
                <> help "Outgoing SOCKS proxy to forward messages to onion-only servers"
                <> value Nothing
            )
      ownDomains :: Maybe (L.NonEmpty TransportHost) <-
        option
          strParse
          ( long "own-domains"
              <> metavar "DOMAINS"
              <> help "Own server domain names (comma-separated)"
              <> value Nothing
          )
      sourceCode <-
        flag' (Just simplexmqSource) (long "source-code" <> help ("Server source code (default: " <> simplexmqSource <> ")"))
          <|> (optional . strOption) (long "source-code" <> metavar "URI" <> help "Server source code")
      operator_ <- entityP "operator" "OPERATOR" "Server operator"
      hosting_ <- entityP "hosting" "HOSTING" "Hosting provider"
      hostingType <-
        option
          strParse
          ( long "hosting-type"
              <> metavar "HOSTING_TYPE"
              <> help "Hosting type: virtual, dedicated, colocation, owned"
              <> value Nothing
          )
      serverCountry <- countryP "server" "SERVER" "Server datacenter"
      website <-
        (optional . strOption)
          ( long "operator-website"
              <> help "Operator public website"
              <> metavar "WEBSITE"
          )
      webStaticPath <-
        (optional . strOption)
          ( long "web-path"
              <> help "Directory to store generated static site with server information"
              <> metavar "PATH"
          )
      disableWeb <-
        switch
          ( long "disable-web"
              <> help "Disable starting static web server with server information"
          )
      scripted <-
        switch
          ( long "yes"
              <> short 'y'
              <> help "Non-interactive initialization using command-line options"
          )
      pure
        InitOptions
          { enableStoreLog,
#if defined(dbServerPostgres)
            dbOptions,
#endif
            logStats,
            signAlgorithm,
            ip,
            fqdn,
            password,
            controlPort,
            socksProxy,
            ownDomains,
            sourceCode = T.pack <$> sourceCode,
            serverInfo =
              ServerPublicInfo
                { sourceCode = T.pack simplexmqSource,
                  usageConditions = Nothing,
                  operator = fst operator_,
                  website,
                  adminContacts = Nothing,
                  complaintsContacts = Nothing,
                  hosting = fst hosting_,
                  hostingType,
                  serverCountry
                },
            operatorCountry = snd operator_,
            hostingCountry = snd hosting_,
            webStaticPath,
            disableWeb,
            scripted
          }
    startOptionsP = do
      maintenance <-
        switch
          ( long "maintenance"
              <> help "Do not start the server, only perform start and stop tasks"
          )
      skipWarnings <-
        switch
          ( long "skip-warnings"
              <> help "Start the server with non-critical start warnings"
          )
      confirmMigrations <-
        option
          parseConfirmMigrations
          ( long "confirm-migrations"
              <> metavar "CONFIRM_MIGRATIONS"
              <> help "Confirm PostgreSQL database migration: up, down (default is manual confirmation)"
              <> value MCConsole
          )
      pure StartOptions {maintenance, skipWarnings, confirmMigrations}
    journalCmdP = storeCmdP "message log file" "journal storage"
#if defined(dbServerPostgres)
    databaseCmdP = storeCmdP "queue store log file" "PostgreSQL database schema"
#endif
    storeCmdP src dest =
      hsubparser
        ( command "import" (info (pure SCImport) (progDesc $ "Import " <> src <> " into a new " <> dest))
            <> command "export" (info (pure SCExport) (progDesc $ "Export " <> dest <> " to " <> src))
            <> command "delete" (info (pure SCDelete) (progDesc $ "Delete " <> dest))
        )
    parseConfirmMigrations :: ReadM MigrationConfirmation
    parseConfirmMigrations = eitherReader $ \case
      "up" -> Right MCYesUp
      "down" -> Right MCYesUpDown
      _ -> Left "invalid migration confirmation, pass 'up' or 'down'"
    parseBasicAuth :: ReadM ServerPassword
    parseBasicAuth = eitherReader $ fmap ServerPassword . strDecode . B.pack
    entityP :: String -> String -> String -> Parser (Maybe Entity, Maybe Text)
    entityP opt' metavar' help' = do
      name_ <-
        (optional . strOption)
          ( long opt'
              <> metavar (metavar' <> "_NAME")
              <> help (help' <> " name")
          )
      country <- countryP opt' metavar' help'
      pure ((\name -> Entity {name, country}) <$> name_, country)
    countryP :: String -> String -> String -> Parser (Maybe Text)
    countryP opt' metavar' help' =
      (optional . option (eitherReader $ validCountryValue opt'))
        ( long (opt' <> "-country")
            <> metavar (metavar' <> "_COUNTRY")
            <> help (help' <> " country")
        )
    strParse :: StrEncoding a => ReadM a
    strParse = eitherReader $ parseAll strP . encodeUtf8 . T.pack
