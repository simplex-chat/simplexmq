{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260712_address_dr where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260712_address_dr :: Text
m20260712_address_dr =
  [r|
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id BIGSERIAL PRIMARY KEY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BYTEA NOT NULL,
  x3dh_priv_key_1 BYTEA NOT NULL,
  x3dh_priv_key_2 BYTEA NOT NULL,
  pq_priv_kem BYTEA,
  created_at TEXT NOT NULL,
  retired_at TEXT
);

CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);
  |]

down_m20260712_address_dr :: Text
down_m20260712_address_dr =
  [r|
DROP INDEX idx_address_ratchet_keys;
DROP TABLE address_ratchet_keys;
  |]
