{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.Postgres
  ( DBOpts (..),
    Migrations.getCurrentMigrations,
    checkSchemaExists,
    createDBStore,
    closeDBStore,
    reopenDBStore,
    execSQL,
  )
where

import Control.Concurrent.STM
import Control.Exception (finally, onException, throwIO, uninterruptibleMask_)
import Control.Logger.Simple (logError)
import Control.Monad
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
import UnliftIO.MVar

-- | Create a new Postgres DBStore with the given connection string, schema name and migrations.
-- If passed schema does not exist in connectInfo database, it will be created.
-- Applies necessary migrations to schema.
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
connectPostgresStore DBOpts {connstr, schema, poolSize, createSchema} = do
  dbSem <- newMVar ()
  dbPool <- newTBQueueIO poolSize
  dbClosed <- newTVarIO True
  let db = DBStore {dbConnstr = connstr, dbSchema = schema, dbPoolSize = fromIntegral poolSize, dbPool, dbSem, dbNew = False, dbClosed}
  dbNew <- connectPool db createSchema
  pure db {dbNew}

-- uninterruptibleMask_ here and below is used here so that it is not interrupted half-way,
-- it relies on the assumption that when dbClosed = True, the queue is empty,
-- and when it is False, the queue is full (or will have connections returned to it by the threads that use them).
connectPool :: DBStore -> Bool -> IO Bool
connectPool DBStore {dbConnstr, dbSchema, dbPoolSize, dbPool, dbClosed} createSchema = uninterruptibleMask_ $ do
  (conn, dbNew) <- connectDB dbConnstr dbSchema createSchema -- TODO [postgres] analogue for dbBusyLoop?
  conns <- replicateM (dbPoolSize - 1) $ fst <$> connectDB dbConnstr dbSchema False
  mapM_ (atomically . writeTBQueue dbPool) (conn : conns)
  atomically $ writeTVar dbClosed False
  pure dbNew

connectDB :: ByteString -> ByteString -> Bool -> IO (DB.Connection, Bool)
connectDB connstr schema createSchema = do
  db <- PSQL.connectPostgreSQL connstr
  dbNew <- prepare db `onException` PSQL.close db
  pure (db, dbNew)
  where
    prepare db = do
      void $ PSQL.execute_ db "SET client_min_messages TO WARNING"
      dbNew <- not <$> doesSchemaExist db schema
      when dbNew $
        if createSchema
          then void $ PSQL.execute_ db $ Query $ "CREATE SCHEMA " <> schema
          else do
            logError $ "connectPostgresStore, schema " <> safeDecodeUtf8 schema <> " does not exist, exiting."
            PSQL.close db
            exitFailure
      void $ PSQL.execute_ db $ Query $ "SET search_path TO " <> schema
      pure dbNew

checkSchemaExists :: ByteString -> ByteString -> IO Bool
checkSchemaExists connstr schema = do
  db <- PSQL.connectPostgreSQL connstr
  doesSchemaExist db schema `finally` DB.close db

doesSchemaExist :: DB.Connection -> ByteString -> IO Bool
doesSchemaExist db schema = do
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
  pure schemaExists

closeDBStore :: DBStore -> IO ()
closeDBStore DBStore {dbPool, dbPoolSize, dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeDBStore: already closed") $ uninterruptibleMask_ $ do
    replicateM_ dbPoolSize $ atomically $ readTBQueue dbPool
    atomically $ writeTVar dbClosed True

reopenDBStore :: DBStore -> IO ()
reopenDBStore db =
  ifM
    (readTVarIO $ dbClosed db)
    (void $ connectPool db False)
    (putStrLn "reopenDBStore: already opened")

-- not used with postgres client (used for ExecAgentStoreSQL, ExecChatStoreSQL)
execSQL :: PSQL.Connection -> Text -> IO [Text]
execSQL _db _query = throwIO (userError "not implemented")
