{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Store.Postgres.Common
  ( PostgresStore (..),
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
data PostgresStore = PostgresStore
  { dbConnectInfo :: Postgres.ConnectInfo,
    dbConnection :: MVar Postgres.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

-- TODO [postgres] semaphore / connection pool?
withConnectionPriority :: PostgresStore -> Bool -> (Postgres.Connection -> IO a) -> IO a
withConnectionPriority PostgresStore {dbConnection} _priority action =
  withMVar dbConnection action

withConnection :: PostgresStore -> (Postgres.Connection -> IO a) -> IO a
withConnection st = withConnectionPriority st False

withConnection' :: PostgresStore -> (Postgres.Connection -> IO a) -> IO a
withConnection' = withConnection

withTransaction' :: PostgresStore -> (Postgres.Connection -> IO a) -> IO a
withTransaction' = withTransaction

withTransaction :: PostgresStore -> (Postgres.Connection -> IO a) -> IO a
withTransaction st = withTransactionPriority st False
{-# INLINE withTransaction #-}

-- TODO [postgres] analogue for dbBusyLoop?
withTransactionPriority :: PostgresStore -> Bool -> (Postgres.Connection -> IO a) -> IO a
withTransactionPriority st priority action = withConnectionPriority st priority transaction
  where
    transaction conn = Postgres.withTransaction conn $ action conn
