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
    RetryAfter (..),
    newDBStorePool,
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
    withTransactionIsolation,
    withRetriedTransaction,
    withRetriedTransactionPriority,
    isTransactionConflict,
    abortsTransaction,
    withSavepoint,
  )
where

import Control.Logger.Simple (logError, logWarn)
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
import Simplex.Messaging.Util (ifM, isAsyncCancellation, tshow)

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
    r <- restore (action conn) `E.catch` reset conn
    atomically $ writeTBQueue dbPoolConns conn
    pure r
  where
    reset conn e = do
      (conn', e') <- E.try dbConnect >>= \case
        Right conn' -> PSQL.close conn >> pure (conn', e)
        Left e' -> pure (conn, if isAsyncCancellation e' && not (isAsyncCancellation e) then e' else e)
      atomically $ writeTBQueue dbPoolConns conn'
      E.throwIO e'

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

-- isolation for agent transactions; postgresql-simple is not a dependency of SQLite builds
data IsolationLevel = ReadCommitted | RepeatableRead

data RetryAfter = RetryAfter (IO ()) String

instance Show RetryAfter where
  show (RetryAfter _ reason) = reason

instance E.Exception RetryAfter

withTransactionIsolation :: DBStore -> IsolationLevel -> (PSQL.Connection -> IO a) -> IO a
withTransactionIsolation st isolation action = withConnection st $ transaction (3 :: Int)
  where
    transaction n conn
      | n > 0 =
          E.try (inTransaction conn $ action conn) >>= \case
            Right r -> pure r
            Left e@(RetryAfter prepare _) -> do
              logError $ "transaction rolled back after " <> tshow e
              inTransaction conn prepare
              transaction (n - 1) conn
      | otherwise = inTransaction conn $ action conn
    inTransaction conn = retryTransaction 3 . PSQL.withTransactionLevel level conn
    level = case isolation of
      ReadCommitted -> PSQL.ReadCommitted
      RepeatableRead -> PSQL.RepeatableRead

withRetriedTransaction :: DBStore -> (PSQL.Connection -> IO a) -> IO a
withRetriedTransaction st = withRetriedTransactionPriority st False
{-# INLINE withRetriedTransaction #-}

withRetriedTransactionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withRetriedTransactionPriority st priority action = withConnectionPriority st priority transaction
  where
    transaction conn = retryTransaction 3 $ PSQL.withTransaction conn $ action conn

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

abortsTransaction :: E.SomeException -> Bool
abortsTransaction e = case E.fromException e of
  Just (_ :: PSQL.SqlError) -> True
  Nothing -> False

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
