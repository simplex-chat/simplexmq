{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260929_ratchet_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260929_ratchet_indexes :: Query
m20260929_ratchet_indexes =
  [sql|
CREATE INDEX idx_processed_ratchet_key_hashes_conn_id ON processed_ratchet_key_hashes(conn_id, processed_ratchet_key_hash_id);
  |]

down_m20260929_ratchet_indexes :: Query
down_m20260929_ratchet_indexes =
  [sql|
DROP INDEX idx_processed_ratchet_key_hashes_conn_id;
  |]
