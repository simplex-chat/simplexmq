{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230701_snd_msg_hashes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230701_snd_msg_hashes :: Query
m20230701_snd_msg_hashes =
  [sql|
CREATE TABLE snd_msg_hashes(
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  internal_snd_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  hash BLOB NOT NULL,
  rcpt_internal_rcv_id INTEGER, -- internal rcv ID of receipt message
  rcpt_internal_id INTEGER, -- internal ID of receipt message
  rcpt_msg_hash_ok INTEGER NOT NULL DEFAULT 0, -- integrity of receipt message
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY(conn_id, internal_snd_id),
  FOREIGN KEY(conn_id, rcpt_internal_rcv_id) REFERENCES rcv_messages(conn_id, internal_rcv_id) ON DELETE CASCADE,
  FOREIGN KEY(conn_id, rcpt_internal_id) REFERENCES messages(conn_id, internal_id) ON DELETE CASCADE
);

CREATE INDEX idx_snd_msg_hashes_conn_id ON snd_msg_hashes(conn_id);
CREATE INDEX idx_snd_msg_hashes_hash ON snd_msg_hashes(conn_id, hash);
CREATE INDEX idx_snd_msg_hashes_receipt_internal_rcv_id ON snd_msg_hashes(conn_id, rcpt_internal_rcv_id);
CREATE INDEX idx_snd_msg_hashes_receipt_internal_id ON snd_msg_hashes(conn_id, rcpt_internal_id);
|]

down_m20230701_snd_msg_hashes :: Query
down_m20230701_snd_msg_hashes =
  [sql|
DROP INDEX idx_snd_msg_hashes_conn_id;
DROP INDEX idx_snd_msg_hashes_hash;
DROP INDEX idx_snd_msg_hashes_receipt_internal_rcv_id;
DROP INDEX idx_snd_msg_hashes_receipt_internal_id;

DROP TABLE snd_msg_hashes;
|]
