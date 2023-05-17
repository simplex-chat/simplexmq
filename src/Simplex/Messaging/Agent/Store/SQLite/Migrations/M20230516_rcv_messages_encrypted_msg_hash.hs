{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230516_rcv_messages_encrypted_msg_hash where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230516_rcv_messages_encrypted_msg_hash :: Query
m20230516_rcv_messages_encrypted_msg_hash =
  [sql|
ALTER TABLE rcv_messages ADD COLUMN encrypted_msg_hash BLOB;
|]

down_m20230516_rcv_messages_encrypted_msg_hash :: Query
down_m20230516_rcv_messages_encrypted_msg_hash =
  [sql|
ALTER TABLE rcv_messages DROP COLUMN encrypted_msg_hash;
|]
