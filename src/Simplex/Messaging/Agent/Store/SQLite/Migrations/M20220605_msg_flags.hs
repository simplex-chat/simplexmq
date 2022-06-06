{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220605_msg_flags where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220605_msg_flags :: Query
m20220605_msg_flags =
  [sql|
ALTER TABLE messages ADD COLUMN msg_flags TEXT NULL;
|]
