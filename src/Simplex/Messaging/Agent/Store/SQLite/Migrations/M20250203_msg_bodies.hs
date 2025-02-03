{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250203_msg_bodies where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250203_msg_bodies :: Query
m20250203_msg_bodies =
    [sql|
CREATE TABLE msg_bodies (
  msg_body_id INTEGER PRIMARY KEY,
  msg_body BLOB NOT NULL DEFAULT x''
)

ALTER TABLE snd_message_deliveries ADD COLUMN msg_body_id INTEGER REFERENCES msg_bodies ON DELETE CASCADE;
ALTER TABLE snd_message_deliveries ADD COLUMN pq_encryption_intent INTEGER NOT NULL DEFAULT 0;
-- other snd_message_deliveries fields - per delivery (keys)?

-- fkey to msg_bodies
-- on each delivery check if other deliveries reference the same msg_body_id, if not delete it
|]

down_m20250203_msg_bodies :: Query
down_m20250203_msg_bodies =
    [sql|
ALTER TABLE snd_message_deliveries DROP COLUMN pq_encryption_intent;
ALTER TABLE snd_message_deliveries DROP COLUMN msg_body_id;

DROP TABLE msg_bodies;
|]
