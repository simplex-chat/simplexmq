{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Store.Shared
  ( Migration (..),
    MigrationsToRun (..),
    DownMigration (..),
    MTRError (..),
    mtrErrorDescription,
    MigrationConfig (..),
    MigrationConfirmation (..),
    MigrationError (..),
    UpMigration (..),
    migrationErrorDescription,
    -- for tests
    toDownMigration,
    upMigration,
  )
where

import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.List (intercalate)
import Data.Maybe (isJust)
import Data.Text (Text)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, sumTypeJSON)

data Migration = Migration {name :: String, up :: Text, down :: Maybe Text}
  deriving (Eq, Show)

data DownMigration = DownMigration {downName :: String, downQuery :: Text}
  deriving (Eq, Show)

toDownMigration :: Migration -> Maybe DownMigration
toDownMigration Migration {name, down} = DownMigration name <$> down

data MigrationsToRun = MTRUp [Migration] | MTRDown [DownMigration] | MTRNone
  deriving (Eq, Show)

data MTRError
  = MTRENoDown {dbMigrations :: [String]}
  | MTREDifferent {appMigration :: String, dbMigration :: String}
  deriving (Eq, Show)

mtrErrorDescription :: MTRError -> String
mtrErrorDescription = \case
  MTRENoDown ms -> "database version is newer than the app, but no down migration for: " <> intercalate ", " ms
  MTREDifferent a d -> "different migration in the app/database: " <> a <> " / " <> d

data MigrationError
  = MEUpgrade {upMigrations :: [UpMigration]}
  | MEDowngrade {downMigrations :: [String]}
  | MigrationError {mtrError :: MTRError}
  deriving (Eq, Show)

migrationErrorDescription :: Bool -> MigrationError -> String
migrationErrorDescription withBackup = \case
  MEUpgrade ums ->
    "The app has a newer version than the database.\nConfirm to " <> backupStr <> "upgrade using these migrations: " <> intercalate ", " (map upName ums)
  MEDowngrade dms ->
    "Database version is newer than the app.\nConfirm to " <> backupStr <> "downgrade using these migrations: " <> intercalate ", " dms
  MigrationError err -> mtrErrorDescription err
  where
    backupStr = if withBackup then "back up and " else ""

data UpMigration = UpMigration {upName :: String, withDown :: Bool}
  deriving (Eq, Show)

upMigration :: Migration -> UpMigration
upMigration Migration {name, down} = UpMigration name $ isJust down

data MigrationConfig = MigrationConfig
  { confirm :: MigrationConfirmation,
    backupPath :: Maybe FilePath -- Nothing - no backup, empty string - the same folder
  }

data MigrationConfirmation = MCYesUp | MCYesUpDown | MCConsole | MCError
  deriving (Eq, Show)

instance StrEncoding MigrationConfirmation where
  strEncode = \case
    MCYesUp -> "yesUp"
    MCYesUpDown -> "yesUpDown"
    MCConsole -> "console"
    MCError -> "error"
  strP =
    A.takeByteString >>= \case
      "yesUp" -> pure MCYesUp
      "yesUpDown" -> pure MCYesUpDown
      "console" -> pure MCConsole
      "error" -> pure MCError
      _ -> fail "invalid MigrationConfirmation"

$(J.deriveJSON (sumTypeJSON $ dropPrefix "MTRE") ''MTRError)

$(J.deriveJSON defaultJSON ''UpMigration)

$(J.deriveToJSON (sumTypeJSON $ dropPrefix "ME") ''MigrationError)
