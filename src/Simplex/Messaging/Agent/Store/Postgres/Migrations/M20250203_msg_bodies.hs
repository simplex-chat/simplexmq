{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20250203_msg_bodies where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20250203_msg_bodies :: Text
m20250203_msg_bodies =
  [r|
ALTER TABLE snd_messages ADD COLUMN msg_encrypt_key BYTEA;
ALTER TABLE snd_messages ADD COLUMN padded_msg_len BIGINT;


CREATE TABLE snd_message_bodies (
  snd_message_body_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  agent_msg BYTEA NOT NULL DEFAULT ''::BYTEA
);
ALTER TABLE snd_messages ADD COLUMN snd_message_body_id BIGINT REFERENCES snd_message_bodies ON DELETE SET NULL;
CREATE INDEX idx_snd_messages_snd_message_body_id ON snd_messages(snd_message_body_id);
|]


down_m20250203_msg_bodies :: Text
down_m20250203_msg_bodies =
  [r|
DROP INDEX idx_snd_messages_snd_message_body_id;
ALTER TABLE snd_messages DROP COLUMN snd_message_body_id;
DROP TABLE snd_message_bodies;


ALTER TABLE snd_messages DROP COLUMN msg_encrypt_key;
ALTER TABLE snd_messages DROP COLUMN padded_msg_len;
|]
