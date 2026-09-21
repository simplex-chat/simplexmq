{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260919_ratchet_ad where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260919_ratchet_ad :: Query
m20260919_ratchet_ad =
  [sql|
ALTER TABLE ratchets ADD COLUMN ratchet_ad BLOB;
ALTER TABLE ratchets ADD COLUMN ratchet_ad_pq BLOB;
  |]

down_m20260919_ratchet_ad :: Query
down_m20260919_ratchet_ad =
  [sql|
ALTER TABLE ratchets DROP COLUMN ratchet_ad_pq;
ALTER TABLE ratchets DROP COLUMN ratchet_ad;
  |]
