{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230510_files_pending_replicas_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230510_files_pending_replicas_indexes :: Query
m20230510_files_pending_replicas_indexes =
  [sql|
CREATE INDEX idx_rcv_file_chunk_replicas_pending ON rcv_file_chunk_replicas(received, replica_number);
CREATE INDEX idx_snd_file_chunk_replicas_pending ON snd_file_chunk_replicas(replica_status, replica_number);
CREATE INDEX idx_deleted_snd_chunk_replicas_pending ON deleted_snd_chunk_replicas(created_at);
|]

down_m20230510_files_pending_replicas_indexes :: Query
down_m20230510_files_pending_replicas_indexes =
  [sql|
DROP INDEX idx_deleted_snd_chunk_replicas_pending;
DROP INDEX idx_snd_file_chunk_replicas_pending;
DROP INDEX idx_rcv_file_chunk_replicas_pending;
|]
