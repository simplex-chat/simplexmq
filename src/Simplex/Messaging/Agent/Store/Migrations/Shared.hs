{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Store.Migrations.Shared
  ( Migration (..),
    MigrationsToRun (..),
    DownMigration (..),
    -- for tests
    toDownMigration
  )
where

import Data.Text (Text)

data Migration = Migration {name :: String, up :: Text, down :: Maybe Text}
  deriving (Eq, Show)

data DownMigration = DownMigration {downName :: String, downQuery :: Text}
  deriving (Eq, Show)

toDownMigration :: Migration -> Maybe DownMigration
toDownMigration Migration {name, down} = DownMigration name <$> down

data MigrationsToRun = MTRUp [Migration] | MTRDown [DownMigration] | MTRNone
  deriving (Eq, Show)
