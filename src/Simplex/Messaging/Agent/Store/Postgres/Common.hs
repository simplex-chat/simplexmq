{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Agent.Store.Postgres.Common
  ( DBStore (..),
    DBStorePool (..),
    DBOpts (..),
    newDBStorePool,
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
  )
where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import qualified Database.PostgreSQL.Simple as PSQL
import Numeric.Natural (Natural)
import Simplex.Messaging.Agent.Store.Postgres.Options

-- TODO [postgres] use log_min_duration_statement instead of custom slow queries (SQLite's Connection type)
data DBStore = DBStore
  { dbConnstr :: ByteString,
    dbSchema :: ByteString,
    dbPoolSize :: Int,
    dbPriorityPool :: DBStorePool,
    dbPool :: DBStorePool,
    -- dbPoolSize :: Int,
    -- dbPool :: TBQueue PSQL.Connection,
    -- -- MVar is needed for fair pool distribution, without STM retry contention.
    -- -- Only one thread can be blocked on STM read.
    -- dbSem :: MVar (),
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

newDBStorePool :: Natural -> IO DBStorePool
newDBStorePool poolSize = do
  dbSem <- newMVar ()
  dbPoolConns <- newTBQueueIO poolSize
  pure DBStorePool {dbSem, dbPoolConns}

data DBStorePool = DBStorePool
  { dbPoolConns :: TBQueue PSQL.Connection,
    -- MVar is needed for fair pool distribution, without STM retry contention.
    -- Only one thread can be blocked on STM read.
    dbSem :: MVar ()
  }

withConnectionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withConnectionPriority DBStore {dbPriorityPool, dbPool} priority =
  withConnectionPool $ if priority then dbPriorityPool else dbPool
{-# INLINE withConnectionPriority #-}

withConnectionPool :: DBStorePool -> (PSQL.Connection -> IO a) -> IO a
withConnectionPool DBStorePool {dbPoolConns, dbSem} =
  bracket
    (withMVar dbSem $ \_ -> atomically $ readTBQueue dbPoolConns)
    (atomically . writeTBQueue dbPoolConns)

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
