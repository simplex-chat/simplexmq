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
    dbPoolSize :: Int,
    dbPool :: TBQueue PSQL.Connection,
    -- MVar is needed for fair pool distribution, without STM retry contention.
    -- Only one thread can be blocked on STM read.
    dbSem :: MVar (),
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

withConnectionPriority :: DBStore -> Bool -> (PSQL.Connection -> IO a) -> IO a
withConnectionPriority DBStore {dbPool, dbSem} _priority =
  bracket
    (withMVar dbSem $ \_ -> atomically $ readTBQueue dbPool)
    (atomically . writeTBQueue dbPool)

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
