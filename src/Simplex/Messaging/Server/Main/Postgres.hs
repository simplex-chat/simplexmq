{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.Main.Postgres where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Ini (Ini, lookupValue)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Numeric.Natural (Natural)
import Options.Applicative
import Simplex.Messaging.Agent.Store.Postgres.Common (DBOpts (..))
import Simplex.Messaging.Server.CLI (readIniDefault)
import Simplex.Messaging.Server.Main.INI
import Simplex.Messaging.Server.Main.Options
import Simplex.Messaging.Util (safeDecodeUtf8, tshow)
import System.Exit (exitFailure)

defaultDBConnStr :: ByteString
defaultDBConnStr = "postgresql://smp@/smp_server_store"

defaultDBSchema :: ByteString
defaultDBSchema = "smp_server"

defaultDBPoolSize :: Natural
defaultDBPoolSize = 10

-- time to retain deleted queues in the database (days), for debugging
defaultDeletedTTL :: Int64
defaultDeletedTTL = 21

iniDbFileContent :: InitOptions -> Text
iniDbFileContent InitOptions {dbOptions = DBOpts {connstr, schema, poolSize}} =
  "# Queue storage mode: `memory` or `database` (to store queue records in PostgreSQL database).\n\
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

iniDBOptions :: Ini -> DBOpts
iniDBOptions ini =
  DBOpts
    { connstr = either (const defaultDBConnStr) encodeUtf8 $ lookupValue "STORE_LOG" "db_connection" ini,
      schema = either (const defaultDBSchema) encodeUtf8 $ lookupValue "STORE_LOG" "db_schema" ini,
      poolSize = readIniDefault defaultDBPoolSize "STORE_LOG" "db_pool_size" ini,
      createSchema = False
    }

iniDeletedTTL :: Ini -> Int64
iniDeletedTTL ini = readIniDefault (86400 * defaultDeletedTTL) "STORE_LOG" "db_deleted_ttl" ini

dbOptsP :: Parser DBOpts
dbOptsP = do
  connstr <-
    strOption
      ( long "database"
          <> short 'd'
          <> metavar "DB_CONN"
          <> help "Database connection string"
          <> value defaultDBConnStr
          <> showDefault
      )
  schema <-
    strOption
      ( long "schema"
          <> metavar "DB_SCHEMA"
          <> help "Database schema"
          <> value defaultDBSchema
          <> showDefault
      )
  poolSize <-
    option
      auto
      ( long "pool-size"
          <> metavar "POOL_SIZE"
          <> help "Database pool size"
          <> value defaultDBPoolSize
          <> showDefault
      )
  pure DBOpts {connstr, schema, poolSize, createSchema = False}

exitConfigureQueueStore :: FilePath -> ByteString -> ByteString -> IO ()
exitConfigureQueueStore logFilePath connstr schema = do
  putStrLn $ "Error: both " <> logFilePath <> " file and " <> B.unpack schema <> " schema are present (database: " <> B.unpack connstr <> ")."
  putStrLn "Configure queue storage."
  exitFailure
