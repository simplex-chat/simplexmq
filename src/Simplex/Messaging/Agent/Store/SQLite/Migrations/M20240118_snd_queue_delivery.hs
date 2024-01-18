{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240118_snd_queue_delivery where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240118_snd_queue_delivery :: Query
m20240118_snd_queue_delivery =
    [sql|
ALTER TABLE snd_queues ADD COLUMN deliver_after TEXT NOT NULL DEFAULT('1970-01-01 00:00:00');
ALTER TABLE snd_queues ADD COLUMN quota_exceeded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE snd_queues ADD COLUMN retry_delay INTEGER;

CREATE INDEX idx_snd_queues_deliver_after ON snd_queues(deliver_after);
|]

down_m20240118_snd_queue_delivery :: Query
down_m20240118_snd_queue_delivery =
    [sql|
DROP INDEX idx_snd_queues_deliver_after;

ALTER TABLE snd_queues DROP COLUMN deliver_after;
ALTER TABLE snd_queues DROP COLUMN quota_exceeded;
ALTER TABLE snd_queues DROP COLUMN retry_delay;
|]
