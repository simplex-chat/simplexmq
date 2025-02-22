{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres
  ( DBOpts (..),
    Migrations.getCurrentMigrations,
    createDBStore,
    closeDBStore,
    reopenDBStore,
    connectDB,
    execSQL,
  )
where

import Control.Exception (throwIO)
import Control.Logger.Simple (logError)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.Functor (($>))
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.Types (Query (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Simplex.Messaging.Agent.Store.Migrations (DBMigrate (..), sharedMigrateSchema)
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as Migrations
import Simplex.Messaging.Agent.Store.Postgres.Common
import qualified Simplex.Messaging.Agent.Store.Postgres.DB as DB
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfirmation (..), MigrationError (..))
import Simplex.Messaging.Util (ifM, safeDecodeUtf8)
import System.Exit (exitFailure)
import UnliftIO.Exception (bracketOnError, onException)
import UnliftIO.MVar
import UnliftIO.STM

-- | Create a new Postgres DBStore with the given connection string, schema name and migrations.
-- If passed schema does not exist in connectInfo database, it will be created.
-- Applies necessary migrations to schema.
-- TODO [postgres] authentication / user password, db encryption (?)
createDBStore :: DBOpts -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError DBStore)
createDBStore opts migrations confirmMigrations = do
  st <- connectPostgresStore opts
  r <- migrateSchema st `onException` closeDBStore st
  case r of
    Right () -> pure $ Right st
    Left e -> closeDBStore st $> Left e
  where
    migrateSchema st =
      let initialize = Migrations.initialize st
          getCurrent = withTransaction st Migrations.getCurrentMigrations
          dbm = DBMigrate {initialize, getCurrent, run = Migrations.run st, backup = pure ()}
       in sharedMigrateSchema dbm (dbNew st) migrations confirmMigrations

connectPostgresStore :: DBOpts -> IO DBStore
connectPostgresStore DBOpts {connstr, schema, createSchema} = do
  (dbConn, dbNew) <- connectDB connstr schema createSchema -- TODO [postgres] analogue for dbBusyLoop?
  when (dbNew && not createSchema) $ do
    logError $ "connectPostgresStore, schema " <> safeDecodeUtf8 schema <> " does not exist, exiting."
    DB.close dbConn
    exitFailure
  dbConnection <- newMVar dbConn
  dbClosed <- newTVarIO False
  pure DBStore {dbConnstr = connstr, dbSchema = schema, dbConnection, dbNew, dbClosed}

connectDB :: ByteString -> ByteString -> Bool -> IO (DB.Connection, Bool)
connectDB connstr schema createSchema = do
  db <- PSQL.connectPostgreSQL connstr
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
      if schemaExists
        then setSearchPath db
        else when createSchema $ do
          void $ PSQL.execute_ db $ Query $ "CREATE SCHEMA " <> schema
          setSearchPath db
      pure schemaExists
    setSearchPath db = void $ PSQL.execute_ db $ Query $ "SET search_path TO " <> schema

-- can share with SQLite
closeDBStore :: DBStore -> IO ()
closeDBStore st@DBStore {dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeDBStore: already closed") $
    withConnection st $ \conn -> do
      DB.close conn
      atomically $ writeTVar dbClosed True

openPostgresStore_ :: DBStore -> IO ()
openPostgresStore_ DBStore {dbConnstr, dbSchema, dbConnection, dbClosed} =
  bracketOnError
    (takeMVar dbConnection)
    (tryPutMVar dbConnection)
    $ \_dbConn -> do
      (dbConn, _dbNew) <- connectDB dbConnstr dbSchema False
      atomically $ writeTVar dbClosed False
      putMVar dbConnection dbConn

reopenDBStore :: DBStore -> IO ()
reopenDBStore st@DBStore {dbClosed} =
  ifM (readTVarIO dbClosed) open (putStrLn "reopenDBStore: already opened")
  where
    open = openPostgresStore_ st

-- TODO [postgres] not necessary for postgres (used for ExecAgentStoreSQL, ExecChatStoreSQL)
execSQL :: PSQL.Connection -> Text -> IO [Text]
execSQL _db _query = throwIO (userError "not implemented")
