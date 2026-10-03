{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20261001_ratchet_key_hashes_unique where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20261001_ratchet_key_hashes_unique :: Query
m20261001_ratchet_key_hashes_unique =
  [sql|
DELETE FROM processed_ratchet_key_hashes
WHERE processed_ratchet_key_hash_id NOT IN (
  SELECT MIN(processed_ratchet_key_hash_id)
  FROM processed_ratchet_key_hashes
  GROUP BY conn_id, hash
);

DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE UNIQUE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
|]

down_m20261001_ratchet_key_hashes_unique :: Query
down_m20261001_ratchet_key_hashes_unique =
  [sql|
DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
|]
