{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230701_delivery_receipts where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230701_delivery_receipts :: Query
m20230701_delivery_receipts =
  [sql|
ALTER TABLE snd_messages ADD COLUMN hash BLOB NOT NULL DEFAULT x'';
ALTER TABLE snd_messages ADD COLUMN rcpt_internal_rcv_id INTEGER; -- internal rcv ID of receipt message
ALTER TABLE snd_messages ADD COLUMN rcpt_internal_id INTEGER; -- internal rcv ID of receipt message
ALTER TABLE snd_messages ADD COLUMN rcpt_status TEXT;
|]

down_m20230701_delivery_receipts :: Query
down_m20230701_delivery_receipts =
  [sql|
ALTER TABLE snd_messages DROP COLUMN hash;
ALTER TABLE snd_messages DROP COLUMN rcpt_internal_rcv_id;
ALTER TABLE snd_messages DROP COLUMN rcpt_internal_id;
ALTER TABLE snd_messages DROP COLUMN rcpt_status;
|]
