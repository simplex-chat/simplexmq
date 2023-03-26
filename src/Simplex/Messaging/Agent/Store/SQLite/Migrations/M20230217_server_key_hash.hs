{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230217_server_key_hash where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- server_key_hash is not null for records whose entities refer to a server
-- that was previously saved with the same host and port but different key hash
m20230217_server_key_hash :: Query
m20230217_server_key_hash =
  [sql|
ALTER TABLE rcv_queues ADD COLUMN server_key_hash BLOB;

ALTER TABLE snd_queues ADD COLUMN server_key_hash BLOB;

ALTER TABLE ntf_subscriptions ADD COLUMN smp_server_key_hash BLOB;

ALTER TABLE commands ADD COLUMN server_key_hash BLOB;
|]
