{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Common
  ( SQLiteStore (..),
    withConnection,
    withConnection',
    withTransaction,
    withTransaction',
    withTransactionCtx,
    sqlString,
  )
where

import Control.Monad
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, onException)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple (SQLError)
import qualified Database.SQLite.Simple as SQL
import qualified Database.SQLite3 as SQLite3
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Util (diffToMilliseconds)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbKey :: TVar String,
    dbConnection :: TMVar (Maybe SQL.Connection),
    dbSlowQueries :: TMap SQL.Query DB.SlowQueryStats,
    dbNew :: Bool
  }

withConnection :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withConnection SQLiteStore {dbConnection = conn, dbSlowQueries = slow, dbFilePath, dbKey} a =
  bracket
    (atomically (takeTMVar conn) >>= maybe (connectDB dbFilePath dbKey) pure)
    (atomically . putTMVar conn . Just)
    (a . (`DB.Connection` slow))

connectDB :: FilePath -> TVar String -> IO SQL.Connection
connectDB path dbKey = dbBusyLoop $ do
  db <- SQL.open path
  prepare db `onException` SQL.close db
  -- _printPragmas db path
  pure db
  where
    prepare db = do
      key <- readTVarIO dbKey
      let exec = SQLite3.exec $ SQL.connectionHandle db
      unless (null key) . exec $ "PRAGMA key = " <> sqlString key <> ";"
      exec
        "PRAGMA busy_timeout = 100;\n\
        \PRAGMA foreign_keys = ON;\n\
        \-- PRAGMA trusted_schema = OFF;\n\
        \PRAGMA secure_delete = ON;\n\
        \PRAGMA auto_vacuum = FULL;"

sqlString :: String -> Text
sqlString s = quote <> T.replace quote "''" (T.pack s) <> quote
  where
    quote = "'"

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
