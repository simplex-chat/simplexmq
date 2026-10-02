{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20261001_ratchet_key_hashes_unique where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20261001_ratchet_key_hashes_unique :: Text
m20261001_ratchet_key_hashes_unique =
  [r|
DELETE FROM processed_ratchet_key_hashes
WHERE processed_ratchet_key_hash_id NOT IN (
  SELECT MIN(processed_ratchet_key_hash_id)
  FROM processed_ratchet_key_hashes
  GROUP BY conn_id, hash
);

DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE UNIQUE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
|]

down_m20261001_ratchet_key_hashes_unique :: Text
down_m20261001_ratchet_key_hashes_unique =
  [r|
DROP INDEX idx_processed_ratchet_key_hashes_hash;
CREATE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(conn_id, hash);
|]
