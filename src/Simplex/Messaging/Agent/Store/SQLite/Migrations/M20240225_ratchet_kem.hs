{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240225_ratchet_kem where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240225_ratchet_kem :: Query
m20240225_ratchet_kem =
    [sql|
ALTER TABLE ratchets ADD COLUMN pq_priv_kem BLOB;
ALTER TABLE connections ADD COLUMN pq_support INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN pq_encryption INTEGER NOT NULL DEFAULT 0;
|]

down_m20240225_ratchet_kem :: Query
down_m20240225_ratchet_kem =
    [sql|
ALTER TABLE ratchets DROP COLUMN pq_priv_kem;
ALTER TABLE connections DROP COLUMN pq_support;
ALTER TABLE messages DROP COLUMN pq_encryption;
|]
