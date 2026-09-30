{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260919_ratchet_verify_codes where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260919_ratchet_verify_codes :: Text
m20260919_ratchet_verify_codes =
  [r|
ALTER TABLE ratchets ADD COLUMN rc_verify_code_ad BYTEA;
ALTER TABLE ratchets ADD COLUMN rc_verify_code_pq BYTEA;
|]

down_m20260919_ratchet_verify_codes :: Text
down_m20260919_ratchet_verify_codes =
  [r|
ALTER TABLE ratchets DROP COLUMN rc_verify_code_pq;
ALTER TABLE ratchets DROP COLUMN rc_verify_code_ad;
|]
