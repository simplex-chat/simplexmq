{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260823_snd_files_entitlement where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260823_snd_files_entitlement :: Text
m20260823_snd_files_entitlement =
  [r|
ALTER TABLE snd_files ADD COLUMN entitlement_credential TEXT;
ALTER TABLE snd_files ADD COLUMN storage_time TEXT NOT NULL DEFAULT 'max';
|]

down_m20260823_snd_files_entitlement :: Text
down_m20260823_snd_files_entitlement =
  [r|
ALTER TABLE snd_files DROP COLUMN storage_time;
ALTER TABLE snd_files DROP COLUMN entitlement_credential;
|]
