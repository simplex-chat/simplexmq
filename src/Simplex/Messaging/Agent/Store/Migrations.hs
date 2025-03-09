{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.Store.Migrations
  ( Migration (..),
    MigrationsToRun (..),
    DownMigration (..),
    DBMigrate (..),
    sharedMigrateSchema,
    -- for tests
    migrationsToRun,
    toDownMigration,
  )
where

import Control.Monad
import Data.Char (toLower)
import Data.Functor (($>))
import Data.Maybe (isNothing, mapMaybe)
import Simplex.Messaging.Agent.Store.Shared
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

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

data DBMigrate = DBMigrate
  { initialize :: IO (),
    getCurrent :: IO [Migration],
    run :: MigrationsToRun -> IO (),
    backup :: IO ()
  }

sharedMigrateSchema :: DBMigrate -> Bool -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError ())
sharedMigrateSchema dbm dbNew' migrations confirmMigrations = do
  initialize dbm
  currentMs <- getCurrent dbm
  case migrationsToRun migrations currentMs of
    Left e -> do
      when (confirmMigrations == MCConsole) $ confirmOrExit ("Database state error: " <> mtrErrorDescription e)
      pure . Left $ MigrationError e
    Right MTRNone -> pure $ Right ()
    Right ms@(MTRUp ums)
      | dbNew' -> run dbm ms $> Right ()
      | otherwise -> case confirmMigrations of
          MCYesUp -> runWithBackup ms
          MCYesUpDown -> runWithBackup ms
          MCConsole -> confirm err >> runWithBackup ms
          MCError -> pure $ Left err
      where
        err = MEUpgrade $ map upMigration ums -- "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map name ums)
    Right ms@(MTRDown dms) -> case confirmMigrations of
      MCYesUpDown -> runWithBackup ms
      MCConsole -> confirm err >> runWithBackup ms
      MCYesUp -> pure $ Left err
      MCError -> pure $ Left err
      where
        err = MEDowngrade $ map downName dms
  where
    runWithBackup ms = backup dbm >> run dbm ms $> Right ()
    confirm err = confirmOrExit $ migrationErrorDescription err

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure
