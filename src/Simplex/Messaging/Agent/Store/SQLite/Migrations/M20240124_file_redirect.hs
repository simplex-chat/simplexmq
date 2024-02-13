{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240124_file_redirect where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240124_file_redirect :: Query
m20240124_file_redirect =
    [sql|
ALTER TABLE snd_files ADD COLUMN redirect_size INTEGER;
ALTER TABLE snd_files ADD COLUMN redirect_digest BLOB;

ALTER TABLE rcv_files ADD COLUMN redirect_id INTEGER REFERENCES rcv_files ON DELETE CASCADE;
ALTER TABLE rcv_files ADD COLUMN redirect_entity_id BLOB;
ALTER TABLE rcv_files ADD COLUMN redirect_size INTEGER;
ALTER TABLE rcv_files ADD COLUMN redirect_digest BLOB;
|]

down_m20240124_file_redirect :: Query
down_m20240124_file_redirect =
    [sql|
ALTER TABLE snd_files DROP COLUMN redirect_size;
ALTER TABLE snd_files DROP COLUMN redirect_digest;

ALTER TABLE rcv_files DROP COLUMN redirect_id;
ALTER TABLE rcv_files DROP COLUMN redirect_entity_id;
ALTER TABLE rcv_files DROP COLUMN redirect_size;
ALTER TABLE rcv_files DROP COLUMN redirect_digest;
|]
