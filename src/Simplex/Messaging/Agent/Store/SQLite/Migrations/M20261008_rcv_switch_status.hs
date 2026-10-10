{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20261008_rcv_switch_status where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20261008_rcv_switch_status :: Query
m20261008_rcv_switch_status =
  [sql|
CREATE INDEX idx_rcv_queues_switch_status ON rcv_queues(switch_status);
|]

down_m20261008_rcv_switch_status :: Query
down_m20261008_rcv_switch_status =
  [sql|
UPDATE rcv_queues SET switch_status = NULL WHERE switch_status = 'received_qend';
DROP INDEX idx_rcv_queues_switch_status;
|]
