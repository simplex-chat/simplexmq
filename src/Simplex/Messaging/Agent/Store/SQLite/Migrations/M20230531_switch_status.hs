{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230531_switch_status where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230531_switch_status :: Query
m20230531_switch_status =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN switch_status TEXT;
ALTER TABLE rcv_queues ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE snd_queues ADD COLUMN switch_status TEXT;
|]

down_m20230531_switch_status :: Query
down_m20230531_switch_status =
  [sql|
ALTER TABLE snd_queues DROP COLUMN switch_status;
ALTER TABLE rcv_queues DROP COLUMN deleted;
ALTER TABLE rcv_queues DROP COLUMN switch_status;
|]
