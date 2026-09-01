{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260823_snd_files_entitlement where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260823_snd_files_entitlement :: Text
m20260823_snd_files_entitlement =
  [r|
ALTER TABLE snd_files ADD COLUMN storage_time BIGINT;
ALTER TABLE snd_file_chunk_replicas ADD COLUMN replica_expires_at BIGINT;
|]

down_m20260823_snd_files_entitlement :: Text
down_m20260823_snd_files_entitlement =
  [r|
ALTER TABLE snd_file_chunk_replicas DROP COLUMN replica_expires_at;
ALTER TABLE snd_files DROP COLUMN storage_time;
|]
