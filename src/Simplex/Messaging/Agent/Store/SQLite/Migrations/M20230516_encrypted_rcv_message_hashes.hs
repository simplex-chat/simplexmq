{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230516_encrypted_rcv_message_hashes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230516_encrypted_rcv_message_hashes :: Query
m20230516_encrypted_rcv_message_hashes =
  [sql|
CREATE TABLE encrypted_rcv_message_hashes(
  encrypted_rcv_message_hash_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_encrypted_rcv_message_hashes_hash ON encrypted_rcv_message_hashes(conn_id, hash);
|]

down_m20230516_encrypted_rcv_message_hashes :: Query
down_m20230516_encrypted_rcv_message_hashes =
  [sql|
DROP INDEX idx_encrypted_rcv_message_hashes_hash;

DROP TABLE encrypted_rcv_message_hashes;
|]
