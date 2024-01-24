{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240124_file_redirect where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240124_file_redirect :: Query
m20240124_file_redirect =
    [sql|
ALTER TABLE snd_files ADD COLUMN redirect INTEGER DEFAULT 0;
ALTER TABLE rcv_files ADD COLUMN redirect INTEGER DEFAULT 0;
|]

down_m20240124_file_redirect :: Query
down_m20240124_file_redirect =
    [sql|
ALTER TABLE snd_files DROP COLUMN redirect;
ALTER TABLE rcv_files DROP COLUMN redirect;
|]
