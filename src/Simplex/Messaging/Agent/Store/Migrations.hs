{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Store.Migrations
  ( Migration (..),
    MigrationsToRun (..),
    MTRError (..),
    DownMigration (..),
    app,
    get,
    mtrErrorDescription,
    -- for tests
    migrationsToRun,
    toDownMigration,
  )
where

import qualified Data.Aeson.TH as J
import Data.Maybe (isNothing, mapMaybe)
import Data.List (intercalate)
import Simplex.Messaging.Agent.Store.Common
import Simplex.Messaging.Agent.Store.DB
import Simplex.Messaging.Agent.Store.Migrations.Shared
import Simplex.Messaging.Parsers (dropPrefix, sumTypeJSON)
#if defined(dbPostgres)
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as PostgresMigrations
#else
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as SQLiteMigrations
#endif

app :: [Migration]
#if defined(dbPostgres)
app = PostgresMigrations.app
#else
app = SQLiteMigrations.app
#endif

get :: DBStore -> [Migration] -> IO (Either MTRError MigrationsToRun)
get st migrations = migrationsToRun migrations <$> withTransaction' st getCurrent

getCurrent :: Connection -> IO [Migration]
#if defined(dbPostgres)
getCurrent = PostgresMigrations.getCurrent
#else
getCurrent = SQLiteMigrations.getCurrent
#endif

#if defined(dbPostgres)
#else
#endif

#if defined(dbPostgres)
#else
#endif

data MTRError
  = MTRENoDown {dbMigrations :: [String]}
  | MTREDifferent {appMigration :: String, dbMigration :: String}
  deriving (Eq, Show)

mtrErrorDescription :: MTRError -> String
mtrErrorDescription = \case
  MTRENoDown ms -> "database version is newer than the app, but no down migration for: " <> intercalate ", " ms
  MTREDifferent a d -> "different migration in the app/database: " <> a <> " / " <> d

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

$(J.deriveJSON (sumTypeJSON $ dropPrefix "MTRE") ''MTRError)
