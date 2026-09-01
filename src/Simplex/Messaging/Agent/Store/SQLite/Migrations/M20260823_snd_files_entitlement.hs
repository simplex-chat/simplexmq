{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260823_snd_files_entitlement where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260823_snd_files_entitlement :: Query
m20260823_snd_files_entitlement =
  [sql|
ALTER TABLE snd_files ADD COLUMN storage_time INTEGER;
ALTER TABLE snd_file_chunk_replicas ADD COLUMN replica_expires_at INTEGER;
  |]

down_m20260823_snd_files_entitlement :: Query
down_m20260823_snd_files_entitlement =
  [sql|
ALTER TABLE snd_file_chunk_replicas DROP COLUMN replica_expires_at;
ALTER TABLE snd_files DROP COLUMN storage_time;
  |]
