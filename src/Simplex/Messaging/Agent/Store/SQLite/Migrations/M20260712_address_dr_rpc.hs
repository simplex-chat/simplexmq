{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260712_address_dr_rpc where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260712_address_dr_rpc :: Query
m20260712_address_dr_rpc =
  [sql|
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BLOB NOT NULL,
  x3dh_priv_key_1 BLOB NOT NULL,
  x3dh_priv_key_2 BLOB NOT NULL,
  pq_priv_kem BLOB,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
) STRICT;

CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);

ALTER TABLE conn_invitations ADD COLUMN service_request INTEGER NOT NULL DEFAULT 0; -- service side: received request is a service request (SREQ) not a contact request (REQ)
ALTER TABLE connections ADD COLUMN created_at TEXT NOT NULL DEFAULT('1970-01-01 00:00:00');
ALTER TABLE connections ADD COLUMN service_request_expires_at TEXT; -- client side: requester's outstanding service request; the time the client stops waiting for the response
  |]

down_m20260712_address_dr_rpc :: Query
down_m20260712_address_dr_rpc =
  [sql|
ALTER TABLE connections DROP COLUMN service_request_expires_at;
ALTER TABLE connections DROP COLUMN created_at;
ALTER TABLE conn_invitations DROP COLUMN service_request;
DROP INDEX idx_address_ratchet_keys;
DROP TABLE address_ratchet_keys;
  |]
