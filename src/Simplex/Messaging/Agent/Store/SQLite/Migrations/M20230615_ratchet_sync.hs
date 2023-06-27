{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230615_ratchet_sync where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- Ratchet public keys are saved when ratchet re-synchronization is started - upon receiving other party's public keys,
-- keys are compared to determine ratchet initialization ordering for both parties.
-- This solves a possible race when both parties start ratchet re-synchronization at the same time.
m20230615_ratchet_sync :: Query
m20230615_ratchet_sync =
  [sql|
ALTER TABLE connections ADD COLUMN ratchet_sync_state TEXT NOT NULL DEFAULT 'ok';

ALTER TABLE ratchets ADD COLUMN x3dh_pub_key_1 BLOB;
ALTER TABLE ratchets ADD COLUMN x3dh_pub_key_2 BLOB;

CREATE TABLE processed_ratchet_key_hashes(
  processed_ratchet_key_hash_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
|]

down_m20230615_ratchet_sync :: Query
down_m20230615_ratchet_sync =
  [sql|
DROP INDEX idx_processed_ratchet_key_hashes_hash;

DROP TABLE processed_ratchet_key_hashes;

ALTER TABLE ratchets DROP COLUMN x3dh_pub_key_2;
ALTER TABLE ratchets DROP COLUMN x3dh_pub_key_1;

ALTER TABLE connections DROP COLUMN ratchet_sync_state;
|]
