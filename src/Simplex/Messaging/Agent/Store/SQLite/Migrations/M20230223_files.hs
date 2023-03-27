{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230223_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230223_files :: Query
m20230223_files =
  [sql|
CREATE TABLE xftp_servers (
  xftp_server_id INTEGER PRIMARY KEY,
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  xftp_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(xftp_host, xftp_port, xftp_key_hash)
);

CREATE TABLE rcv_files (
  rcv_file_id INTEGER PRIMARY KEY,
  rcv_file_entity_id BLOB NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  key BLOB NOT NULL,
  nonce BLOB NOT NULL,
  chunk_size INTEGER NOT NULL,
  prefix_path TEXT NOT NULL,
  tmp_path TEXT,
  save_path TEXT NOT NULL,
  status TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(rcv_file_entity_id)
);

CREATE INDEX idx_rcv_files_user_id ON rcv_files(user_id);

CREATE TABLE rcv_file_chunks (
  rcv_file_chunk_id INTEGER PRIMARY KEY,
  rcv_file_id INTEGER NOT NULL REFERENCES rcv_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  tmp_path TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_rcv_file_chunks_rcv_file_id ON rcv_file_chunks(rcv_file_id);

CREATE TABLE rcv_file_chunk_replicas (
  rcv_file_chunk_replica_id INTEGER PRIMARY KEY,
  rcv_file_chunk_id INTEGER NOT NULL REFERENCES rcv_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  received INTEGER NOT NULL DEFAULT 0,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_rcv_file_chunk_replicas_rcv_file_chunk_id ON rcv_file_chunk_replicas(rcv_file_chunk_id);
CREATE INDEX idx_rcv_file_chunk_replicas_xftp_server_id ON rcv_file_chunk_replicas(xftp_server_id);
|]

-- this is for tests, older versions do not support down migrations
down_m20230223_files :: Query
down_m20230223_files =
  [sql|
DROP INDEX idx_rcv_file_chunk_replicas_xftp_server_id;
DROP INDEX idx_rcv_file_chunk_replicas_rcv_file_chunk_id;
DROP TABLE rcv_file_chunk_replicas;

DROP INDEX idx_rcv_file_chunks_rcv_file_id;
DROP TABLE rcv_file_chunks;

DROP INDEX idx_rcv_files_user_id;
DROP TABLE rcv_files;

DROP TABLE xftp_servers;
|]
