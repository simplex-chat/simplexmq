{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230722_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230722_indexes :: Query
m20230722_indexes =
  [sql|
CREATE INDEX idx_processed_ratchet_key_hashes_created_at ON processed_ratchet_key_hashes(created_at);
CREATE INDEX idx_encrypted_rcv_message_hashes_created_at ON encrypted_rcv_message_hashes(created_at);
|]

down_m20230722_indexes :: Query
down_m20230722_indexes =
  [sql|
DROP INDEX idx_encrypted_rcv_message_hashes_created_at;
DROP INDEX idx_processed_ratchet_key_hashes_created_at;
|]
