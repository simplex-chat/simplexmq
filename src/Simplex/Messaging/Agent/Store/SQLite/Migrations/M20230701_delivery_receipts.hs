{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230701_delivery_receipts where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230701_delivery_receipts :: Query
m20230701_delivery_receipts =
  [sql|
ALTER TABLE snd_messages ADD COLUMN rcpt_internal_id INTEGER;
ALTER TABLE snd_messages ADD COLUMN rcpt_status TEXT;

CREATE INDEX idx_snd_messages_rcpt_internal_id ON snd_messages(conn_id, rcpt_internal_id);
|]

down_m20230701_delivery_receipts :: Query
down_m20230701_delivery_receipts =
  [sql|
DROP INDEX idx_snd_messages_rcpt_internal_id;

ALTER TABLE snd_messages DROP COLUMN rcpt_internal_id;
ALTER TABLE snd_messages DROP COLUMN rcpt_status;
|]
