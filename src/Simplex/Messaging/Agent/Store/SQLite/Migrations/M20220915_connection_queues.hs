{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220915_connection_queues where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220915_connection_queues :: Query
m20220915_connection_queues =
  [sql|
-- rcv_queues
ALTER TABLE rcv_queues ADD COLUMN rcv_queue_id INTEGER NULL;
CREATE UNIQUE INDEX idx_rcv_queue_id ON rcv_queues(rcv_queue_id);

ALTER TABLE rcv_queues ADD COLUMN rcv_primary INTEGER CHECK (rcv_primary NOT NULL);
UPDATE rcv_queues SET rcv_primary = 1;

ALTER TABLE rcv_queues ADD COLUMN next_rcv_primary INTEGER CHECK (next_rcv_primary NOT NULL);
UPDATE rcv_queues SET next_rcv_primary = 0;

ALTER TABLE rcv_queues ADD COLUMN replace_rcv_queue INTEGER CHECK (replace_rcv_queue NOT NULL);
UPDATE rcv_queues SET replace_rcv_queue = 0;

ALTER TABLE rcv_queues ADD COLUMN replace_rcv_queue_id INTEGER NULL;

-- snd_queues
ALTER TABLE snd_queues ADD COLUMN snd_queue_id INTEGER NULL;
CREATE UNIQUE INDEX idx_snd_queue_id ON snd_queues (snd_queue_id);

ALTER TABLE snd_queues ADD COLUMN snd_primary INTEGER CHECK (snd_primary NOT NULL);
UPDATE snd_queues SET snd_primary = 1;

-- messages
CREATE TABLE snd_message_deliveries (
  snd_message_delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_queue_id INTEGER NULL,
  internal_id INTEGER NOT NULL,
  FOREIGN KEY (conn_id, internal_id) REFERENCES messages ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_snd_message_deliveries ON snd_message_deliveries (conn_id, snd_queue_id);

ALTER TABLE rcv_messages ADD COLUMN rcv_queue_id INTEGER NULL;
|]
