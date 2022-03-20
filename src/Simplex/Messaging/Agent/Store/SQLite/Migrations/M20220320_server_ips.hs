{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220320_server_ips where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220320_server_ips :: Query
m20220320_server_ips =
  [sql|
UPDATE servers SET host = '178.79.168.175' WHERE host = 'smp8.simplex.im';
UPDATE servers SET host = '178.79.169.107' WHERE host = 'smp9.simplex.im';
UPDATE servers SET host = '45.33.54.229' WHERE host = 'smp10.simplex.im';
|]
