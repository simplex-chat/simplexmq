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
import Data.Functor (($>))
import Data.Ini (lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as T
import Network.Socket (HostName)
import Options.Applicative
import Simplex.Messaging.Client (HostMode (..), NetworkConfig (..), ProtocolClientConfig (..), SocksMode (..), defaultNetworkConfig, textToHostMode)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Server (runNtfServer)
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..), defaultInactiveClientExpiration)
import Simplex.Messaging.Notifications.Server.Push.APNS (defaultAPNSPushClientConfig)
import Simplex.Messaging.Notifications.Transport (supportedServerNTFVRange)
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), pattern NtfServer)
import Simplex.Messaging.Server.CLI
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (ServerCredentials (..), TransportServerConfig (..), defaultTransportServerConfig)
import Simplex.Messaging.Util (tshow)
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
    iniFile = combine cfgPath "ntf-server.ini"
    serverVersion = "SMP notifications server v" <> simplexMQVersion
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
        restoreLastNtfsFile path = case iniOnOff "STORE_LOG" "restore_last_notifications" ini of
          Just True -> Just path
          Just False -> Nothing
          -- if the setting is not set, it is enabled when store log is enabled
          _ -> enableStoreLog $> path
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
              storeLogFile = enableStoreLog $> storeLogFilePath,
              storeLastNtfsFile = restoreLastNtfsFile $ combine logPath "ntf-server-last-notifications.log",
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
                  }
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
    fqdn :: Maybe HostName
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
