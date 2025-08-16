{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250815_service_certs where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- TODO move date forward, create migration for postgres
m20250815_service_certs :: Query
m20250815_service_certs =
  [sql|
CREATE TABLE server_certs(
  server_cert_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users ON UPDATE RESTRICT ON DELETE CASCADE,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  certificate BLOB NOT NULL,
  priv_key BLOB NOT NULL,
  service_id BLOB,
  FOREIGN KEY(host, port) REFERENCES servers ON UPDATE CASCADE ON DELETE RESTRICT,
);

CREATE UNIQUE INDEX idx_server_certs_user_id_host_port ON server_certs(user_id, host, port);

CREATE INDEX idx_server_certs_host_port ON server_certs(host, port);

ALTER TABLE rcv_queues ADD COLUMN rcv_service_assoc INTEGER NOT NULL DEFAULT 0;
  |]

down_m20250815_service_certs :: Query
down_m20250815_service_certs =
  [sql|
ALTER TABLE rcv_queues DROP COLUMN rcv_service_assoc;

DROP INDEX idx_server_certs_host_port;

DROP INDEX idx_server_certs_user_id_host_port;

DROP TABLE server_certs;
  |]
