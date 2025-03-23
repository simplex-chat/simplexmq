{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250322_short_links where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250322_short_links :: Query
m20250322_short_links =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN link_id BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_key BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_sig_key BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_enc_immutable_data BLOB;

CREATE UNIQUE INDEX idx_rcv_queues_link_id ON rcv_queues(host, port, link_id);

CREATE TABLE inv_short_links(
  inv_short_link_id INTEGER PRIMARY KEY AUTOINCREMENT,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  link_id BLOB NOT NULL,
  link_key BLOB NOT NULL,
  snd_private_key BLOB NOT NULL,
  conn_req BLOB,
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE UNIQUE INDEX idx_inv_short_links_link_id ON inv_short_links(host, port, link_id);
  |]

down_m20250322_short_links :: Query
down_m20250322_short_links =
  [sql|
DROP INDEX idx_rcv_queues_link_id;
ALTER TABLE rcv_queues DROP COLUMN link_id;
ALTER TABLE rcv_queues DROP COLUMN link_key;
ALTER TABLE rcv_queues DROP COLUMN link_sig_key;
ALTER TABLE rcv_queues DROP COLUMN link_enc_immutable_data;

DROP INDEX idx_inv_short_links_link_id;
DROP TABLE inv_short_links;
  |]
