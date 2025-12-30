{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20251010_client_notices where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20251010_client_notices :: Query
m20251010_client_notices =
  [sql|
CREATE TABLE client_notices(
  client_notice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT NOT NULL,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  entity_id BLOB NOT NULL,
  server_key_hash BLOB,
  notice_ttl INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX idx_client_notices_entity ON client_notices(protocol, host, port, entity_id);

ALTER TABLE rcv_queues ADD COLUMN client_notice_id INTEGER
REFERENCES client_notices ON UPDATE RESTRICT ON DELETE SET NULL;

CREATE INDEX idx_rcv_queues_client_notice_id ON rcv_queues(client_notice_id);
|]

down_m20251010_client_notices :: Query
down_m20251010_client_notices =
  [sql|
DROP INDEX idx_rcv_queues_client_notice_id;
ALTER TABLE rcv_queues DROP COLUMN client_notice_id;

DROP INDEX idx_client_notices_entity;
DROP TABLE client_notices;
|]
