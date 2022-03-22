{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220322_notifications where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220322_notifications :: Query
m20220322_notifications =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN ntf_id BLOB,

ALTER TABLE rcv_queues ADD COLUMN ntf_private_key BLOB

CREATE UNIQUE INDEX idx_rcv_queues_ntf ON rcv_queues (host, port, ntf_id);

CREATE TABLE ntf_servers (
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (host, port)
) WITHOUT ROWID;

CREATE TABLE ntf_tokens (
  ntf_token TEXT NOT NULL, -- or BLOB?
  ntf_token_status, -- current / previous
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (ntf_token)
)

CREATE TABLE ntf_subscriptions (
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_sub_id BLOB, -- it can be null if it has to be created but was not created yet
  ntf_sub_status TEXT NOT NULL,
  ntf_sub_action TEXT, -- if there is an action required on this subscription: create / check / token / delete
  ntf_sub_action_ts TEXT, -- the earliest time for the action, e.g. checks can be scheduled every X hours
  ntf_token TEXT NOT NULL, -- or BLOB?
  smp_host TEXT NOT NULL,
  smp_port TEXT NOT NULL,
  smp_ntf_id BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, -- this is to check subscription status periodically to know when it was last checked
  PRIMARY KEY (ntf_host, ntf_port, ntf_sub_id),
  FOREIGN KEY (ntf_host, ntf_port) REFERENCES ntf_servers
    ON DELETE RESTRICT ON UPDATE CASCADE,
  FOREIGN KEY (smp_host, smp_port, ntf_id) REFERENCES rcv_queues (host, port, ntf_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
)
|]
