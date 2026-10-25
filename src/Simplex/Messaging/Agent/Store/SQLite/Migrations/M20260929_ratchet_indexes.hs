{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260929_ratchet_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- idx_skipped_messages_conn_id is not changed: SQLite index entries include rowid (skipped_message_id)
m20260929_ratchet_indexes :: Query
m20260929_ratchet_indexes =
  [sql|
DELETE FROM processed_ratchet_key_hashes AS h
WHERE EXISTS (
  SELECT 1 FROM processed_ratchet_key_hashes d
  WHERE d.conn_id = h.conn_id AND d.hash = h.hash AND d.processed_ratchet_key_hash_id < h.processed_ratchet_key_hash_id
);

DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE UNIQUE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
CREATE INDEX idx_processed_ratchet_key_hashes_conn_id ON processed_ratchet_key_hashes(conn_id, processed_ratchet_key_hash_id);
  |]

down_m20260929_ratchet_indexes :: Query
down_m20260929_ratchet_indexes =
  [sql|
DROP INDEX idx_processed_ratchet_key_hashes_conn_id;
DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
  |]
