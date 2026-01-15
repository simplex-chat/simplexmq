{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Common
  ( DBStore (..),
    DBOpts (..),
    SQLiteFuncDef (..),
    SQLiteFuncPtrs (..),
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionPriority,
    withSavepoint,
    dbBusyLoop,
    storeKey,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (retry)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Database.SQLite.Simple (SQLError)
import qualified Database.SQLite.Simple as SQL
import Database.SQLite3.Bindings
import Foreign.Ptr
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store.SQLite.Util
import Simplex.Messaging.Util (ifM, unlessM)
import qualified UnliftIO.Exception as E
import UnliftIO.MVar
import UnliftIO.STM

storeKey :: ScrubbedBytes -> Bool -> Maybe ScrubbedBytes
storeKey key keepKey = if keepKey || BA.null key then Just key else Nothing

data DBStore = DBStore
  { dbFilePath :: FilePath,
    dbFunctions :: [SQLiteFuncDef],
    dbKey :: TVar (Maybe ScrubbedBytes),
    dbSem :: TVar Int,
    dbConnection :: MVar DB.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

data DBOpts = DBOpts
  { dbFilePath :: FilePath,
    dbFunctions :: [SQLiteFuncDef],
    dbKey :: ScrubbedBytes,
    keepKey :: Bool,
    vacuum :: Bool,
    track :: DB.TrackQueries
  }

-- e.g. `SQLiteFuncDef "func_name" 2 (SQLiteFuncPtr True func)`
-- or   `SQLiteFuncDef "aggr_name" 3 (SQLiteAggrPtrs step final)`
data SQLiteFuncDef = SQLiteFuncDef
  { funcName :: ByteString,
    argCount :: CArgCount,
    funcPtrs :: SQLiteFuncPtrs
  }

data SQLiteFuncPtrs
  = SQLiteFuncPtr {deterministic :: Bool, funcPtr :: FunPtr SQLiteFunc}
  | SQLiteAggrPtrs {stepPtr :: FunPtr SQLiteFunc, finalPtr :: FunPtr SQLiteFuncFinal}

withConnectionPriority :: DBStore -> Bool -> (DB.Connection -> IO a) -> IO a
withConnectionPriority DBStore {dbSem, dbConnection} priority action
  | priority = E.bracket_ signal release $ withMVar dbConnection action
  | otherwise = lowPriority
  where
    lowPriority = wait >> withMVar dbConnection (\db -> ifM free (Just <$> action db) (pure Nothing)) >>= maybe lowPriority pure
    signal = atomically $ modifyTVar' dbSem (+ 1)
    release = atomically $ modifyTVar' dbSem $ \sem -> if sem > 0 then sem - 1 else 0
    wait = unlessM free $ atomically $ unlessM ((0 ==) <$> readTVar dbSem) retry
    free = (0 ==) <$> readTVarIO dbSem

withConnection :: DBStore -> (DB.Connection -> IO a) -> IO a
withConnection st = withConnectionPriority st False

withConnection' :: DBStore -> (SQL.Connection -> IO a) -> IO a
withConnection' st action = withConnection st $ action . DB.conn

withTransaction' :: DBStore -> (SQL.Connection -> IO a) -> IO a
withTransaction' st action = withTransaction st $ action . DB.conn

withTransaction :: DBStore -> (DB.Connection -> IO a) -> IO a
withTransaction st = withTransactionPriority st False
{-# INLINE withTransaction #-}

withTransactionPriority :: DBStore -> Bool -> (DB.Connection -> IO a) -> IO a
withTransactionPriority st priority action = withConnectionPriority st priority $ dbBusyLoop . transaction
  where
    transaction db@DB.Connection {conn} = SQL.withImmediateTransaction conn $ action db

-- Execute an action within a savepoint (no-op for SQLite, just tries the action).
-- This provides a consistent interface with the PostgreSQL version.
withSavepoint :: DB.Connection -> SQL.Query -> IO a -> IO (Either SQLError a)
withSavepoint _ _ = E.try

dbBusyLoop :: forall a. IO a -> IO a
dbBusyLoop action = loop 500 3000000
  where
    loop :: Int -> Int -> IO a
    loop t tLim =
      action `E.catch` \(e :: SQLError) ->
        let se = SQL.sqlError e
         in if tLim > t && (se == SQL.ErrorBusy || se == SQL.ErrorLocked)
              then do
                threadDelay t
                loop (t * 9 `div` 8) (tLim - t)
              else E.throwIO e
