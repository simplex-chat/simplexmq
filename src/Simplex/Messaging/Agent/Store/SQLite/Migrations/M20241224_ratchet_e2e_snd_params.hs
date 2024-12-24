{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20241224_ratchet_e2e_snd_params where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20241224_ratchet_e2e_snd_params :: Query
m20241224_ratchet_e2e_snd_params =
    [sql|
ALTER TABLE ratchets ADD COLUMN pq_pub_kem BLOB;
|]

down_m20241224_ratchet_e2e_snd_params :: Query
down_m20241224_ratchet_e2e_snd_params =
    [sql|
ALTER TABLE ratchets DROP COLUMN pq_pub_kem;
|]
