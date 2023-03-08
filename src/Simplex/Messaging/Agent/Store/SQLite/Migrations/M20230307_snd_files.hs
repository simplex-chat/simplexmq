{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230307_snd_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- this migration is a draft - it is not included in the list of migrations
m20230307_snd_files :: Query
m20230307_snd_files =
  [sql|
CREATE TABLE snd_files (
  snd_file_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  key BLOB NOT NULL,
  nonce BLOB NOT NULL,
  chunk_size INTEGER NOT NULL,
  path TEXT NOT NULL,
  enc_path TEXT,
  status TEXT NOT NULL,
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
  delay INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_file_chunks_snd_file_id ON snd_file_chunks(snd_file_id);

-- ? add fk to snd_file_descriptions?
-- ? probably it's not necessary since these entities are
-- ? required at different stages of sending files -
-- ? replicas on upload, description on notifying client
CREATE TABLE snd_file_chunk_replicas (
  snd_file_chunk_replica_id INTEGER PRIMARY KEY,
  snd_file_chunk_id INTEGER NOT NULL REFERENCES snd_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  -- created INTEGER NOT NULL DEFAULT 0, -- as in XFTP create - registered on server
  uploaded INTEGER NOT NULL DEFAULT 0,
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

CREATE TABLE snd_file_descriptions (
  snd_file_description_id INTEGER PRIMARY KEY,
  snd_file_id INTEGER NOT NULL REFERENCES snd_files ON DELETE CASCADE,
  sender INTEGER NOT NULL, -- 1 for sender file description
  descr_text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_snd_file_descriptions_snd_file_id ON snd_file_descriptions(snd_file_id);
|]
