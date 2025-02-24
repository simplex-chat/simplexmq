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
import Control.Exception (bracketOnError, finally, onException, throwIO)
import Control.Logger.Simple (logError)
import Control.Monad (void, unless, when)
import Data.ByteString (ByteString)
import Data.Functor (($>))
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.Types (Query (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.SqlQQ (sql)
import GHC.IO (catchAny)
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
  (dbConn, dbNew) <- connectDB connstr schema createSchema -- TODO [postgres] analogue for dbBusyLoop?
  dbConnCount <- newMVar 1
  dbPool <- newTBQueueIO poolSize
  dbClosed <- newTVarIO False
  pure DBStore {dbConnstr = connstr, dbSchema = schema, dbPoolSize = poolSize, dbConnCount, dbPool, dbNew, dbClosed}

connectDB :: ByteString -> ByteString -> Bool -> IO (DB.Connection, Bool)
connectDB connstr schema createSchema =
  connectDB_ connstr schema createSchema `catchAny` \e -> do
    putStrLn $ "connectPostgresStore error: " <> show e
    exitFailure

checkSchemaExists :: ByteString -> ByteString -> IO Bool
checkSchemaExists connstr schema = do
  db <- PSQL.connectPostgreSQL connstr
  doesSchemaExist db schema `finally` DB.close db

-- can share with SQLite
closeDBStore :: DBStore -> IO ()
closeDBStore st@DBStore {dbConnCount, dbPool, dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeDBStore: already closed") $ do
    atomically $ writeTVar dbClosed True
    closeConn
  where
    closeConn = do
      closed <-
        modifyMVar dbConnCount $ \case
          0 -> pure (0, True)
          n -> (n - 1, False) <$ (DB.close =<< atomically (readTBQueue dbPool))
      unless closed closeConn

openPostgresStore_ :: DBStore -> IO ()
openPostgresStore_ st@DBStore {dbClosed} = do
  atomically $ writeTVar dbClosed False
  withConnection st $ \_ -> pure ()

reopenDBStore :: DBStore -> IO ()
reopenDBStore st@DBStore {dbClosed} =
  ifM (readTVarIO dbClosed) open (putStrLn "reopenDBStore: already opened")
  where
    open = openPostgresStore_ st

-- not used with postgres client (used for ExecAgentStoreSQL, ExecChatStoreSQL)
execSQL :: PSQL.Connection -> Text -> IO [Text]
execSQL _db _query = throwIO (userError "not implemented")
