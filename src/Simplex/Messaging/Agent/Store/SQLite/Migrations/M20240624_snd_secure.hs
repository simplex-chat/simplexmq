{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240624_snd_secure where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240624_snd_secure :: Query
m20240624_snd_secure =
    [sql|
ALTER TABLE rcv_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;
ALTER TABLE snd_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;
|]

down_m20240624_snd_secure :: Query
down_m20240624_snd_secure =
    [sql|
ALTER TABLE rcv_queues DROP COLUMN snd_secure;
ALTER TABLE snd_queues DROP COLUMN snd_secure;
|]
