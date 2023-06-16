{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230615_ratchet_resync where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230615_ratchet_resync :: Query
m20230615_ratchet_resync =
  [sql|
ALTER TABLE connections ADD COLUMN ratchet_desync_state TEXT;
ALTER TABLE connections ADD COLUMN ratchet_resync_state TEXT;
|]

down_m20230615_ratchet_resync :: Query
down_m20230615_ratchet_resync =
  [sql|
ALTER TABLE connections DROP COLUMN ratchet_resync_state;
ALTER TABLE connections DROP COLUMN ratchet_desync_state;
|]
