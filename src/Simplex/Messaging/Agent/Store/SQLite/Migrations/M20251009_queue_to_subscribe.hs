{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20251009_queue_to_subscribe where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20251009_queue_to_subscribe :: Query
m20251009_queue_to_subscribe =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN to_subscribe INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_rcv_queues_to_subscribe ON rcv_queues(to_subscribe);
|]

down_m20251009_queue_to_subscribe :: Query
down_m20251009_queue_to_subscribe =
  [sql|
DROP INDEX idx_rcv_queues_to_subscribe;
ALTER TABLE rcv_queues DROP COLUMN to_subscribe;
|]
