{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Common
  ( SQLiteStore (..),
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionCtx,
    dbBusyLoop,
  )
where

import Control.Concurrent (threadDelay)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple (SQLError)
import qualified Database.SQLite.Simple as SQL
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Util (diffToMilliseconds)
import UnliftIO.Exception (bracket)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbEncrypted :: TVar Bool,
    dbConnection :: TMVar DB.Connection,
    dbClosed :: TVar Bool,
    dbNew :: Bool
  }

withConnection :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withConnection SQLiteStore {dbConnection} =
  bracket
    (atomically $ takeTMVar dbConnection)
    (atomically . putTMVar dbConnection)

withConnection' :: SQLiteStore -> (SQL.Connection -> IO a) -> IO a
withConnection' st action = withConnection st $ action . DB.conn

withTransaction :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withTransaction = withTransactionCtx Nothing

withTransaction' :: SQLiteStore -> (SQL.Connection -> IO a) -> IO a
withTransaction' st action = withTransaction st $ action . DB.conn

withTransactionCtx :: Maybe String -> SQLiteStore -> (DB.Connection -> IO a) -> IO a
withTransactionCtx ctx_ st action = withConnection st $ dbBusyLoop . transactionWithCtx
  where
    transactionWithCtx db@DB.Connection {conn} = case ctx_ of
      Nothing -> SQL.withImmediateTransaction conn $ action db
      Just ctx -> do
        t1 <- getCurrentTime
        r <- SQL.withImmediateTransaction conn $ action db
        t2 <- getCurrentTime
        putStrLn $ "withTransactionCtx start :: " <> show t1 <> " :: " <> ctx
        putStrLn $ "withTransactionCtx end   :: " <> show t2 <> " :: " <> ctx <> " :: duration=" <> show (diffToMilliseconds $ diffUTCTime t2 t1)
        pure r

dbBusyLoop :: forall a. IO a -> IO a
dbBusyLoop action = loop 500 3000000
  where
    loop :: Int -> Int -> IO a
    loop t tLim =
      action `E.catch` \(e :: SQLError) ->
        if tLim > t && SQL.sqlError e == SQL.ErrorBusy
          then do
            threadDelay t
            loop (t * 9 `div` 8) (tLim - t)
          else E.throwIO e
