{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
    withSavepoint,
  )
where

import Control.Monad (void)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.Bitraversable (bimapM)
import Data.ByteString (ByteString)
import Data.Functor (($>))
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
    dbConnect :: IO PSQL.Connection,
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
withConnectionPriority DBStore {dbPriorityPool, dbPool, dbConnect} priority =
  withConnectionPool (if priority then dbPriorityPool else dbPool) dbConnect
{-# INLINE withConnectionPriority #-}

withConnectionPool :: DBStorePool -> IO PSQL.Connection -> (PSQL.Connection -> IO a) -> IO a
withConnectionPool DBStorePool {dbPoolConns, dbSem} dbConnect action =
  E.mask $ \restore -> do
    conn <- withMVar dbSem $ \_ -> atomically $ readTBQueue dbPoolConns
    r <- restore (action conn) `E.onException` reset conn
    atomically $ writeTBQueue dbPoolConns conn
    pure r
  where
    reset conn = do
      conn' <- E.try dbConnect >>= \case
        Right conn' -> PSQL.close conn >> pure conn'
        Left (_ :: E.SomeException) -> pure conn
      atomically $ writeTBQueue dbPoolConns conn'

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

-- Execute an action within a savepoint.
-- On success, releases the savepoint. On error, rolls back to the savepoint
-- to restore the transaction to a usable state before returning the error.
withSavepoint :: PSQL.Connection -> PSQL.Query -> IO a -> IO (Either PSQL.SqlError a)
withSavepoint db name action = do
  void $ PSQL.execute_ db $ "SAVEPOINT " <> name
  E.try action
    >>= bimapM
      (PSQL.execute_ db ("ROLLBACK TO SAVEPOINT " <> name) $>)
      (PSQL.execute_ db ("RELEASE SAVEPOINT " <> name) $>)
