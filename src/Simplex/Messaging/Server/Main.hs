{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Server.Main where

import Control.Concurrent.STM
import Control.Logger.Simple
import Control.Monad (void, when, (<$!>))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlpha, isAscii, toUpper)
import Data.Functor (($>))
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.List (find, isPrefixOf)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as T
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Agent.Protocol (connReqUriP')
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SocksMode (..), defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (BasicAuth (..), ProtoServerWithAuth (ProtoServerWithAuth), pattern SMPServer)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defMsgExpirationDays, defaultInactiveClientExpiration, defaultMessageExpiration, defaultProxyClientConcurrency)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Transport (batchCmdsSMPVersion, sendingProxySMPVersion, simplexMQVersion, supportedSMPHandshakes, supportedServerSMPRelayVRange)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (eitherToMaybe, safeDecodeUtf8, tshow)
import Simplex.Messaging.Version (mkVersionRange)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (combine)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

smpServerCLI :: FilePath -> FilePath -> IO ()
smpServerCLI = smpServerCLI_ (\_ _ _ -> pure ()) (\_ -> pure ())

smpServerCLI_ :: (ServerInformation -> Maybe TransportHost -> FilePath -> IO ()) -> (EmbeddedWebParams -> IO ()) -> FilePath -> FilePath -> IO ()
smpServerCLI_ generateSite serveStaticFiles cfgPath logPath =
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
    dataLogFilePath = combine logPath "smp-server-data.log"
    httpsCertFile = combine cfgPath "web.cert"
    httpsKeyFile = combine cfgPath "web.key"
    defaultStaticPath = combine logPath "www"
    initializeServer opts@InitOptions {ip, fqdn, sourceCode = src', webStaticPath = sp', disableWeb = noWeb', scripted}
      | scripted = initialize opts
      | otherwise = do
          putStrLn "Use `smp-server init -h` for available options."
          void $ withPrompt "SMP server will be initialized (press Enter)" getLine
          enableStoreLog <- onOffPrompt "Enable store log to restore queues and messages on server restart" True
          logStats <- onOffPrompt "Enable logging daily statistics" False
          putStrLn "Require a password to create new messaging queues?"
          password <- withPrompt "'r' for random (default), 'n' - no password, or enter password: " serverPassword
          let host = fromMaybe ip fqdn
          host' <- withPrompt ("Enter server FQDN or IP address for certificate (" <> host <> "): ") getLine
          sourceCode' <- withPrompt ("Enter server source code URI (" <> maybe simplexmqSource T.unpack src' <> "): ") getServerSourceCode
          staticPath' <- withPrompt ("Enter path to store generated static site with server information (" <> fromMaybe defaultStaticPath sp' <> "): ") getLine
          enableWeb <- onOffPrompt "Enable built-in web server for static site" (not noWeb')
          initialize
            opts
              { enableStoreLog,
                logStats,
                fqdn = if null host' then fqdn else Just host',
                password,
                sourceCode = (T.pack <$> sourceCode') <|> src',
                webStaticPath = if null staticPath' then sp' else Just staticPath',
                disableWeb = not enableWeb
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
        initialize InitOptions {enableStoreLog, logStats, signAlgorithm, password, sourceCode, webStaticPath, disableWeb} = do
          clearDirIfExists cfgPath
          clearDirIfExists logPath
          createDirectoryIfMissing True cfgPath
          createDirectoryIfMissing True logPath
          let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
          fp <- createServerX509 cfgPath x509cfg
          basicAuth <- mapM createServerPassword password
          let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
              srv = ProtoServerWithAuth (SMPServer [THDomainName host] "" (C.KeyHash fp)) basicAuth
          T.writeFile iniFile $ iniFileContent host basicAuth $ Just "https://github.com/simplex-chat/simplexmq"
          putStrLn $ "Server initialized, please provide additional server information in " <> iniFile <> "."
          putStrLn $ "Run `" <> executableName <> " start` to start server."
          warnCAPrivateKeyFile cfgPath x509cfg
          printServiceInfo serverVersion srv
          printSourceCode sourceCode
          where
            createServerPassword = \case
              ServerPassword s -> pure s
              SPRandom -> BasicAuth . strEncode <$> (atomically . C.randomBytes 32 =<< C.newRandom)
            iniFileContent host basicAuth sourceCode' =
              informationIniContent sourceCode'
                <> "[STORE_LOG]\n\
                   \# The server uses STM memory for persistence,\n\
                   \# that will be lost on restart (e.g., as with redis).\n\
                   \# This option enables saving memory to append only log,\n\
                   \# and restoring it when the server is started.\n\
                   \# Log is compacted on start (deleted objects are removed).\n"
                <> ("enable: " <> onOff enableStoreLog <> "\n\n")
                <> "# Undelivered messages are optionally saved and restored when the server restarts,\n\
                   \# they are preserved in the .bak file until the next restart.\n"
                <> ("restore_messages: " <> onOff enableStoreLog <> "\n")
                <> ("expire_messages_days: " <> tshow defMsgExpirationDays <> "\n\n")
                <> "# Log daily server statistics to CSV file\n"
                <> ("log_stats: " <> onOff logStats <> "\n\n")
                <> "[AUTH]\n\
                   \# Set new_queues option to off to completely prohibit creating new messaging queues.\n\
                   \# This can be useful when you want to decommission the server, but not all connections are switched yet.\n\
                   \new_queues: on\n\n\
                   \# Use create_password option to enable basic auth to create new messaging queues.\n\
                   \# The password should be used as part of server address in client configuration:\n\
                   \# smp://fingerprint:password@host1,host2\n\
                   \# The password will not be shared with the connecting contacts, you must share it only\n\
                   \# with the users who you want to allow creating messaging queues on your server.\n"
                <> ( case basicAuth of
                      Just auth -> "create_password: " <> safeDecodeUtf8 (strEncode auth)
                      _ -> "# create_password: password to create new queues (any printable ASCII characters without whitespace, '@', ':' and '/')"
                   )
                <> "\n\n\
                   \# control_port_admin_password:\n\
                   \# control_port_user_password:\n\n\
                   \[TRANSPORT]\n\
                   \# host is only used to print server address on start\n"
                <> ("host: " <> T.pack host <> "\n")
                <> ("port: " <> T.pack defaultServerPort <> "\n")
                <> "log_tls_errors: off\n\
                   \websockets: off\n\
                   \# control_port: 5224\n\n\
                   \[PROXY]\n\
                   \# Network configuration for SMP proxy client.\n\
                   \# `host_mode` can be 'public' (default) or 'onion'.\n\
                   \# It defines prefferred hostname for destination servers with multiple hostnames.\n\
                   \# host_mode: public\n\
                   \# required_host_mode: off\n\n\
                   \# The domain suffixes of the relays you operate (space-separated) to count as separate proxy statistics.\n\
                   \# own_server_domains: \n\n\
                   \# SOCKS proxy port for forwarding messages to destination servers.\n\
                   \# You may need a separate instance of SOCKS proxy for incoming single-hop requests.\n\
                   \# socks_proxy: localhost:9050\n\n\
                   \# `socks_mode` can be 'onion' for SOCKS proxy to be used for .onion destination hosts only (default)\n\
                   \# or 'always' to be used for all destination hosts (can be used if it is an .onion server).\n\
                   \# socks_mode: onion\n\n\
                   \# Limit number of threads a client can spawn to process proxy commands in parrallel.\n"
                <> ("# client_concurrency: " <> tshow defaultProxyClientConcurrency <> "\n\n")
                <> "[INACTIVE_CLIENTS]\n\
                   \# TTL and interval to check inactive clients\n\
                   \disconnect: off\n"
                <> ("# ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
                <> ("# check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration) <> "\n")
                <> "\n\n\
                   \[WEB]\n\
                   \# Set path to generate static mini-site for server information and qr codes/links\n"
                <> ("static_path: " <> T.pack (fromMaybe defaultStaticPath webStaticPath) <> "\n\n")
                <> "# Run an embedded server on this port\n\
                   \# Onion sites can use any port and register it in the hidden service config.\n\
                   \# Running on a port 80 may require setting process capabilities.\n"
                <> ((if disableWeb then "# " else "") <> "http: 8000\n\n")
                <> "# You can run an embedded TLS web server too if you provide port and cert and key files.\n\
                   \# Not required for running relay on onion address.\n\
                   \# https: 443\n"
                <> ("# cert: " <> T.pack httpsCertFile <> "\n")
                <> ("# key: " <> T.pack httpsKeyFile <> "\n")
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@ServerConfig {information, transports, storeLogFile, newQueueBasicAuth, messageExpiration, inactiveClientExpiration} = serverConfig
          sourceCode' = (\ServerPublicInfo {sourceCode} -> sourceCode) <$> information
          srv = ProtoServerWithAuth (SMPServer [THDomainName host] (if port == "5223" then "" else port) (C.KeyHash fp)) newQueueBasicAuth
      printServiceInfo serverVersion srv
      printSourceCode sourceCode'
      printServerConfig transports storeLogFile
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
      let persistence
            | isNothing storeLogFile = SPMMemoryOnly
            | isJust (storeMsgsFile cfg) = SPMMessages
            | otherwise = SPMQueues
      let config =
            ServerPublicConfig
              { persistence,
                messageExpiration = ttl <$> messageExpiration,
                statsEnabled = isJust logStats,
                newQueuesAllowed = allowNewQueues cfg,
                basicAuthEnabled = isJust newQueueBasicAuth
              }
      runWebServer ini ServerInformation {config, information}
      runSMPServer cfg
      where
        enableStoreLog = settingIsOn "STORE_LOG" "enable" ini
        logStats = settingIsOn "STORE_LOG" "log_stats" ini
        c = combine cfgPath . ($ defaultX509Config)
        serverConfig =
          ServerConfig
            { transports = iniTransports ini,
              smpHandshakeTimeout = 120000000,
              tbqSize = 64,
              msgQueueQuota = 128,
              queueIdBytes = 24,
              msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
              caCertificateFile = c caCrtFile,
              privateKeyFile = c serverKeyFile,
              certificateFile = c serverCrtFile,
              storeLogFile = enableStoreLog $> storeLogFilePath,
              dataLogFile = enableStoreLog $> dataLogFilePath,
              storeMsgsFile =
                let messagesPath = combine logPath "smp-server-messages.log"
                 in case iniOnOff "STORE_LOG" "restore_messages" ini of
                      Just True -> Just messagesPath
                      Just False -> Nothing
                      -- if the setting is not set, it is enabled when store log is enabled
                      _ -> enableStoreLog $> messagesPath,
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
              pendingENDInterval = 15000000, -- 15 seconds
              smpServerVRange = supportedServerSMPRelayVRange,
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini,
                    alpn = Just supportedSMPHandshakes
                  },
              controlPort = eitherToMaybe $ T.unpack <$> lookupValue "TRANSPORT" "control_port" ini,
              smpAgentCfg =
                defaultSMPClientAgentConfig
                  { smpCfg =
                      (smpCfg defaultSMPClientAgentConfig)
                        { serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion,
                          agreeSecret = True,
                          networkConfig =
                            defaultNetworkConfig
                              { socksProxy = either error id <$!> strDecodeIni "PROXY" "socks_proxy" ini,
                                socksMode = maybe SMOnion (either error id) $! strDecodeIni "PROXY" "socks_mode" ini,
                                hostMode = either (const HMPublic) textToHostMode $ lookupValue "PROXY" "host_mode" ini,
                                requiredHostMode = fromMaybe False $ iniOnOff "PROXY" "required_host_mode" ini
                              }
                        },
                    ownServerDomains = either (const []) textToOwnServers $ lookupValue "PROXY" "own_server_domains" ini,
                    persistErrorInterval = 30 -- seconds
                  },
              allowSMPProxy = True,
              serverClientConcurrency = readIniDefault defaultProxyClientConcurrency "PROXY" "client_concurrency" ini,
              information = serverPublicInfo ini
            }
        textToHostMode :: Text -> HostMode
        textToHostMode = \case
          "public" -> HMPublic
          "onion" -> HMOnionViaSocks
          s -> error . T.unpack $ "Invalid host_mode: " <> s
        textToOwnServers :: Text -> [ByteString]
        textToOwnServers = map encodeUtf8 . T.words

    runWebServer ini si =
      case eitherToMaybe $ T.unpack <$> lookupValue "WEB" "static_path" ini of
        Nothing -> logWarn "No server static path set"
        Just webStaticPath -> do
          let onionHost =
                either (const Nothing) (find isOnion) $
                  strDecode @(L.NonEmpty TransportHost) . encodeUtf8 =<< lookupValue "TRANSPORT" "host" ini
              webHttpPort = eitherToMaybe $ read . T.unpack <$> lookupValue "WEB" "http" ini
              webHttpsParams =
                eitherToMaybe $ do
                  port <- read . T.unpack <$> lookupValue "WEB" "https" ini
                  cert <- T.unpack <$> lookupValue "WEB" "cert" ini
                  key <- T.unpack <$> lookupValue "WEB" "key" ini
                  pure WebHttpsParams {port, cert, key}
          generateSite si onionHost webStaticPath
          when (isJust webHttpPort || isJust webHttpsParams) $
            serveStaticFiles EmbeddedWebParams {webStaticPath, webHttpPort, webHttpsParams}
          where
            isOnion = \case THOnionHost _ -> True; _ -> False

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

informationIniContent :: Maybe Text -> Text
informationIniContent sourceCode_ =
  "[INFORMATION]\n\
  \# AGPLv3 license requires that you make any source code modifications\n\
  \# available to the end users of the server.\n\
  \# LICENSE: https://github.com/simplex-chat/simplexmq/blob/stable/LICENSE\n\
  \# Include correct source code URI in case the server source code is modified in any way.\n\
  \# If any other information fields are present, source code property also MUST be present.\n\n"
    <> (maybe "# source_code: URI" ("source_code: " <>) sourceCode_ <> "\n\n")
    <> "# Declaring all below information is optional, any of these fields can be omitted.\n\
       \\n\
       \# Server usage conditions and amendments.\n\
       \# It is recommended to use standard conditions with any amendments in a separate document.\n\
       \# usage_conditions: https://github.com/simplex-chat/simplex-chat/blob/stable/PRIVACY.md\n\
       \# condition_amendments: link\n\
       \\n\
       \# Server location and operator.\n\
       \# server_country: ISO-3166 2-letter code\n\
       \# operator: entity (organization or person name)\n\
       \# operator_country: ISO-3166 2-letter code\n\
       \# website:\n\
       \\n\
       \# Administrative contacts.\n\
       \# admin_simplex: SimpleX address\n\
       \# admin_email:\n\
       \# admin_pgp:\n\
       \# admin_pgp_fingerprint:\n\
       \\n\
       \# Contacts for complaints and feedback.\n\
       \# complaints_simplex: SimpleX address\n\
       \# complaints_email:\n\
       \# complaints_pgp:\n\
       \# complaints_pgp_fingerprint:\n\
       \\n\
       \# Hosting provider.\n\
       \# hosting: entity (organization or person name)\n\
       \# hosting_country: ISO-3166 2-letter code\n\n"

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
          hosting = iniEntity "hosting" "hosting_country"
        }
    infoValue name = eitherToMaybe $ lookupValue "INFORMATION" name ini
    iniEntity nameField countryField =
      (\name -> Entity {name, country = countryValue countryField})
        <$!> infoValue nameField
    countryValue field =
      (\cs -> if T.length cs == 2 && T.all (\c -> isAscii c && isAlpha c) cs then T.map toUpper cs else error $ "Use ISO3166 2-letter code for " <> T.unpack field)
        <$!> infoValue field
    iniContacts simplexField emailField pgpKeyUriField pgpKeyFingerprintField =
      let simplex = either error id . parseAll (connReqUriP' Nothing) . encodeUtf8 <$!> eitherToMaybe (lookupValue "INFORMATION" simplexField ini)
          email = infoValue emailField
          pkURI_ = infoValue pgpKeyUriField
          pkFingerprint_ = infoValue pgpKeyFingerprintField
       in case (simplex, email, pkURI_, pkFingerprint_) of
            (Nothing, Nothing, Nothing, _) -> Nothing
            (Nothing, Nothing, _, Nothing) -> Nothing
            (_, _, pkURI, pkFingerprint) -> Just ServerContactAddress {simplex, email, pgp = PGPKey <$> pkURI <*> pkFingerprint}

printSourceCode :: Maybe Text -> IO ()
printSourceCode = \case
  Just sourceCode -> T.putStrLn $ "Server source code: " <> sourceCode
  Nothing -> do
    putStrLn "Warning: server source code is not specified."
    putStrLn "Add 'source_code' property to [INFORMATION] section of INI file."

data CliCommand
  = Init InitOptions
  | OnlineCert CertOptions
  | Start
  | Delete

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    logStats :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName,
    password :: Maybe ServerPassword,
    sourceCode :: Maybe Text,
    webStaticPath :: Maybe FilePath,
    disableWeb :: Bool,
    scripted :: Bool
  }
  deriving (Show)

data ServerPassword = ServerPassword BasicAuth | SPRandom
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
        switch
          ( long "store-log"
              <> short 'l'
              <> help "Enable store log for persistence"
          )
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
      sourceCode <-
        (optional . strOption)
          ( long "source-code"
              <> help "Server source code will be communicated to the users"
              <> metavar "URI"
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
            logStats,
            signAlgorithm,
            ip,
            fqdn,
            password,
            sourceCode,
            webStaticPath,
            disableWeb,
            scripted
          }
    parseBasicAuth :: ReadM ServerPassword
    parseBasicAuth = eitherReader $ fmap ServerPassword . strDecode . B.pack
