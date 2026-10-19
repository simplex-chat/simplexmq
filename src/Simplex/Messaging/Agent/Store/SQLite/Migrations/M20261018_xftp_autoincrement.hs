{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20261018_xftp_autoincrement where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20261018_xftp_autoincrement :: Query
m20261018_xftp_autoincrement =
  [sql|
INSERT INTO sqlite_sequence (name, seq)
SELECT 'rcv_files', MAX(ROWID) FROM rcv_files;

INSERT INTO sqlite_sequence (name, seq)
SELECT 'rcv_file_chunks', MAX(ROWID) FROM rcv_file_chunks;

INSERT INTO sqlite_sequence (name, seq)
SELECT 'rcv_file_chunk_replicas', MAX(ROWID) FROM rcv_file_chunk_replicas;

INSERT INTO sqlite_sequence (name, seq)
SELECT 'snd_files', MAX(ROWID) FROM snd_files;

INSERT INTO sqlite_sequence (name, seq)
SELECT 'snd_file_chunks', MAX(ROWID) FROM snd_file_chunks;

INSERT INTO sqlite_sequence (name, seq)
SELECT 'snd_file_chunk_replicas', MAX(ROWID) FROM snd_file_chunk_replicas;

PRAGMA writable_schema=1;

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_id INTEGER PRIMARY KEY,', 'rcv_file_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'rcv_files' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_chunk_id INTEGER PRIMARY KEY,', 'rcv_file_chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'rcv_file_chunks' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_chunk_replica_id INTEGER PRIMARY KEY,', 'rcv_file_chunk_replica_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'rcv_file_chunk_replicas' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_id INTEGER PRIMARY KEY,', 'snd_file_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'snd_files' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_chunk_id INTEGER PRIMARY KEY,', 'snd_file_chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'snd_file_chunks' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_chunk_replica_id INTEGER PRIMARY KEY,', 'snd_file_chunk_replica_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'snd_file_chunk_replicas' AND type = 'table';

PRAGMA writable_schema=RESET;
  |]

down_m20261018_xftp_autoincrement :: Query
down_m20261018_xftp_autoincrement =
  [sql|
DELETE FROM sqlite_sequence WHERE name = 'rcv_files';
DELETE FROM sqlite_sequence WHERE name = 'rcv_file_chunks';
DELETE FROM sqlite_sequence WHERE name = 'rcv_file_chunk_replicas';
DELETE FROM sqlite_sequence WHERE name = 'snd_files';
DELETE FROM sqlite_sequence WHERE name = 'snd_file_chunks';
DELETE FROM sqlite_sequence WHERE name = 'snd_file_chunk_replicas';

PRAGMA writable_schema=1;

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'rcv_file_id INTEGER PRIMARY KEY,')
WHERE name = 'rcv_files' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'rcv_file_chunk_id INTEGER PRIMARY KEY,')
WHERE name = 'rcv_file_chunks' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'rcv_file_chunk_replica_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'rcv_file_chunk_replica_id INTEGER PRIMARY KEY,')
WHERE name = 'rcv_file_chunk_replicas' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'snd_file_id INTEGER PRIMARY KEY,')
WHERE name = 'snd_files' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'snd_file_chunk_id INTEGER PRIMARY KEY,')
WHERE name = 'snd_file_chunks' AND type = 'table';

UPDATE sqlite_master SET sql = replace(sql, 'snd_file_chunk_replica_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'snd_file_chunk_replica_id INTEGER PRIMARY KEY,')
WHERE name = 'snd_file_chunk_replicas' AND type = 'table';

PRAGMA writable_schema=RESET;
  |]
