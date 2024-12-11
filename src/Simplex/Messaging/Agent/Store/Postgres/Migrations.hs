{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations
  ( app,
    getCurrent,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as DB
import Simplex.Messaging.Agent.Store.Migrations.Shared
import Simplex.Messaging.Agent.Store.Postgres.Migrations.M20241210_initial

schemaMigrations :: [(String, Text, Maybe Text)]
schemaMigrations =
  [ ("20241210_initial", m20241210_initial, Nothing)
  ]

-- | The list of migrations in ascending order by date
app :: [Migration]
app = sortOn name $ map migration schemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

getCurrent :: DB.Connection -> IO [Migration]
getCurrent db = map toMigration <$> DB.query_ db "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    toMigration (name, down) = Migration {name, up = T.pack "", down}

-- TODO [postgres] run

-- TODO [postgres] initialize
