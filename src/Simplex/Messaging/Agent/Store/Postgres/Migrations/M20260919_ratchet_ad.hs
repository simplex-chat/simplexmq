{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260919_ratchet_ad where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260919_ratchet_ad :: Text
m20260919_ratchet_ad =
  [r|
ALTER TABLE ratchets ADD COLUMN ratchet_ad BYTEA;
ALTER TABLE ratchets ADD COLUMN ratchet_ad_pq BYTEA;
|]

down_m20260919_ratchet_ad :: Text
down_m20260919_ratchet_ad =
  [r|
ALTER TABLE ratchets DROP COLUMN ratchet_ad_pq;
ALTER TABLE ratchets DROP COLUMN ratchet_ad;
|]
