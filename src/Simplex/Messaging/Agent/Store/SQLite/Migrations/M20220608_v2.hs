{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220608_v2 where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220608_v2 :: Query
m20220608_v2 =
  [sql|
ALTER TABLE messages ADD COLUMN msg_flags TEXT NULL;

ALTER TABLE conn_confirmations ADD COLUMN smp_reply_queues BLOB NULL;

ALTER TABLE connections ADD COLUMN duplex_handshake INTEGER NULL DEFAULT 0;

ALTER TABLE rcv_messages ADD COLUMN user_ack INTEGER NULL DEFAULT 0;
|]
