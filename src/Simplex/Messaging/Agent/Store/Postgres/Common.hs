{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Store.Postgres.Common
  ( DBStore (..),
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
  )
where

import qualified Database.PostgreSQL.Simple as PSQL
import UnliftIO.MVar
import UnliftIO.STM

-- TODO [postgres] use log_min_duration_statement instead of custom slow queries (SQLite's Connection type)
data DBStore = DBStore
  { dbConnectInfo :: PSQL.ConnectInfo,
    dbConnection :: MVar PSQL.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

-- TODO [postgres] connection pool
withConnectionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withConnectionPriority DBStore {dbConnection} _priority action =
  withMVar dbConnection action

withConnection :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withConnection st = withConnectionPriority st False

withConnection' :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withConnection' = withConnection

withTransaction' :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withTransaction' = withTransaction

withTransaction :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withTransaction st = withTransactionPriority st False
{-# INLINE withTransaction #-}

-- TODO [postgres] analogue for dbBusyLoop?
withTransactionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withTransactionPriority st priority action = withConnectionPriority st priority transaction
  where
    transaction conn = PSQL.withTransaction conn $ action conn
