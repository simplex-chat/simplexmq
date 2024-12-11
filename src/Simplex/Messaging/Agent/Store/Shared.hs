{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Messaging.Agent.Store.Shared
  ( MigrationConfirmation (..),
    MigrationError (..),
    UpMigration (..),
    migrationErrorDescription,
    upMigration, -- used in tests
  )
where

import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.List (intercalate)
import Data.Maybe (isJust)
import Simplex.Messaging.Agent.Store.Migrations (MTRError (..), Migration (..), mtrErrorDescription)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, sumTypeJSON)

data MigrationError
  = MEUpgrade {upMigrations :: [UpMigration]}
  | MEDowngrade {downMigrations :: [String]}
  | MigrationError {mtrError :: MTRError}
  deriving (Eq, Show)

migrationErrorDescription :: MigrationError -> String
migrationErrorDescription = \case
  MEUpgrade ums ->
    "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map upName ums)
  MEDowngrade dms ->
    "Database version is newer than the app.\nConfirm to back up and downgrade using these migrations: " <> intercalate ", " dms
  MigrationError err -> mtrErrorDescription err

data UpMigration = UpMigration {upName :: String, withDown :: Bool}
  deriving (Eq, Show)

upMigration :: Migration -> UpMigration
upMigration Migration {name, down} = UpMigration name $ isJust down

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

$(J.deriveJSON defaultJSON ''UpMigration)

$(J.deriveToJSON (sumTypeJSON $ dropPrefix "ME") ''MigrationError)
