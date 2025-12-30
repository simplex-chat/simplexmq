{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250322_short_links where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250322_short_links :: Query
m20250322_short_links =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN link_id BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_key BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_priv_sig_key BLOB;
ALTER TABLE rcv_queues ADD COLUMN link_enc_fixed_data BLOB;

CREATE UNIQUE INDEX idx_rcv_queues_link_id ON rcv_queues(host, port, link_id);

ALTER TABLE rcv_queues ADD COLUMN queue_mode TEXT;
UPDATE rcv_queues SET queue_mode = 'M' WHERE snd_secure = 1;
ALTER TABLE rcv_queues DROP COLUMN snd_secure;

ALTER TABLE snd_queues ADD COLUMN queue_mode TEXT;
UPDATE snd_queues SET queue_mode = 'M' WHERE snd_secure = 1;
ALTER TABLE snd_queues DROP COLUMN snd_secure;

CREATE TABLE inv_short_links(
  inv_short_link_id INTEGER PRIMARY KEY AUTOINCREMENT,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  server_key_hash BLOB,
  link_id BLOB NOT NULL,
  link_key BLOB NOT NULL,
  snd_private_key BLOB NOT NULL,
  snd_id BLOB,
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT ON UPDATE CASCADE
) STRICT;

CREATE UNIQUE INDEX idx_inv_short_links_link_id ON inv_short_links(host, port, link_id);
  |]

down_m20250322_short_links :: Query
down_m20250322_short_links =
  [sql|
DROP INDEX idx_rcv_queues_link_id;
ALTER TABLE rcv_queues DROP COLUMN link_id;
ALTER TABLE rcv_queues DROP COLUMN link_key;
ALTER TABLE rcv_queues DROP COLUMN link_priv_sig_key;
ALTER TABLE rcv_queues DROP COLUMN link_enc_fixed_data;

DROP INDEX idx_inv_short_links_link_id;
DROP TABLE inv_short_links;

ALTER TABLE rcv_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;
UPDATE rcv_queues SET snd_secure = 1 WHERE queue_mode = 'M';
ALTER TABLE rcv_queues DROP COLUMN queue_mode;

ALTER TABLE snd_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;
UPDATE snd_queues SET snd_secure = 1 WHERE queue_mode = 'M';
ALTER TABLE snd_queues DROP COLUMN queue_mode;
  |]
