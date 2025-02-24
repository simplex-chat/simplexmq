{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.Postgres.Common
  ( DBStore (..),
    DBOpts (..),
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
    connectDB_,
    doesSchemaExist,
  )
where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, onException, throwIO)
import Control.Logger.Simple
import Control.Monad (void, unless, when)
import Data.ByteString (ByteString)
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Database.PostgreSQL.Simple.Types (Query (..))
import qualified Data.Text as T
import Numeric.Natural
import Simplex.Messaging.Util (safeDecodeUtf8, tryWriteTBQueue, whenM)

-- TODO [postgres] use log_min_duration_statement instead of custom slow queries (SQLite's Connection type)
data DBStore = DBStore
  { dbConnstr :: ByteString,
    dbSchema :: ByteString,
    dbPoolSize :: Natural,
    dbConnCount :: MVar Natural,
    dbPool :: TBQueue PSQL.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

data DBOpts = DBOpts
  { connstr :: ByteString,
    schema :: ByteString,
    poolSize :: Natural,
    createSchema :: Bool
  }
  deriving (Show)

takeConnection :: DBStore -> IO PSQL.Connection
takeConnection DBStore {dbConnstr, dbSchema, dbPoolSize, dbConnCount, dbPool, dbClosed} = do
  whenM (readTVarIO dbClosed) $ throwIO $ userError "takeConnection: database store is closed" 
  atomically (tryReadTBQueue dbPool) >>= \case
    Just conn -> pure conn
    Nothing ->
      modifyMVar dbConnCount $ \n ->
        if n < dbPoolSize
          then (n + 1,) . fst <$> connectDB_ dbConnstr dbSchema False
          else (n,) <$> atomically (readTBQueue dbPool)

putConnection :: DBStore -> PSQL.Connection -> IO ()
putConnection DBStore {dbPool} conn = do
  ok <- atomically $ tryWriteTBQueue dbPool conn
  unless ok $ PSQL.close conn

connectDB_ :: ByteString -> ByteString -> Bool -> IO (PSQL.Connection, Bool)
connectDB_ connstr schema createSchema = do
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
            let err = "schema " <> safeDecodeUtf8 schema <> " does not exist."
            logError $ "connectPostgresStore: " <> err
            throwIO $ userError $ T.unpack err
      void $ PSQL.execute_ db $ Query $ "SET search_path TO " <> schema
      pure dbNew

doesSchemaExist :: PSQL.Connection -> ByteString -> IO Bool
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

-- TODO [postgres] connection pool
withConnectionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withConnectionPriority db _priority = bracket (takeConnection db) (putConnection db)
{-# INLINE withConnectionPriority #-}

withConnection :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withConnection st = withConnectionPriority st False
{-# INLINE withConnection #-}

withConnection' :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withConnection' = withConnection
{-# INLINE withConnection' #-}

withTransaction' :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withTransaction' = withTransaction
{-# INLINE withTransaction' #-}

withTransaction :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withTransaction st = withTransactionPriority st False
{-# INLINE withTransaction #-}

-- TODO [postgres] analogue for dbBusyLoop?
withTransactionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withTransactionPriority st priority action = withConnectionPriority st priority transaction
  where
    transaction conn = PSQL.withTransaction conn $ action conn
