{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres
  ( createDBStore,
    defaultSimplexConnectInfo,
    closeDBStore,
    execSQL,
    -- for tests
    dropDatabaseAndUser,
    dropSchema,
  )
where

import Control.Exception (bracket, throwIO)
import Control.Monad (unless, void)
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
    \db -> do
      -- check if the user exists, create if not
      [Only userExists] <-
        PSQL.query
          db
          [sql|
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_roles
              WHERE rolname = ?
            )
          |]
          (Only user)
      unless userExists $ void $ PSQL.execute_ db (fromString $ "CREATE USER " <> user)
      -- check if the database exists, create if not
      [Only dbExists] <-
        PSQL.query
          db
          [sql|
            SELECT EXISTS (
              SELECT 1 FROM pg_catalog.pg_database
              WHERE datname = ?
            )
          |]
          (Only dbName)
      unless dbExists $ void $ PSQL.execute_ db (fromString $ "CREATE DATABASE " <> dbName <> " OWNER " <> user)

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
dropSchema connectInfo schema = do
  bracket (PSQL.connect connectInfo) PSQL.close $
    \db ->
      void $ PSQL.execute_ db (fromString $ "DROP SCHEMA IF EXISTS " <> schema <> " CASCADE")

dropDatabaseAndUser :: ConnectInfo -> IO ()
dropDatabaseAndUser ConnectInfo {connectUser = user, connectDatabase = dbName} = do
  bracket (PSQL.connect defaultConnectInfo {connectUser = "postgres", connectDatabase = "postgres"}) PSQL.close $
    \db -> do
      void $ PSQL.execute_ db (fromString $ "DROP USER " <> user)
      void $ PSQL.execute_ db (fromString $ "DROP DATABASE " <> dbName)
