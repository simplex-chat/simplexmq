{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.App (appMigrations) where

import Data.List (sortOn)
import Data.Text (Text)
import Simplex.Messaging.Agent.Store.Postgres.Migrations.M20241210_initial
import Simplex.Messaging.Agent.Store.Postgres.Migrations.M20250203_msg_bodies
import Simplex.Messaging.Agent.Store.Shared (Migration (..))

schemaMigrations :: [(String, Text, Maybe Text)]
schemaMigrations =
  [ ("20241210_initial", m20241210_initial, Nothing),
    ("20250203_msg_bodies", m20250203_msg_bodies, Just down_m20250203_msg_bodies)
  ]

-- | The list of migrations in ascending order by date
appMigrations :: [Migration]
appMigrations = sortOn name $ map migration schemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}
