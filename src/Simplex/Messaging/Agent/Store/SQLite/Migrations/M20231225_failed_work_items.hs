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

CREATE INDEX idx_rcv_files_status_created_at ON rcv_files(status, created_at);
CREATE INDEX idx_snd_files_status_created_at ON snd_files(status, created_at);
CREATE INDEX idx_snd_files_snd_file_entity_id ON snd_files(snd_file_entity_id);
|]

down_m20231225_failed_work_items :: Query
down_m20231225_failed_work_items =
    [sql|
DROP INDEX idx_rcv_files_status_created_at;
DROP INDEX idx_snd_files_status_created_at;
DROP INDEX idx_snd_files_snd_file_entity_id;

ALTER TABLE snd_message_deliveries DROP COLUMN failed;
ALTER TABLE commands DROP COLUMN failed;
ALTER TABLE ntf_subscriptions DROP COLUMN ntf_failed;
ALTER TABLE ntf_subscriptions DROP COLUMN smp_failed;
ALTER TABLE rcv_files DROP COLUMN failed;
ALTER TABLE snd_files DROP COLUMN failed;
ALTER TABLE deleted_snd_chunk_replicas DROP COLUMN failed;
|]
