{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230401_snd_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230401_snd_files :: Query
m20230401_snd_files =
  [sql|
CREATE TABLE snd_files (
  snd_file_id INTEGER PRIMARY KEY,
  snd_file_entity_id BLOB NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  num_recipients INTEGER NOT NULL,
  digest BLOB,
  key BLOB NOT NUll,
  nonce BLOB NOT NUll,
  path TEXT NOT NULL,
  prefix_path TEXT,
  status TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_files_user_id ON snd_files(user_id);

CREATE TABLE snd_file_chunks (
  snd_file_chunk_id INTEGER PRIMARY KEY,
  snd_file_id INTEGER NOT NULL REFERENCES snd_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_offset INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_file_chunks_snd_file_id ON snd_file_chunks(snd_file_id);

CREATE TABLE snd_file_chunk_replicas (
  snd_file_chunk_replica_id INTEGER PRIMARY KEY,
  snd_file_chunk_id INTEGER NOT NULL REFERENCES snd_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  replica_status TEXT NOT NULL,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_file_chunk_replicas_snd_file_chunk_id ON snd_file_chunk_replicas(snd_file_chunk_id);
CREATE INDEX idx_snd_file_chunk_replicas_xftp_server_id ON snd_file_chunk_replicas(xftp_server_id);

CREATE TABLE snd_file_chunk_replica_recipients (
  snd_file_chunk_replica_recipient_id INTEGER PRIMARY KEY,
  snd_file_chunk_replica_id INTEGER NOT NULL REFERENCES snd_file_chunk_replicas ON DELETE CASCADE,
  rcv_replica_id BLOB NOT NULL,
  rcv_replica_key BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_file_chunk_replica_recipients_snd_file_chunk_replica_id ON snd_file_chunk_replica_recipients(snd_file_chunk_replica_id);

CREATE TABLE deleted_snd_chunk_replicas (
  deleted_snd_chunk_replica_id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  chunk_digest BLOB NOT NULL,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_deleted_snd_chunk_replicas_user_id ON deleted_snd_chunk_replicas(user_id);
CREATE INDEX idx_deleted_snd_chunk_replicas_xftp_server_id ON deleted_snd_chunk_replicas(xftp_server_id);
|]

down_m20230401_snd_files :: Query
down_m20230401_snd_files =
  [sql|
DROP INDEX idx_deleted_snd_chunk_replicas_xftp_server_id;
DROP INDEX idx_deleted_snd_chunk_replicas_user_id;
DROP TABLE deleted_snd_chunk_replicas;

DROP INDEX idx_snd_file_chunk_replica_recipients_snd_file_chunk_replica_id;
DROP TABLE snd_file_chunk_replica_recipients;

DROP INDEX idx_snd_file_chunk_replicas_snd_file_chunk_id;
DROP INDEX idx_snd_file_chunk_replicas_xftp_server_id;
DROP TABLE snd_file_chunk_replicas;

DROP INDEX idx_snd_file_chunks_snd_file_id;
DROP TABLE snd_file_chunks;

DROP INDEX idx_snd_files_user_id;
DROP TABLE snd_files;
|]
