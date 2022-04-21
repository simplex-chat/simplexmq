{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220301_snd_queue_keys where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220301_snd_queue_keys :: Query
m20220301_snd_queue_keys =
  [sql|
ALTER TABLE snd_queues ADD COLUMN snd_public_key BLOB;
ALTER TABLE snd_queues ADD COLUMN e2e_pub_key BLOB;
|]
