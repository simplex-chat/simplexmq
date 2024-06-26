{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240624_snd_secure where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240624_snd_secure :: Query
m20240624_snd_secure =
    [sql|
ALTER TABLE rcv_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;
ALTER TABLE snd_queues ADD COLUMN snd_secure INTEGER NOT NULL DEFAULT 0;

PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(sql, 'sender_key BLOB NOT NULL,', 'sender_key BLOB,')
WHERE name = 'conn_confirmations' AND type = 'table';

PRAGMA writable_schema=0;
|]

down_m20240624_snd_secure :: Query
down_m20240624_snd_secure =
    [sql|
ALTER TABLE rcv_queues DROP COLUMN snd_secure;
ALTER TABLE snd_queues DROP COLUMN snd_secure;

PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(sql, 'sender_key BLOB,', 'sender_key BLOB NOT NULL,')
WHERE name = 'conn_confirmations' AND type = 'table';

PRAGMA writable_schema=0;
|]
