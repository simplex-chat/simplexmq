{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20250322_short_links where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

m20250322_short_links :: Text
m20250322_short_links =
  T.pack    
    [r|
ALTER TABLE rcv_queues ADD COLUMN link_id BYTEA;
ALTER TABLE rcv_queues ADD COLUMN link_key BYTEA;
ALTER TABLE rcv_queues ADD COLUMN link_priv_sig_key BYTEA;
ALTER TABLE rcv_queues ADD COLUMN link_enc_fixed_data BYTEA;

CREATE UNIQUE INDEX idx_rcv_queues_link_id ON rcv_queues(host, port, link_id);

ALTER TABLE rcv_queues ADD COLUMN queue_mode TEXT;
UPDATE rcv_queues SET queue_mode = 'M' WHERE snd_secure = 1;
ALTER TABLE rcv_queues DROP COLUMN snd_secure;

ALTER TABLE snd_queues ADD COLUMN queue_mode TEXT;
UPDATE snd_queues SET queue_mode = 'M' WHERE snd_secure = 1;
ALTER TABLE snd_queues DROP COLUMN snd_secure;

CREATE TABLE inv_short_links(
  inv_short_link_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  server_key_hash BYTEA,
  link_id BYTEA NOT NULL,
  link_key BYTEA NOT NULL,
  snd_private_key BYTEA NOT NULL,
  snd_id BYTEA,
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE UNIQUE INDEX idx_inv_short_links_link_id ON inv_short_links(host, port, link_id);
|]

down_m20250322_short_links :: Text
down_m20250322_short_links =
  T.pack
    [r|
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
