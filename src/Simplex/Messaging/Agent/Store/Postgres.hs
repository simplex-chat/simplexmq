{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres
  ( createDBStore,
    defaultSimplexConnectInfo,
    closeDBStore,
    execSQL,
    -- for tests
    createDBAndUserIfNotExists,
    dropSchema,
    dropAllSchemasExceptSystem,
    dropDatabaseAndUser,
  )
where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, unless, void, when)
import Data.Functor (($>))
import Data.String (fromString)
import Data.Text (Text)
import Database.PostgreSQL.Simple (ConnectInfo (..), Only (..), defaultConnectInfo)
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Simplex.Messaging.Agent.Store.Migrations (migrateSchema)
import Simplex.Messaging.Agent.Store.Postgres.Common
import qualified Simplex.Messaging.Agent.Store.Postgres.DB as DB
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationError (..))
import Simplex.Messaging.Util (ifM)
import UnliftIO.Exception (onException)
import UnliftIO.MVar
import UnliftIO.STM

defaultSimplexConnectInfo :: ConnectInfo
defaultSimplexConnectInfo =
  defaultConnectInfo
    { connectUser = "simplex",
      connectDatabase = "simplex_v6_3_client_db"
    }

-- | Create a new Postgres DBStore with the given connection info, schema name and migrations.
-- This function creates the user and/or database passed in connectInfo if they do not exist
-- (expects the default 'postgres' user and 'postgres' db to exist).
-- If passed schema does not exist in connectInfo database, it will be created.
-- Applies necessary migrations to schema.
-- TODO [postgres] authentication / user password, db encryption (?)
createDBStore :: ConnectInfo -> String -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError DBStore)
createDBStore connectInfo schema migrations confirmMigrations = do
  createDBAndUserIfNotExists connectInfo
  st <- connectPostgresStore connectInfo schema
  r <- migrateSchema st migrations confirmMigrations `onException` closeDBStore st
  case r of
    Right () -> pure $ Right st
    Left e -> closeDBStore st $> Left e

createDBAndUserIfNotExists :: ConnectInfo -> IO ()
createDBAndUserIfNotExists ConnectInfo {connectUser = user, connectDatabase = dbName} = do
  -- connect to the default "postgres" maintenance database
  bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = "postgres"}) PSQL.close $
    \postgresDB -> do
      void $ PSQL.execute_ postgresDB "SET client_min_messages TO WARNING"
      -- check if the user exists, create if not
      [Only userExists] <-
        PSQL.query
          postgresDB
          [sql|
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_roles
              WHERE rolname = ?
            )
          |]
          (Only user)
      unless userExists $ void $ PSQL.execute_ postgresDB (fromString $ "CREATE USER " <> user)
      -- check if the database exists, create if not
      dbExists <- checkDBExists postgresDB dbName
      unless dbExists $ void $ PSQL.execute_ postgresDB (fromString $ "CREATE DATABASE " <> dbName <> " OWNER " <> user)

checkDBExists :: PSQL.Connection -> String -> IO Bool
checkDBExists postgresDB dbName = do
  [Only dbExists] <-
    PSQL.query
      postgresDB
      [sql|
        SELECT EXISTS (
          SELECT 1 FROM pg_catalog.pg_database
          WHERE datname = ?
        )
      |]
      (Only dbName)
  pure dbExists

connectPostgresStore :: ConnectInfo -> String -> IO DBStore
connectPostgresStore dbConnectInfo schema = do
  (dbConn, dbNew) <- connectDB dbConnectInfo schema -- TODO [postgres] analogue for dbBusyLoop?
  dbConnection <- newMVar dbConn
  dbClosed <- newTVarIO False
  pure DBStore {dbConnectInfo, dbConnection, dbNew, dbClosed}

connectDB :: ConnectInfo -> String -> IO (DB.Connection, Bool)
connectDB dbConnectInfo schema = do
  db <- PSQL.connect dbConnectInfo
  schemaExists <- prepare db `onException` PSQL.close db
  let dbNew = not schemaExists
  pure (db, dbNew)
  where
    prepare db = do
      void $ PSQL.execute_ db "SET client_min_messages TO WARNING"
      [Only schemaExists] <-
        PSQL.query
          db
          [sql|
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_namespace
              WHERE nspname = ?
            )
          |]
          (Only schema)
      unless schemaExists $ void $ PSQL.execute_ db (fromString $ "CREATE SCHEMA " <> schema)
      void $ PSQL.execute_ db (fromString $ "SET search_path TO " <> schema)
      pure schemaExists

-- can share with SQLite
closeDBStore :: DBStore -> IO ()
closeDBStore st@DBStore {dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeDBStore: already closed") $
    withConnection st $ \conn -> do
      DB.close conn
      atomically $ writeTVar dbClosed True

-- TODO [postgres] not necessary for postgres (used for ExecAgentStoreSQL, ExecChatStoreSQL)
execSQL :: PSQL.Connection -> Text -> IO [Text]
execSQL _db _query = throwIO (userError "not implemented")

dropSchema :: ConnectInfo -> String -> IO ()
dropSchema connectInfo schema =
  bracket (PSQL.connect connectInfo) PSQL.close $
    \db -> do
      void $ PSQL.execute_ db "SET client_min_messages TO WARNING"
      void $ PSQL.execute_ db (fromString $ "DROP SCHEMA IF EXISTS " <> schema <> " CASCADE")

dropAllSchemasExceptSystem :: ConnectInfo -> IO ()
dropAllSchemasExceptSystem connectInfo =
  bracket (PSQL.connect connectInfo) PSQL.close $
    \db -> do
      void $ PSQL.execute_ db "SET client_min_messages TO WARNING"
      schemaNames :: [Only String] <-
        PSQL.query_
          db
          [sql|
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('public', 'pg_catalog', 'information_schema')
          |]
      forM_ schemaNames $ \(Only schema) ->
        PSQL.execute_ db (fromString $ "DROP SCHEMA " <> schema <> " CASCADE")

dropDatabaseAndUser :: ConnectInfo -> IO ()
dropDatabaseAndUser ConnectInfo {connectUser = user, connectDatabase = dbName} =
  bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = "postgres"}) PSQL.close $
    \postgresDB -> do
      void $ PSQL.execute_ postgresDB "SET client_min_messages TO WARNING"
      dbExists <- checkDBExists postgresDB dbName
      when dbExists $ do
        void $ PSQL.execute_ postgresDB (fromString $ "ALTER DATABASE " <> dbName <> " WITH ALLOW_CONNECTIONS false")
        -- terminate all connections to the database
        _r :: [Only Bool] <-
          PSQL.query
            postgresDB
            [sql|
              SELECT pg_terminate_backend(pg_stat_activity.pid)
              FROM pg_stat_activity
              WHERE datname = ?
                AND pid <> pg_backend_pid()
            |]
            (Only dbName)
        void $ PSQL.execute_ postgresDB (fromString $ "DROP DATABASE " <> dbName)
      void $ PSQL.execute_ postgresDB (fromString $ "DROP USER IF EXISTS " <> user)
