{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Server.Main where

import Control.Concurrent.STM
import Control.Monad (void)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SocksMode (..), defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth (..), ProtoServerWithAuth (ProtoServerWithAuth), pattern SMPServer)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defMsgExpirationDays, defaultInactiveClientExpiration, defaultMessageExpiration, defaultProxyClientConcurrency)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (batchCmdsSMPVersion, sendingProxySMPVersion, simplexMQVersion, supportedSMPHandshakes, supportedServerSMPRelayVRange)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (safeDecodeUtf8)
import Simplex.Messaging.Version (mkVersionRange)
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
    initializeServer opts@InitOptions {ip, fqdn, scripted}
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
          initialize opts {enableStoreLog, logStats, fqdn = if null host' then fqdn else Just host', password}
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
        initialize InitOptions {enableStoreLog, logStats, signAlgorithm, password} = do
          clearDirIfExists cfgPath
          clearDirIfExists logPath
          createDirectoryIfMissing True cfgPath
          createDirectoryIfMissing True logPath
          let x509cfg = defaultX509Config {commonName = fromMaybe ip fqdn, signAlgorithm}
          fp <- createServerX509 cfgPath x509cfg
          basicAuth <- mapM createServerPassword password
          let host = fromMaybe (if ip == "127.0.0.1" then "<hostnames>" else ip) fqdn
              srv = ProtoServerWithAuth (SMPServer [THDomainName host] "" (C.KeyHash fp)) basicAuth
          writeFile iniFile $ iniFileContent host basicAuth
          putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `" <> executableName <> " start` to start server."
          warnCAPrivateKeyFile cfgPath x509cfg
          printServiceInfo serverVersion srv
          where
            createServerPassword = \case
              ServerPassword s -> pure s
              SPRandom -> BasicAuth . strEncode <$> (atomically . C.randomBytes 32 =<< C.newRandom)
            iniFileContent host basicAuth =
              "[STORE_LOG]\n\
              \# The server uses STM memory for persistence,\n\
              \# that will be lost on restart (e.g., as with redis).\n\
              \# This option enables saving memory to append only log,\n\
              \# and restoring it when the server is started.\n\
              \# Log is compacted on start (deleted objects are removed).\n"
                <> ("enable: " <> onOff enableStoreLog <> "\n\n")
                <> "# Undelivered messages are optionally saved and restored when the server restarts,\n\
                   \# they are preserved in the .bak file until the next restart.\n"
                <> ("restore_messages: " <> onOff enableStoreLog <> "\n")
                <> ("expire_messages_days: " <> show defMsgExpirationDays <> "\n\n")
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
                      Just auth -> "create_password: " <> T.unpack (safeDecodeUtf8 $ strEncode auth)
                      _ -> "# create_password: password to create new queues (any printable ASCII characters without whitespace, '@', ':' and '/')"
                   )
                <> "\n\n\
                   \# control_port_admin_password:\n\
                   \# control_port_user_password:\n\n\
                   \[TRANSPORT]\n\
                   \# host is only used to print server address on start\n"
                <> ("host: " <> host <> "\n")
                <> ("port: " <> defaultServerPort <> "\n")
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
                <> ("# client_concurrency: " <> show defaultProxyClientConcurrency <> "\n\n")
                <> "[INACTIVE_CLIENTS]\n\
                   \# TTL and interval to check inactive clients\n\
                   \disconnect: off\n"
                <> ("# ttl: " <> show (ttl defaultInactiveClientExpiration) <> "\n")
                <> ("# check_interval: " <> show (checkInterval defaultInactiveClientExpiration) <> "\n")
    runServer ini = do
      hSetBuffering stdout LineBuffering
      hSetBuffering stderr LineBuffering
      fp <- checkSavedFingerprint cfgPath defaultX509Config
      let host = either (const "<hostnames>") T.unpack $ lookupValue "TRANSPORT" "host" ini
          port = T.unpack $ strictIni "TRANSPORT" "port" ini
          cfg@ServerConfig {transports, storeLogFile, newQueueBasicAuth, messageExpiration, inactiveClientExpiration} = serverConfig
          srv = ProtoServerWithAuth (SMPServer [THDomainName host] (if port == "5223" then "" else port) (C.KeyHash fp)) newQueueBasicAuth
      printServiceInfo serverVersion srv
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
              -- serverTbqSize = 1024,
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
              newQueueBasicAuth = either error id <$> strDecodeIni "AUTH" "create_password" ini,
              controlPortAdminAuth = either error id <$> strDecodeIni "AUTH" "control_port_admin_password" ini,
              controlPortUserAuth = either error id <$> strDecodeIni "AUTH" "control_port_user_password" ini,
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
              smpServerVRange = supportedServerSMPRelayVRange,
              transportConfig =
                defaultTransportServerConfig
                  { logTLSErrors = fromMaybe False $ iniOnOff "TRANSPORT" "log_tls_errors" ini,
                    alpn = Just supportedSMPHandshakes
                  },
              controlPort = either (const Nothing) (Just . T.unpack) $ lookupValue "TRANSPORT" "control_port" ini,
              smpAgentCfg =
                defaultSMPClientAgentConfig
                  { smpCfg =
                      (smpCfg defaultSMPClientAgentConfig)
                        { serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion,
                          agreeSecret = True,
                          networkConfig =
                            defaultNetworkConfig
                              { socksProxy = either error id <$> strDecodeIni "PROXY" "socks_proxy" ini,
                                socksMode = either (const SMOnion) textToSocksMode $ lookupValue "PROXY" "socks_mode" ini,
                                hostMode = either (const HMPublic) textToHostMode $ lookupValue "PROXY" "host_mode" ini,
                                requiredHostMode = fromMaybe False $ iniOnOff "PROXY" "required_host_mode" ini
                              }
                        },
                    ownServerDomains = either (const []) textToOwnServers $ lookupValue "PROXY" "own_server_domains" ini,
                    persistErrorInterval = 30 -- seconds
                  },
              allowSMPProxy = True,
              proxyClientConcurrency = readIniDefault defaultProxyClientConcurrency "PROXY" "client_concurrency" ini
            }
        textToSocksMode :: Text -> SocksMode
        textToSocksMode = \case
          "always" -> SMAlways
          "onion" -> SMOnion
          s -> error . T.unpack $ "Invalid socks_mode: " <> s
        textToHostMode :: Text -> HostMode
        textToHostMode = \case
          "public" -> HMPublic
          "onion" -> HMOnionViaSocks
          s -> error . T.unpack $ "Invalid host_mode: " <> s
        textToOwnServers :: Text -> [ByteString]
        textToOwnServers = map encodeUtf8 . T.words

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
              <> showDefault
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
      scripted <-
        switch
          ( long "yes"
              <> short 'y'
              <> help "Non-interactive initialization using command-line options"
          )
      pure InitOptions {enableStoreLog, logStats, signAlgorithm, ip, fqdn, password, scripted}
    parseBasicAuth :: ReadM ServerPassword
    parseBasicAuth = eitherReader $ fmap ServerPassword . strDecode . B.pack
