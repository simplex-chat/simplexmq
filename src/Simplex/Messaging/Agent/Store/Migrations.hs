{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.Store.Migrations
  ( Migration (..),
    MigrationsToRun (..),
    DownMigration (..),
    app,
    get,
    getCurrent,
    initialize,
    run,
    migrateSchema,
    -- for tests
    migrationsToRun,
    toDownMigration,
  )
where

import Control.Monad
import Data.Char (toLower)
import Data.Functor (($>))
import Data.Maybe (isNothing, mapMaybe)
import Simplex.Messaging.Agent.Store.Common
import Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Agent.Store.Shared
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
#if defined(dbPostgres)
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as PostgresMigrations
import Simplex.Messaging.Agent.Store.Postgres.Common (PostgresStore (..))
#else
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as SQLiteMigrations
import Simplex.Messaging.Agent.Store.SQLite.Common (SQLiteStore (..))
import Simplex.Messaging.Agent.Store.SQLite.DB (Connection (..))
import System.Directory (copyFile)
#endif

app :: [Migration]
#if defined(dbPostgres)
app = PostgresMigrations.app
#else
app = SQLiteMigrations.app
#endif

get :: DBStore -> [Migration] -> IO (Either MTRError MigrationsToRun)
get st migrations = migrationsToRun migrations <$> withTransaction st getCurrent

getCurrent :: DB.Connection -> IO [Migration]
#if defined(dbPostgres)
getCurrent = PostgresMigrations.getCurrent
#else
getCurrent = SQLiteMigrations.getCurrent . conn
#endif

initialize :: DBStore -> IO ()
#if defined(dbPostgres)
initialize = PostgresMigrations.initialize
#else
initialize = SQLiteMigrations.initialize
#endif

run :: DBStore -> MigrationsToRun -> IO ()
#if defined(dbPostgres)
run = PostgresMigrations.run
#else
run = SQLiteMigrations.run
#endif

migrationsToRun :: [Migration] -> [Migration] -> Either MTRError MigrationsToRun
migrationsToRun [] [] = Right MTRNone
migrationsToRun appMs [] = Right $ MTRUp appMs
migrationsToRun [] dbMs
  | length dms == length dbMs = Right $ MTRDown dms
  | otherwise = Left $ MTRENoDown $ mapMaybe nameNoDown dbMs
  where
    dms = mapMaybe toDownMigration dbMs
    nameNoDown m = if isNothing (down m) then Just $ name m else Nothing
migrationsToRun (a : as) (d : ds)
  | name a == name d = migrationsToRun as ds
  | otherwise = Left $ MTREDifferent (name a) (name d)

migrateSchema :: DBStore -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError ())
migrateSchema st migrations confirmMigrations = do
  initialize st
  get st migrations >>= \case
    Left e -> do
      when (confirmMigrations == MCConsole) $ confirmOrExit ("Database state error: " <> mtrErrorDescription e)
      pure . Left $ MigrationError e
    Right MTRNone -> pure $ Right ()
    Right ms@(MTRUp ums)
      | dbNew st -> run st ms $> Right ()
      | otherwise -> case confirmMigrations of
          MCYesUp -> runWithBackup st ms
          MCYesUpDown -> runWithBackup st ms
          MCConsole -> confirm err >> runWithBackup st ms
          MCError -> pure $ Left err
      where
        err = MEUpgrade $ map upMigration ums -- "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map name ums)
    Right ms@(MTRDown dms) -> case confirmMigrations of
      MCYesUpDown -> runWithBackup st ms
      MCConsole -> confirm err >> runWithBackup st ms
      MCYesUp -> pure $ Left err
      MCError -> pure $ Left err
      where
        err = MEDowngrade $ map downName dms
  where
    confirm err = confirmOrExit $ migrationErrorDescription err

-- TODO [postgres] backup?
runWithBackup :: DBStore -> MigrationsToRun -> IO (Either a ())
#if defined(dbPostgres)
runWithBackup st ms = run st ms $> Right ()
#else
runWithBackup st ms = do
  let f = dbFilePath st
  copyFile f (f <> ".bak")
  run st ms
  pure $ Right ()
#endif

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure
