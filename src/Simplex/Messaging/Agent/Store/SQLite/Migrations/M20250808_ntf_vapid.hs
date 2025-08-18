{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250808_ntf_vapid where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250808_ntf_vapid :: Query
m20250808_ntf_vapid =
  [sql|
ALTER TABLE ntf_servers ADD COLUMN ntf_vapid TEXT;
  |]

down_m20250808_ntf_vapid :: Query
down_m20250808_ntf_vapid =
  [sql|
ALTER TABLE ntf_servers DROP COLUMN ntf_vapid TEXT;
  |]
