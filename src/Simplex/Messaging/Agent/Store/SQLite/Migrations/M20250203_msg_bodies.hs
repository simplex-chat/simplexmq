{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250203_msg_bodies where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250203_msg_bodies :: Query
m20250203_msg_bodies =
    [sql|
ALTER TABLE snd_messages ADD COLUMN msg_encrypt_key BLOB;
ALTER TABLE snd_messages ADD COLUMN padded_msg_len INTEGER;


-- CREATE TABLE msg_bodies (
--   msg_body_id INTEGER PRIMARY KEY,
--   msg_body BLOB NOT NULL DEFAULT x''
-- )

-- ALTER TABLE snd_messages ADD COLUMN msg_body_id INTEGER REFERENCES msg_bodies ON DELETE CASCADE;

-- fkey to msg_bodies
-- on each delivery check if other deliveries reference the same msg_body_id, if not delete it
|]

down_m20250203_msg_bodies :: Query
down_m20250203_msg_bodies =
    [sql|
ALTER TABLE snd_messages DROP COLUMN msg_encrypt_key;
ALTER TABLE snd_messages DROP COLUMN padded_msg_len;


-- ALTER TABLE snd_messages DROP COLUMN msg_body_id;

-- DROP TABLE msg_bodies;
|]
