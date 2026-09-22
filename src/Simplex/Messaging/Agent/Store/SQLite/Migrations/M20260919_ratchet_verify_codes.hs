{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260919_ratchet_verify_codes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260919_ratchet_verify_codes :: Query
m20260919_ratchet_verify_codes =
  [sql|
ALTER TABLE ratchets ADD COLUMN rc_verify_code_ad BLOB;
ALTER TABLE ratchets ADD COLUMN rc_verify_code_pq BLOB;
  |]

down_m20260919_ratchet_verify_codes :: Query
down_m20260919_ratchet_verify_codes =
  [sql|
ALTER TABLE ratchets DROP COLUMN rc_verify_code_pq;
ALTER TABLE ratchets DROP COLUMN rc_verify_code_ad;
  |]
