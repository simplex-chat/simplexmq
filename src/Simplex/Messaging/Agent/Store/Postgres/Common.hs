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

import qualified Database.PostgreSQL.Simple as Postgres
import UnliftIO.MVar
import UnliftIO.STM

-- TODO [postgres] use log_min_duration_statement instead of custom slow queries (SQLite's Connection type)
data DBStore = DBStore
  { dbConnectInfo :: Postgres.ConnectInfo,
    dbConnection :: MVar Postgres.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

-- TODO [postgres] semaphore / connection pool?
withConnectionPriority :: DBStore -> Bool -> (Postgres.Connection -> IO a) -> IO a
withConnectionPriority DBStore {dbConnection} _priority action =
  withMVar dbConnection action

withConnection :: DBStore -> (Postgres.Connection -> IO a) -> IO a
withConnection st = withConnectionPriority st False

withConnection' :: DBStore -> (Postgres.Connection -> IO a) -> IO a
withConnection' = withConnection

withTransaction' :: DBStore -> (Postgres.Connection -> IO a) -> IO a
withTransaction' = withTransaction

withTransaction :: DBStore -> (Postgres.Connection -> IO a) -> IO a
withTransaction st = withTransactionPriority st False
{-# INLINE withTransaction #-}

-- TODO [postgres] analogue for dbBusyLoop?
withTransactionPriority :: DBStore -> Bool -> (Postgres.Connection -> IO a) -> IO a
withTransactionPriority st priority action = withConnectionPriority st priority transaction
  where
    transaction conn = Postgres.withTransaction conn $ action conn
