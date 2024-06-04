{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240417_rcv_files_approved_relays where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240417_rcv_files_approved_relays :: Query
m20240417_rcv_files_approved_relays =
    [sql|
ALTER TABLE rcv_files ADD COLUMN approved_relays INTEGER NOT NULL DEFAULT 0;
|]

down_m20240417_rcv_files_approved_relays :: Query
down_m20240417_rcv_files_approved_relays =
    [sql|
ALTER TABLE rcv_files DROP COLUMN approved_relays;
|]
