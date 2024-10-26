{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20241007_rcv_queues_last_broker_ts where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20241007_rcv_queues_last_broker_ts :: Query
m20241007_rcv_queues_last_broker_ts =
    [sql|
ALTER TABLE rcv_queues ADD COLUMN last_broker_ts TEXT;
|]

down_m20241007_rcv_queues_last_broker_ts :: Query
down_m20241007_rcv_queues_last_broker_ts =
    [sql|
ALTER TABLE rcv_queues DROP COLUMN last_broker_ts;
|]
