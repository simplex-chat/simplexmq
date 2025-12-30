{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250203_msg_bodies where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250203_msg_bodies :: Query
m20250203_msg_bodies =
    [sql|
ALTER TABLE snd_messages ADD COLUMN msg_encrypt_key BLOB;
ALTER TABLE snd_messages ADD COLUMN padded_msg_len INTEGER;


CREATE TABLE snd_message_bodies (
  snd_message_body_id INTEGER PRIMARY KEY,
  agent_msg BLOB NOT NULL DEFAULT x''
) STRICT;
ALTER TABLE snd_messages ADD COLUMN snd_message_body_id INTEGER REFERENCES snd_message_bodies ON DELETE SET NULL;
CREATE INDEX idx_snd_messages_snd_message_body_id ON snd_messages(snd_message_body_id);
|]

down_m20250203_msg_bodies :: Query
down_m20250203_msg_bodies =
    [sql|
DROP INDEX idx_snd_messages_snd_message_body_id;
ALTER TABLE snd_messages DROP COLUMN snd_message_body_id;
DROP TABLE snd_message_bodies;


ALTER TABLE snd_messages DROP COLUMN msg_encrypt_key;
ALTER TABLE snd_messages DROP COLUMN padded_msg_len;
|]
