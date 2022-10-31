{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220915_connection_queues where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220915_connection_queues :: Query
m20220915_connection_queues =
  [sql|
PRAGMA ignore_check_constraints=ON;

-- rcv_queues
ALTER TABLE rcv_queues ADD COLUMN rcv_queue_id INTEGER CHECK (rcv_queue_id NOT NULL);
UPDATE rcv_queues SET rcv_queue_id = 1;
CREATE UNIQUE INDEX idx_rcv_queue_id ON rcv_queues (conn_id, rcv_queue_id);

ALTER TABLE rcv_queues ADD COLUMN rcv_primary INTEGER CHECK (rcv_primary NOT NULL);
UPDATE rcv_queues SET rcv_primary = 1;

ALTER TABLE rcv_queues ADD COLUMN replace_rcv_queue_id INTEGER NULL;

-- snd_queues
ALTER TABLE snd_queues ADD COLUMN snd_queue_id INTEGER CHECK (snd_queue_id NOT NULL);
UPDATE snd_queues SET snd_queue_id = 1;
CREATE UNIQUE INDEX idx_snd_queue_id ON snd_queues (conn_id, snd_queue_id);

ALTER TABLE snd_queues ADD COLUMN snd_primary INTEGER CHECK (snd_primary NOT NULL);
UPDATE snd_queues SET snd_primary = 1;

ALTER TABLE snd_queues ADD COLUMN replace_snd_queue_id INTEGER NULL;

-- connections
ALTER TABLE connections ADD COLUMN deleted INTEGER DEFAULT 0 CHECK (deleted NOT NULL);
UPDATE connections SET deleted = 0;

-- messages
CREATE TABLE snd_message_deliveries (
  snd_message_delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_queue_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  FOREIGN KEY (conn_id, internal_id) REFERENCES messages ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_snd_message_deliveries ON snd_message_deliveries (conn_id, snd_queue_id);

ALTER TABLE rcv_messages ADD COLUMN rcv_queue_id INTEGER CHECK (rcv_queue_id NOT NULL);
UPDATE rcv_messages SET rcv_queue_id = 1;

PRAGMA ignore_check_constraints=OFF;
|]
