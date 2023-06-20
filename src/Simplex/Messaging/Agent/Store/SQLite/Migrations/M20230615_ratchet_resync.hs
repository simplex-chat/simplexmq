{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230615_ratchet_resync where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- Ratchet public keys are saved when ratchet re-synchronization is started - upon receiving other party's public keys,
-- key hashes are compared to determine ratchet initialization ordering for both parties.
-- This solves a possible race when both parties start ratchet re-synchronization at the same time.
-- Public keys are deleted after initializing ratchet.
m20230615_ratchet_resync :: Query
m20230615_ratchet_resync =
  [sql|
ALTER TABLE connections ADD COLUMN ratchet_desync_state TEXT;
ALTER TABLE connections ADD COLUMN ratchet_resync_state TEXT;

ALTER TABLE ratchets ADD COLUMN x3dh_pub_key_1 BLOB;
ALTER TABLE ratchets ADD COLUMN x3dh_pub_key_2 BLOB;
|]

down_m20230615_ratchet_resync :: Query
down_m20230615_ratchet_resync =
  [sql|
ALTER TABLE ratchets DROP COLUMN x3dh_pub_key_2;
ALTER TABLE ratchets DROP COLUMN x3dh_pub_key_1;

ALTER TABLE connections DROP COLUMN ratchet_resync_state;
ALTER TABLE connections DROP COLUMN ratchet_desync_state;
|]
