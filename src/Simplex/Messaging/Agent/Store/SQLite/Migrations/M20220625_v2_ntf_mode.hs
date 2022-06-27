{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220625_v2_ntf_mode where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220625_v2_ntf_mode :: Query
m20220625_v2_ntf_mode =
  [sql|
ALTER TABLE ntf_tokens ADD COLUMN ntf_mode TEXT NULL;

DELETE FROM ntf_tokens;
|]
