{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240225_ratchet_kem where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240225_ratchet_kem :: Query
m20240225_ratchet_kem =
    [sql|
ALTER TABLE ratchets ADD COLUMN pq_priv_kem BLOB;
|]

down_m20240225_ratchet_kem :: Query
down_m20240225_ratchet_kem =
    [sql|
ALTER TABLE ratchets DROP COLUMN pq_priv_kem;
|]
