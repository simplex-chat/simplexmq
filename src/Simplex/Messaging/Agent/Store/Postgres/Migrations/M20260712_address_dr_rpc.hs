{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260712_address_dr_rpc where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260712_address_dr_rpc :: Text
m20260712_address_dr_rpc =
  [r|
CREATE TABLE address_ratchet_keys(
  address_ratchet_key_id BIGSERIAL PRIMARY KEY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  ratchet_key_id BYTEA NOT NULL,
  x3dh_priv_key_1 BYTEA NOT NULL,
  x3dh_priv_key_2 BYTEA NOT NULL,
  pq_priv_kem BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);

CREATE UNIQUE INDEX idx_address_ratchet_keys ON address_ratchet_keys(conn_id, ratchet_key_id);

ALTER TABLE conn_invitations ADD COLUMN is_service_request SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE connections ADD COLUMN created_at TIMESTAMPTZ;
  |]

down_m20260712_address_dr_rpc :: Text
down_m20260712_address_dr_rpc =
  [r|
ALTER TABLE connections DROP COLUMN created_at;
ALTER TABLE conn_invitations DROP COLUMN is_service_request;
DROP INDEX idx_address_ratchet_keys;
DROP TABLE address_ratchet_keys;
  |]
