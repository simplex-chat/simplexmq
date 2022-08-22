{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220821_msg_deliveries where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220821_msg_deliveries :: Query
m20220821_msg_deliveries =
  [sql|
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
