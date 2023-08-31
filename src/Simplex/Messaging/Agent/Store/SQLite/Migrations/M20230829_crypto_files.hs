{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230829_crypto_files where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230829_crypto_files :: Query
m20230829_crypto_files =
  [sql|
ALTER TABLE rcv_files ADD COLUMN save_file_key BLOB;
ALTER TABLE rcv_files ADD COLUMN save_file_nonce BLOB;
ALTER TABLE snd_files ADD COLUMN src_file_key BLOB;
ALTER TABLE snd_files ADD COLUMN src_file_nonce BLOB;
|]

down_m20230829_crypto_files :: Query
down_m20230829_crypto_files =
  [sql|
ALTER TABLE rcv_files DROP COLUMN save_file_key;
ALTER TABLE rcv_files DROP COLUMN save_file_nonce;
ALTER TABLE snd_files DROP COLUMN src_file_key;
ALTER TABLE snd_files DROP COLUMN src_file_nonce;
|]
