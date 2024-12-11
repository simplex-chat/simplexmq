{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( createSQLiteStore,
    connectSQLiteStore,
    closeSQLiteStore,
    openSQLiteStore,
    reopenSQLiteStore,
    sqlString,
    keyString,
    storeKey,
    execSQL,
    upMigration, -- used in tests
  )
where

import Control.Monad
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.Char (toLower)
import Data.Functor (($>))
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Query (..))
import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.QQ (sql)
import qualified Database.SQLite3 as SQLite3
import Simplex.Messaging.Agent.Store.Migrations (mtrErrorDescription)
import Simplex.Messaging.Agent.Store.Migrations.Shared (Migration (..), MigrationsToRun (..))
import Simplex.Messaging.Agent.Store.SQLite.Common
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Agent.Store.Shared
import Simplex.Messaging.Util (ifM, safeDecodeUtf8)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import UnliftIO.Exception (bracketOnError, onException)
import UnliftIO.MVar
import UnliftIO.STM

-- * SQLite Store implementation

createSQLiteStore :: FilePath -> ScrubbedBytes -> Bool -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError SQLiteStore)
createSQLiteStore dbFilePath dbKey keepKey migrations confirmMigrations = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing True dbDir
  st <- connectSQLiteStore dbFilePath dbKey keepKey
  r <- migrateSchema st migrations confirmMigrations `onException` closeSQLiteStore st
  case r of
    Right () -> pure $ Right st
    Left e -> closeSQLiteStore st $> Left e

migrateSchema :: SQLiteStore -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError ())
migrateSchema st migrations confirmMigrations = do
  Migrations.initialize st
  Migrations.get st migrations >>= \case
    Left e -> do
      when (confirmMigrations == MCConsole) $ confirmOrExit ("Database state error: " <> mtrErrorDescription e)
      pure . Left $ MigrationError e
    Right MTRNone -> pure $ Right ()
    Right ms@(MTRUp ums)
      | dbNew st -> Migrations.run st ms $> Right ()
      | otherwise -> case confirmMigrations of
          MCYesUp -> run ms
          MCYesUpDown -> run ms
          MCConsole -> confirm err >> run ms
          MCError -> pure $ Left err
      where
        err = MEUpgrade $ map upMigration ums -- "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map name ums)
    Right ms@(MTRDown dms) -> case confirmMigrations of
      MCYesUpDown -> run ms
      MCConsole -> confirm err >> run ms
      MCYesUp -> pure $ Left err
      MCError -> pure $ Left err
      where
        err = MEDowngrade $ map downName dms
  where
    confirm err = confirmOrExit $ migrationErrorDescription err
    run ms = do
      let f = dbFilePath st
      copyFile f (f <> ".bak")
      Migrations.run st ms
      pure $ Right ()

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

connectSQLiteStore :: FilePath -> ScrubbedBytes -> Bool -> IO SQLiteStore
connectSQLiteStore dbFilePath key keepKey = do
  dbNew <- not <$> doesFileExist dbFilePath
  dbConn <- dbBusyLoop (connectDB dbFilePath key)
  dbConnection <- newMVar dbConn
  dbKey <- newTVarIO $! storeKey key keepKey
  dbClosed <- newTVarIO False
  dbSem <- newTVarIO 0
  pure SQLiteStore {dbFilePath, dbKey, dbSem, dbConnection, dbNew, dbClosed}

connectDB :: FilePath -> ScrubbedBytes -> IO DB.Connection
connectDB path key = do
  db <- DB.open path
  prepare db `onException` DB.close db
  -- _printPragmas db path
  pure db
  where
    prepare db = do
      let exec = SQLite3.exec $ SQL.connectionHandle $ DB.conn db
      unless (BA.null key) . exec $ "PRAGMA key = " <> keyString key <> ";"
      exec . fromQuery $
        [sql|
          PRAGMA busy_timeout = 100;
          PRAGMA foreign_keys = ON;
          -- PRAGMA trusted_schema = OFF;
          PRAGMA secure_delete = ON;
          PRAGMA auto_vacuum = FULL;
        |]

closeSQLiteStore :: SQLiteStore -> IO ()
closeSQLiteStore st@SQLiteStore {dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeSQLiteStore: already closed") $
    withConnection st $ \conn -> do
      DB.close conn
      atomically $ writeTVar dbClosed True

openSQLiteStore :: SQLiteStore -> ScrubbedBytes -> Bool -> IO ()
openSQLiteStore st@SQLiteStore {dbClosed} key keepKey =
  ifM (readTVarIO dbClosed) (openSQLiteStore_ st key keepKey) (putStrLn "openSQLiteStore: already opened")

openSQLiteStore_ :: SQLiteStore -> ScrubbedBytes -> Bool -> IO ()
openSQLiteStore_ SQLiteStore {dbConnection, dbFilePath, dbKey, dbClosed} key keepKey =
  bracketOnError
    (takeMVar dbConnection)
    (tryPutMVar dbConnection)
    $ \DB.Connection {slow} -> do
      DB.Connection {conn} <- connectDB dbFilePath key
      atomically $ do
        writeTVar dbClosed False
        writeTVar dbKey $! storeKey key keepKey
      putMVar dbConnection DB.Connection {conn, slow}

reopenSQLiteStore :: SQLiteStore -> IO ()
reopenSQLiteStore st@SQLiteStore {dbKey, dbClosed} =
  ifM (readTVarIO dbClosed) open (putStrLn "reopenSQLiteStore: already opened")
  where
    open =
      readTVarIO dbKey >>= \case
        Just key -> openSQLiteStore_ st key True
        Nothing -> fail "reopenSQLiteStore: no key"

keyString :: ScrubbedBytes -> Text
keyString = sqlString . safeDecodeUtf8 . BA.convert

sqlString :: Text -> Text
sqlString s = quote <> T.replace quote "''" s <> quote
  where
    quote = "'"

-- _printPragmas :: DB.Connection -> FilePath -> IO ()
-- _printPragmas db path = do
--   foreign_keys <- DB.query_ db "PRAGMA foreign_keys;" :: IO [[Int]]
--   print $ path <> " foreign_keys: " <> show foreign_keys
--   -- when run via sqlite-simple query for trusted_schema seems to return empty list
--   trusted_schema <- DB.query_ db "PRAGMA trusted_schema;" :: IO [[Int]]
--   print $ path <> " trusted_schema: " <> show trusted_schema
--   secure_delete <- DB.query_ db "PRAGMA secure_delete;" :: IO [[Int]]
--   print $ path <> " secure_delete: " <> show secure_delete
--   auto_vacuum <- DB.query_ db "PRAGMA auto_vacuum;" :: IO [[Int]]
--   print $ path <> " auto_vacuum: " <> show auto_vacuum

execSQL :: DB.Connection -> Text -> IO [Text]
execSQL db query = do
  rs <- newIORef []
  SQLite3.execWithCallback (SQL.connectionHandle $ DB.conn db) query (addSQLResultRow rs)
  reverse <$> readIORef rs

addSQLResultRow :: IORef [Text] -> SQLite3.ColumnIndex -> [Text] -> [Maybe Text] -> IO ()
addSQLResultRow rs _count names values = modifyIORef' rs $ \case
  [] -> [showValues values, T.intercalate "|" names]
  rs' -> showValues values : rs'
  where
    showValues = T.intercalate "|" . map (fromMaybe "")
