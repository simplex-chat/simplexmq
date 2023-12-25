{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20231225_failed_work_items where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20231225_failed_work_items :: Query
m20231225_failed_work_items =
    [sql|
ALTER TABLE snd_message_deliveries ADD COLUMN failed INTEGER DEFAULT 0;
ALTER TABLE commands ADD COLUMN failed INTEGER DEFAULT 0;
ALTER TABLE ntf_subscriptions ADD COLUMN ntf_failed INTEGER DEFAULT 0;
ALTER TABLE ntf_subscriptions ADD COLUMN smp_failed INTEGER DEFAULT 0;
ALTER TABLE rcv_files ADD COLUMN failed INTEGER DEFAULT 0;
ALTER TABLE snd_files ADD COLUMN failed INTEGER DEFAULT 0;
ALTER TABLE deleted_snd_chunk_replicas ADD COLUMN failed INTEGER DEFAULT 0;
|]

down_m20231225_failed_work_items :: Query
down_m20231225_failed_work_items =
    [sql|
ALTER TABLE snd_message_deliveries DROP COLUMN failed;
ALTER TABLE commands DROP COLUMN failed;
ALTER TABLE ntf_subscriptions DROP COLUMN ntf_failed;
ALTER TABLE ntf_subscriptions DROP COLUMN smp_failed;
ALTER TABLE rcv_files DROP COLUMN failed;
ALTER TABLE snd_files DROP COLUMN failed;
ALTER TABLE deleted_snd_chunk_replicas DROP COLUMN failed;
|]
