{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260712_address_dr where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260712_address_dr :: Query
m20260712_address_dr =
  [sql|
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BLOB NOT NULL,
  x3dh_priv_key_1 BLOB NOT NULL,
  x3dh_priv_key_2 BLOB NOT NULL,
  pq_priv_kem BLOB,
  created_at TEXT NOT NULL
) STRICT;

CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);
  |]

down_m20260712_address_dr :: Query
down_m20260712_address_dr =
  [sql|
DROP INDEX idx_address_ratchet_keys;
DROP TABLE address_ratchet_keys;
  |]
