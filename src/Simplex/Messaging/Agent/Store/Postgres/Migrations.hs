{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations
  ( app,
    initialize,
    run,
    getCurrent,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as DB
import Simplex.Messaging.Agent.Store.Shared
import Simplex.Messaging.Agent.Store.Postgres.Common
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

-- TODO [postgres] initialize
initialize :: DBStore -> IO ()
initialize st = undefined

-- TODO [postgres] run
run :: DBStore -> MigrationsToRun -> IO ()
run st = undefined

getCurrent :: DB.Connection -> IO [Migration]
getCurrent db = map toMigration <$> DB.query_ db "SELECT name, down FROM migrations ORDER BY name ASC;"
  where
    toMigration (name, down) = Migration {name, up = T.pack "", down}
