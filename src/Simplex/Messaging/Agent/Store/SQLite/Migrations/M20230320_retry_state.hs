{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230320_retry_state where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230320_retry_state :: Query
m20230320_retry_state =
  [sql|
ALTER TABLE snd_messages ADD COLUMN retry_int_slow INTEGER;
ALTER TABLE snd_messages ADD COLUMN retry_int_fast INTEGER;
|]

-- this is for tests, older versions do not support down migrations
down_m20230320_retry_state :: Query
down_m20230320_retry_state =
  [sql|
ALTER TABLE snd_messages DROP COLUMN retry_int_fast;
ALTER TABLE snd_messages DROP COLUMN retry_int_slow;
|]
