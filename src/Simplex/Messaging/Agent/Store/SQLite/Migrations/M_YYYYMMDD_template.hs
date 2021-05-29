{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M_YYYYMMDD_template where

import Database.SQLite.Simple.QQ (sql)
import Simplex.Messaging.Agent.Store.SQLite.Migrations.Types (SchemaMigration (..))

{-# ANN module "HLint: ignore Use camelCase" #-}

m_YYYYMMDD_template :: SchemaMigration
m_YYYYMMDD_template =
  SchemaMigration
    { name = "YYYYMMDD_template",
      up =
        [sql|
          ALTER TABLE table 
          ADD COLUMN field TEXT NOT NULL;
        |],
      down =
        [sql|
          ALTER TABLE table 
          DROP COLUMN field;
        |]
    }
