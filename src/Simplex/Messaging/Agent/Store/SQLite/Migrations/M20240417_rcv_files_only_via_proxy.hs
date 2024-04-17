{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240417_rcv_files_only_via_proxy where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240417_rcv_files_only_via_proxy :: Query
m20240417_rcv_files_only_via_proxy =
    [sql|
ALTER TABLE rcv_files ADD COLUMN only_via_proxy INTEGER NOT NULL DEFAULT 0;
|]

down_m20240417_rcv_files_only_via_proxy :: Query
down_m20240417_rcv_files_only_via_proxy =
    [sql|
ALTER TABLE rcv_files DROP COLUMN only_via_proxy;
|]
