{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220404_ntf_subscriptions_draft where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220404_ntf_subscriptions_draft :: Query
m20220404_ntf_subscriptions_draft =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN ntf_id BLOB;

ALTER TABLE rcv_queues ADD COLUMN ntf_public_key BLOB;

ALTER TABLE rcv_queues ADD COLUMN ntf_private_key BLOB;

CREATE UNIQUE INDEX idx_rcv_queues_ntf ON rcv_queues (host, port, ntf_id);

CREATE TABLE ntf_subscriptions (
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_sub_id BLOB,
  ntf_sub_status TEXT NOT NULL, -- new, created, active, pending, error_auth
  ntf_sub_action TEXT, -- if there is an action required on this subscription: create / check / delete
  ntf_sub_smp_action TEXT, -- action with SMP server: nkey; only one of this and ntf_sub_action can (should) be not null in same record
  ntf_sub_action_ts TEXT, -- the earliest time for the action, e.g. checks can be scheduled every X hours
  ntf_token TEXT NOT NULL, -- or BLOB?
  smp_host TEXT NULL,
  smp_port TEXT NULL,
  smp_rcv_id BLOB NULL,
  smp_ntf_id BLOB,
  marked_for_deletion INTEGER NOT NULL DEFAULT 0, -- to be checked on updates by workers to not overwrite delete command
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, -- this is to check subscription status periodically to know when it was last checked
  PRIMARY KEY (smp_host, smp_port, smp_rcv_id),
  FOREIGN KEY (ntf_host, ntf_port) REFERENCES ntf_servers
    ON DELETE RESTRICT ON UPDATE CASCADE,
  FOREIGN KEY (smp_host, smp_port, smp_rcv_id) REFERENCES rcv_queues (host, port, rcv_id)
    ON DELETE SET NULL ON UPDATE CASCADE
) WITHOUT ROWID;
|]
