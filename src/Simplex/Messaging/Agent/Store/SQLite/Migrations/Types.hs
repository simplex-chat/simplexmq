module Simplex.Messaging.Agent.Store.SQLite.Migrations.Types where

import Database.SQLite.Simple (Query)

data SchemaMigration = SchemaMigration
  { name :: String,
    up :: Query,
    down :: Query
  }
