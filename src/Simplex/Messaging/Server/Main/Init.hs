{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Main.Init where

import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, isNothing)
import Numeric.Natural (Natural)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Network.Socket (HostName)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth)
import Simplex.Messaging.Server.CLI (SignAlgorithm, onOff)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.Information (Entity (..), ServerPublicInfo (..))
import Simplex.Messaging.Transport.Client (SocksProxy, TransportHost)
import Simplex.Messaging.Util (safeDecodeUtf8, tshow)
import System.FilePath ((</>))

defaultControlPort :: Int
defaultControlPort = 5224

defaultDBOpts :: DBOpts
defaultDBOpts =
  DBOpts
    { connstr = defaultDBConnStr,
      schema = defaultDBSchema,
      poolSize = defaultDBPoolSize,
      createSchema = False
    }

defaultDBConnStr :: ByteString
defaultDBConnStr = "postgresql://smp@/smp_server_store"

defaultDBSchema :: ByteString
defaultDBSchema = "smp_server"

defaultDBPoolSize :: Natural
defaultDBPoolSize = 10

-- time to retain deleted queues in the database (days), for debugging
defaultDeletedTTL :: Int64
defaultDeletedTTL = 21

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    dbOptions :: DBOpts,
    logStats :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName,
    password :: Maybe ServerPassword,
    controlPort :: Maybe Int,
    socksProxy :: Maybe SocksProxy,
    ownDomains :: Maybe (L.NonEmpty TransportHost),
    sourceCode :: Maybe Text,
    serverInfo :: ServerPublicInfo,
    operatorCountry :: Maybe Text,
    hostingCountry :: Maybe Text,
    webStaticPath :: Maybe FilePath,
    disableWeb :: Bool,
    scripted :: Bool
  }
  deriving (Show)

data ServerPassword = ServerPassword BasicAuth | SPRandom
  deriving (Show)

iniFileContent :: FilePath -> FilePath -> InitOptions -> HostName -> Maybe BasicAuth -> Maybe (Text, Text) -> Text
iniFileContent cfgPath logPath opts host basicAuth controlPortPwds =
  informationIniContent opts
    <> "[STORE_LOG]\n\
        \# The server uses memory or PostgreSQL database for persisting queue records.\n\
        \# Use `enable: on` to use append-only log to preserve and restore queue records on restart.\n\
        \# Log is compacted on start (deleted objects are removed).\n"
    <> ("enable: " <> onOff enableStoreLog <> "\n\n")
    <> "# Queue storage mode: `memory` or `database` (to store queue records in PostgreSQL database).\n\
        \# `memory` - in-memory persistence, with optional append-only log (`enable: on`).\n\
        \# `database`- PostgreSQL databass (requires `store_messages: journal`).\n\
        \store_queues: memory\n\n\
        \# Database connection settings for PostgreSQL database (`store_queues: database`).\n"
    <> (optDisabled' (connstr == defaultDBConnStr) <> "db_connection: " <> safeDecodeUtf8 connstr <> "\n")
    <> (optDisabled' (schema == defaultDBSchema) <> "db_schema: " <> safeDecodeUtf8 schema <> "\n")
    <> (optDisabled' (poolSize == defaultDBPoolSize) <> "db_pool_size: " <> tshow poolSize <> "\n\n")
    <> "# Write database changes to store log file\n\
        \# db_store_log: off\n\n\
        \# Time to retain deleted queues in the database, days.\n"
    <> ("db_deleted_ttl: " <> tshow defaultDeletedTTL <> "\n\n")
    <> "# Message storage mode: `memory` or `journal`.\n\
        \store_messages: memory\n\n\
        \# When store_messages is `memory`, undelivered messages are optionally saved and restored\n\
        \# when the server restarts, they are preserved in the .bak file until the next restart.\n"
    <> ("restore_messages: " <> onOff enableStoreLog <> "\n\n")
    <> "# Messages and notifications expiration periods.\n"
    <> ("expire_messages_days: " <> tshow defMsgExpirationDays <> "\n")
    <> "expire_messages_on_start: on\n"
    <> ("expire_ntfs_hours: " <> tshow defNtfExpirationHours <> "\n\n")
    <> "# Log daily server statistics to CSV file\n"
    <> ("log_stats: " <> onOff logStats <> "\n\n")
    <> "# Log interval for real-time Prometheus metrics\n\
        \# prometheus_interval: 300\n\n\
        \[AUTH]\n\
        \# Set new_queues option to off to completely prohibit creating new messaging queues.\n\
        \# This can be useful when you want to decommission the server, but not all connections are switched yet.\n\
        \new_queues: on\n\n\
        \# Use create_password option to enable basic auth to create new messaging queues.\n\
        \# The password should be used as part of server address in client configuration:\n\
        \# smp://fingerprint:password@host1,host2\n\
        \# The password will not be shared with the connecting contacts, you must share it only\n\
        \# with the users who you want to allow creating messaging queues on your server.\n"
    <> ( let noPassword = "password to create new queues and forward messages (any printable ASCII characters without whitespace, '@', ':' and '/')"
          in optDisabled basicAuth <> "create_password: " <> maybe noPassword (safeDecodeUtf8 . strEncode) basicAuth
        )
    <> "\n\n"
    <> (optDisabled controlPortPwds <> "control_port_admin_password: " <> maybe "" fst controlPortPwds <> "\n")
    <> (optDisabled controlPortPwds <> "control_port_user_password: " <> maybe "" snd controlPortPwds <> "\n")
    <> "\n\
        \[TRANSPORT]\n\
        \# Host is only used to print server address on start.\n\
        \# You can specify multiple server ports.\n"
    <> ("host: " <> T.pack host <> "\n")
    <> ("port: " <> defaultServerPorts <> "\n")
    <> "log_tls_errors: off\n\n\
        \# Use `websockets: 443` to run websockets server in addition to plain TLS.\n\
        \# This option is deprecated and should be used for testing only.\n\
        \# , port 443 should be specified in port above\n\
        \websockets: off\n"
    <> (optDisabled controlPort <> "control_port: " <> tshow (fromMaybe defaultControlPort controlPort))
    <> "\n\n\
        \[PROXY]\n\
        \# Network configuration for SMP proxy client.\n\
        \# `host_mode` can be 'public' (default) or 'onion'.\n\
        \# It defines prefferred hostname for destination servers with multiple hostnames.\n\
        \# host_mode: public\n\
        \# required_host_mode: off\n\n\
        \# The domain suffixes of the relays you operate (space-separated) to count as separate proxy statistics.\n"
    <> (optDisabled ownDomains <> "own_server_domains: " <> maybe "" (safeDecodeUtf8 . strEncode) ownDomains)
    <> "\n\n\
        \# SOCKS proxy port for forwarding messages to destination servers.\n\
        \# You may need a separate instance of SOCKS proxy for incoming single-hop requests.\n"
    <> (optDisabled socksProxy <> "socks_proxy: " <> maybe "localhost:9050" (safeDecodeUtf8 . strEncode) socksProxy)
    <> "\n\n\
        \# `socks_mode` can be 'onion' for SOCKS proxy to be used for .onion destination hosts only (default)\n\
        \# or 'always' to be used for all destination hosts (can be used if it is an .onion server).\n\
        \# socks_mode: onion\n\n\
        \# Limit number of threads a client can spawn to process proxy commands in parrallel.\n"
    <> ("# client_concurrency: " <> tshow defaultProxyClientConcurrency)
    <> "\n\n\
        \[INACTIVE_CLIENTS]\n\
        \# TTL and interval to check inactive clients\n\
        \disconnect: on\n"
    <> ("ttl: " <> tshow (ttl defaultInactiveClientExpiration) <> "\n")
    <> ("check_interval: " <> tshow (checkInterval defaultInactiveClientExpiration))
    <> "\n\n\
        \[WEB]\n\
        \# Set path to generate static mini-site for server information and qr codes/links\n"
    <> ("static_path: " <> T.pack (fromMaybe defaultStaticPath webStaticPath) <> "\n\n")
    <> "# Run an embedded server on this port\n\
        \# Onion sites can use any port and register it in the hidden service config.\n\
        \# Running on a port 80 may require setting process capabilities.\n\
        \# http: 8000\n\n\
        \# You can run an embedded TLS web server too if you provide port and cert and key files.\n\
        \# Not required for running relay on onion address.\n"
    <> (webDisabled <> "https: 443\n")
    <> (webDisabled <> "cert: " <> T.pack httpsCertFile <> "\n")
    <> (webDisabled <> "key: " <> T.pack httpsKeyFile <> "\n")
  where
    InitOptions {enableStoreLog, dbOptions, socksProxy, ownDomains, controlPort, webStaticPath, disableWeb, logStats} = opts
    DBOpts {connstr, schema, poolSize} = dbOptions
    defaultServerPorts = "5223,443"
    defaultStaticPath = logPath </> "www"
    httpsCertFile = cfgPath </> "web.crt"
    httpsKeyFile = cfgPath </> "web.key"
    webDisabled = if disableWeb then "# " else ""

informationIniContent :: InitOptions -> Text
informationIniContent InitOptions {sourceCode, serverInfo} =
  "[INFORMATION]\n\
  \# AGPLv3 license requires that you make any source code modifications\n\
  \# available to the end users of the server.\n\
  \# LICENSE: https://github.com/simplex-chat/simplexmq/blob/stable/LICENSE\n\
  \# Include correct source code URI in case the server source code is modified in any way.\n\
  \# If any other information fields are present, source code property also MUST be present.\n\n"
    <> (optDisabled sourceCode <> "source_code: " <> fromMaybe "URI" sourceCode)
    <> "\n\n\
       \# Declaring all below information is optional, any of these fields can be omitted.\n\
       \\n\
       \# Server usage conditions and amendments.\n\
       \# It is recommended to use standard conditions with any amendments in a separate document.\n\
       \# usage_conditions: https://github.com/simplex-chat/simplex-chat/blob/stable/PRIVACY.md\n\
       \# condition_amendments: link\n\
       \\n\
       \# Server location and operator.\n"
    <> countryStr "server" serverCountry
    <> enitiyStrs "operator" operator
    <> (optDisabled website <> "website: " <> fromMaybe "" website)
    <> "\n\n\
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
       \# Hosting provider.\n"
    <> enitiyStrs "hosting" hosting
    <> "\n\
       \# Hosting type can be `virtual`, `dedicated`, `colocation`, `owned`\n"
    <> ("hosting_type: " <> maybe "virtual" (decodeLatin1 . strEncode) hostingType <> "\n\n")
  where
    ServerPublicInfo {operator, website, hosting, hostingType, serverCountry} = serverInfo
    countryStr optName country = optDisabled country <> optName <> "_country: " <> fromMaybe "ISO-3166 2-letter code" country <> "\n"
    enitiyStrs optName entity =
      optDisabled entity
        <> optName
        <> ": "
        <> maybe "entity (organization or person name)" name entity
        <> "\n"
        <> countryStr optName (country =<< entity)

optDisabled :: Maybe a -> Text
optDisabled = optDisabled' . isNothing
{-# INLINE optDisabled #-}

optDisabled' :: Bool -> Text
optDisabled' cond = if cond then "# " else ""
{-# INLINE optDisabled' #-}
