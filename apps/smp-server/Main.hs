{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Logger.Simple
import Data.Functor (($>))
import Data.Ini (lookupValue)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.CLI (ServerCLIConfig (..), protocolServerCLI, readStrictIni)
import Simplex.Messaging.Server.Env.STM (ServerConfig (..), defaultInactiveClientExpiration, defaultMessageExpiration)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (simplexMQVersion, supportedSMPServerVRange)
import System.FilePath (combine)

cfgPath :: FilePath
cfgPath = "/etc/opt/simplex"

logPath :: FilePath
logPath = "/var/opt/simplex"

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug
  withGlobalLogging logCfg . protocolServerCLI smpServerCLIConfig $ \cfg@ServerConfig {inactiveClientExpiration} -> do
    putStrLn $ case inactiveClientExpiration of
      Just ExpirationConfig {ttl, checkInterval} -> "expiring clients inactive for " <> show ttl <> " seconds every " <> show checkInterval <> " seconds"
      _ -> "not expiring inactive clients"
    putStrLn $
      "creating new queues "
        <> if allowNewQueues cfg
          then maybe "allowed" (const "requires basic auth") $ newQueueBasicAuth cfg
          else "NOT allowed"
    runSMPServer cfg

smpServerCLIConfig :: ServerCLIConfig ServerConfig
smpServerCLIConfig =
  let caCrtFile = combine cfgPath "ca.crt"
      serverKeyFile = combine cfgPath "server.key"
      serverCrtFile = combine cfgPath "server.crt"
   in ServerCLIConfig
        { cfgDir = cfgPath,
          logDir = logPath,
          iniFile = combine cfgPath "smp-server.ini",
          storeLogFile = combine logPath "smp-server-store.log",
          caKeyFile = combine cfgPath "ca.key",
          caCrtFile,
          serverKeyFile,
          serverCrtFile,
          fingerprintFile = combine cfgPath "fingerprint",
          defaultServerPort = "5223",
          executableName = "smp-server",
          serverVersion = "SMP server v" <> simplexMQVersion,
          mkIniFile = \enableStoreLog defaultServerPort ->
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
              <> ("# check_interval: " <> show (checkInterval defaultInactiveClientExpiration) <> "\n"),
          mkServerConfig = \storeLogFile transports ini ->
            let onOff section name = case lookupValue section name ini of
                  Right "on" -> Just True
                  Right "off" -> Just False
                  Right s -> error . T.unpack $ "invalid INI setting " <> name <> ": " <> s
                  _ -> Nothing
                settingIsOn section name = if onOff section name == Just True then Just () else Nothing
                logStats = settingIsOn "STORE_LOG" "log_stats"
             in ServerConfig
                  { transports,
                    tbqSize = 16,
                    serverTbqSize = 64,
                    msgQueueQuota = 128,
                    queueIdBytes = 24,
                    msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
                    caCertificateFile = caCrtFile,
                    privateKeyFile = serverKeyFile,
                    certificateFile = serverCrtFile,
                    storeLogFile,
                    storeMsgsFile =
                      let messagesPath = combine logPath "smp-server-messages.log"
                       in case onOff "STORE_LOG" "restore_messages" of
                            Just True -> Just messagesPath
                            Just False -> Nothing
                            -- if the setting is not set, it is enabled when store log is enabled
                            _ -> storeLogFile $> messagesPath,
                    -- allow creating new queues by default
                    allowNewQueues = fromMaybe True $ onOff "AUTH" "new_queues",
                    newQueueBasicAuth = case lookupValue "AUTH" "create_password" ini of
                      Right auth -> either error Just . strDecode $ encodeUtf8 auth
                      _ -> Nothing,
                    messageExpiration = Just defaultMessageExpiration,
                    inactiveClientExpiration =
                      settingIsOn "INACTIVE_CLIENTS" "disconnect"
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
        }
