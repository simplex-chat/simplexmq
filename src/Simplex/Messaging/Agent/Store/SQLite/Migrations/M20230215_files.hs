{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230215_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230215_files :: Query
m20230215_files =
  [sql|
CREATE TABLE xftp_servers (
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  xftp_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (xftp_host, xftp_port)
) WITHOUT ROWID;

CREATE TABLE rcv_files (
  rcv_file_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL, -- ?
  size INTEGER NOT NULL, -- ?
  digest BLOB NOT NULL,
  key BLOB NOT NULL,
  iv BLOB NOT NULL,
  chunk_size INTEGER NOT NULL,
  save_path TEXT, -- ? NOT NULL
  temp_path TEXT, -- ? NOT NULL
  -- xftp_action TEXT,
  complete INTEGER NOT NULL DEFAULT 0, -- when collected and decrypted -- ? store status?
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE rcv_file_chunks (
  rcv_file_chunk_id INTEGER PRIMARY KEY,
  rcv_file_id INTEGER NOT NULL REFERENCES rcv_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  -- received INTEGER NOT NULL DEFAULT 0, -- ? duplicate
  temp_path TEXT, -- ? NOT NULL
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE rcv_file_chunk_replicas (
  rcv_file_chunk_replica_id INTEGER PRIMARY KEY,
  rcv_file_chunk_id INTEGER NOT NULL REFERENCES rcv_file_chunks ON DELETE CASCADE,
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  rcvKey BLOB NOT NULL,
  received INTEGER NOT NULL DEFAULT 0,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (xftp_host, xftp_port) REFERENCES xftp_servers
    ON DELETE RESTRICT ON UPDATE CASCADE
);

-- or store on rcv_files / rcv_file_chunks?
CREATE TABLE xftp_actions (
  xftp_action_id INTEGER PRIMARY KEY,
  xftp_host TEXT,
  xftp_port TEXT,
  action TEXT NOT NULL, -- encoded XftpAction? or foreign key to rcv_files / rcv_file_chunks?
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (xftp_host, xftp_port) REFERENCES xftp_servers
    ON DELETE RESTRICT ON UPDATE CASCADE
);
|]
