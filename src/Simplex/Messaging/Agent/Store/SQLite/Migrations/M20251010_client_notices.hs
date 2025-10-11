{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20251010_client_notices where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20251010_client_notices :: Query
m20251010_client_notices =
  [sql|
CREATE TABLE client_notices(
  client_notice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  entity_id BLOB NOT NULL,
  notice_domains TEXT NOT NULL,
  notice_scopes TEXT NOT NULL,
  notice_expires INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX idx_client_notices_entity_id ON client_notices(host, port, entity_id);
CREATE INDEX idx_client_notices_domains ON client_notices(notice_domains);

ALTER TABLE rcv_queues ADD COLUMN client_notice_id INTEGER
REFERENCES client_notices ON UPDATE RESTRICT ON DELETE SET NULL;

CREATE INDEX idx_rcv_queues_client_notice_id ON rcv_queues(client_notice_id);
|]

down_m20251010_client_notices :: Query
down_m20251010_client_notices =
  [sql|
DROP INDEX idx_rcv_queues_client_notice_id;

ALTER TABLE rcv_queues DROP COLUMN client_notice_id;

DROP INDEX idx_client_notices_entity_id;
DROP INDEX idx_client_notices_domains;

DROP TABLE client_notices;
|]
