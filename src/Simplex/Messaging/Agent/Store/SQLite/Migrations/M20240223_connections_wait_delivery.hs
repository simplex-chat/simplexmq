{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240223_connections_wait_delivery where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240223_connections_wait_delivery :: Query
m20240223_connections_wait_delivery =
  [sql|
ALTER TABLE connections ADD COLUMN deleted_wait_delivery INTEGER NOT NULL DEFAULT 0;
|]

down_m20240223_connections_wait_delivery :: Query
down_m20240223_connections_wait_delivery =
  [sql|
ALTER TABLE connections DROP COLUMN deleted_wait_delivery;
|]
