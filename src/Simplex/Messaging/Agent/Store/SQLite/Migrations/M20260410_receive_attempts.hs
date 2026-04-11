{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260410_receive_attempts where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260410_receive_attempts :: Query
m20260410_receive_attempts =
  [sql|
ALTER TABLE rcv_messages ADD COLUMN receive_attempts INTEGER NOT NULL DEFAULT 0;
|]

down_m20260410_receive_attempts :: Query
down_m20260410_receive_attempts =
  [sql|
ALTER TABLE rcv_messages DROP COLUMN receive_attempts;
|]
