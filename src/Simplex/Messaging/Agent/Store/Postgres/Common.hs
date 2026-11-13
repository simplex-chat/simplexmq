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
    IsolationLevel (..),
    newDBStorePool,
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
    withTransactionIsolation,
    isTransactionConflict,
    withSavepoint,
  )
where

import Control.Logger.Simple (logWarn)
import Control.Monad (void)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import qualified Control.Exception as E
import Data.Bitraversable (bimapM)
import Data.ByteString (ByteString)
import Data.Functor (($>))
import qualified Database.PostgreSQL.Simple as PSQL
import qualified Database.PostgreSQL.Simple.Transaction as PSQL
import Numeric.Natural (Natural)
import Simplex.Messaging.Agent.Store.Postgres.Options
import Simplex.Messaging.Util (ifM, tshow)

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
withConnectionPriority DBStore {dbPriorityPool, dbPool, dbConnect, dbClosed} priority =
  withConnectionPool (if priority then dbPriorityPool else dbPool) dbClosed dbConnect
{-# INLINE withConnectionPriority #-}

withConnectionPool :: DBStorePool -> TVar Bool -> IO PSQL.Connection -> (PSQL.Connection -> IO a) -> IO a
withConnectionPool DBStorePool {dbPoolConns, dbSem} dbClosed dbConnect action =
  E.mask $ \restore -> do
    conn <- withMVar dbSem $ \_ -> atomically $ ifM (readTVar dbClosed) (throwSTM $ userError "withConnection: database closed") (readTBQueue dbPoolConns)
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

data IsolationLevel = ReadCommitted | RepeatableRead

withTransactionIsolation :: DBStore -> IsolationLevel -> (PSQL.Connection -> IO a) -> IO a
withTransactionIsolation st isolation action = withConnection st transaction
  where
    transaction conn = retryTransaction 3 $ PSQL.withTransactionLevel level conn $ action conn
    level = case isolation of
      ReadCommitted -> PSQL.ReadCommitted
      RepeatableRead -> PSQL.RepeatableRead

retryTransaction :: Int -> IO a -> IO a
retryTransaction n transaction
  | n > 0 = E.tryJust conflict transaction >>= either retryAfter pure
  | otherwise = transaction
  where
    conflict e = if conflictState e then Just e else Nothing
    retryAfter e = do
      logWarn $ "transaction retried after " <> tshow e
      retryTransaction (n - 1) transaction

isTransactionConflict :: E.SomeException -> Bool
isTransactionConflict = maybe False conflictState . E.fromException

conflictState :: PSQL.SqlError -> Bool
conflictState = (`elem` ["40001", "40P01"]) . PSQL.sqlState

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
