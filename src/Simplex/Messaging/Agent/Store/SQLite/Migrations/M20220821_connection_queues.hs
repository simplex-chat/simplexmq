{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220821_connection_queues where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220821_connection_queues :: Query
m20220821_connection_queues =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN rcv_queue_id INTEGER NULL;
ALTER TABLE rcv_queues ADD COLUMN rcv_primary INTEGER CHECK (rcv_primary NOT NULL);
UPDATE rcv_queues SET rcv_primary = 1;
CREATE UNIQUE INDEX idx_rcv_queue_id ON rcv_queues(rcv_queue_id);

ALTER TABLE snd_queues ADD COLUMN snd_queue_id INTEGER NULL;
ALTER TABLE snd_queues ADD COLUMN snd_primary INTEGER CHECK (snd_primary NOT NULL);
UPDATE snd_queues SET snd_primary = 1;
CREATE UNIQUE INDEX idx_snd_queue_id ON snd_queues(snd_queue_id);

CREATE TABLE snd_message_deliveries (
  conn_id BLOB NOT NULL,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BLOB NOT NULL,
  internal_id INTEGER NOT NULL,
  internal_snd_id INTEGER NOT NULL,
  PRIMARY KEY(conn_id, host, port, snd_id, internal_snd_id),
  FOREIGN KEY(conn_id, internal_snd_id) REFERENCES snd_messages,
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages,
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;

CREATE TABLE rcv_message_deliveries (
  conn_id BLOB NOT NULL,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BLOB NOT NULL,
  internal_id INTEGER NOT NULL,
  internal_rcv_id INTEGER NOT NULL,
  PRIMARY KEY(conn_id, host, port, rcv_id, internal_rcv_id),
  FOREIGN KEY(conn_id, internal_rcv_id) REFERENCES rcv_messages,
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages,
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;

ALTER TABLE connections ADD COLUMN conn_status TEXT;
|]
