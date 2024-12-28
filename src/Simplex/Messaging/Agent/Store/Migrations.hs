{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.Store.Migrations
  ( Migration (..),
    MigrationsToRun (..),
    DownMigration (..),
    Migrations.app,
    Migrations.getCurrent,
    get,
    Migrations.initialize,
    Migrations.run,
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
import Simplex.Messaging.Agent.Store.Shared
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
#if defined(dbPostgres)
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as Migrations
#else
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import System.Directory (copyFile)
#endif

get :: DBStore -> [Migration] -> IO (Either MTRError MigrationsToRun)
get st migrations = migrationsToRun migrations <$> withTransaction st Migrations.getCurrent

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

migrateSchema :: DBStore -> [Migration] -> MigrationConfirmation -> Bool -> IO (Either MigrationError ())
migrateSchema st migrations confirmMigrations vacuum = do
  Migrations.initialize st
  get st migrations >>= \case
    Left e -> do
      when (confirmMigrations == MCConsole) $ confirmOrExit ("Database state error: " <> mtrErrorDescription e)
      pure . Left $ MigrationError e
    Right MTRNone -> pure $ Right ()
    Right ms@(MTRUp ums)
      | dbNew st -> Migrations.run st vacuum ms $> Right ()
      | otherwise -> case confirmMigrations of
          MCYesUp -> runWithBackup st vacuum ms
          MCYesUpDown -> runWithBackup st vacuum ms
          MCConsole -> confirm err >> runWithBackup st vacuum ms
          MCError -> pure $ Left err
      where
        err = MEUpgrade $ map upMigration ums -- "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map name ums)
    Right ms@(MTRDown dms) -> case confirmMigrations of
      MCYesUpDown -> runWithBackup st vacuum ms
      MCConsole -> confirm err >> runWithBackup st vacuum ms
      MCYesUp -> pure $ Left err
      MCError -> pure $ Left err
      where
        err = MEDowngrade $ map downName dms
  where
    confirm err = confirmOrExit $ migrationErrorDescription err

runWithBackup :: DBStore -> Bool -> MigrationsToRun -> IO (Either a ())
#if defined(dbPostgres)
runWithBackup st vacuum ms = Migrations.run st vacuum ms $> Right ()
#else
runWithBackup st vacuum ms = do
  let f = dbFilePath st
  copyFile f (f <> ".bak")
  Migrations.run st vacuum ms
  pure $ Right ()
#endif

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure
