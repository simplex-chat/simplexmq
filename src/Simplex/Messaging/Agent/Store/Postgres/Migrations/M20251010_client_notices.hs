{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20251010_client_notices where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20251010_client_notices :: Text
m20251010_client_notices =
  [r|
CREATE TABLE client_notices(
  client_notice_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  protocol TEXT NOT NULL,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  entity_id BYTEA NOT NULL,
  server_key_hash BYTEA,
  notice_ttl BIGINT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

CREATE UNIQUE INDEX idx_client_notices_entity ON client_notices(protocol, host, port, entity_id);

ALTER TABLE rcv_queues ADD COLUMN client_notice_id BIGINT
REFERENCES client_notices ON UPDATE RESTRICT ON DELETE SET NULL;

CREATE INDEX idx_rcv_queues_client_notice_id ON rcv_queues(client_notice_id);
|]

down_m20251010_client_notices :: Text
down_m20251010_client_notices =
  [r|
DROP INDEX idx_rcv_queues_client_notice_id;
ALTER TABLE rcv_queues DROP COLUMN client_notice_id;

DROP INDEX idx_client_notices_entity;
DROP TABLE client_notices;
|]
