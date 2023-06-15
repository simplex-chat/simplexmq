{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230615_ratchet_resync where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230615_ratchet_resync :: Query
m20230615_ratchet_resync =
  [sql|
ALTER TABLE connections ADD COLUMN ratchet_resync INTEGER NOT NULL DEFAULT 0;
|]

down_m20230615_ratchet_resync :: Query
down_m20230615_ratchet_resync =
  [sql|
ALTER TABLE connections DROP COLUMN ratchet_resync;
|]
