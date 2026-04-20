{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260410_receive_attempts where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260410_receive_attempts :: Text
m20260410_receive_attempts =
  [r|
ALTER TABLE rcv_messages ADD COLUMN receive_attempts SMALLINT NOT NULL DEFAULT 0;
|]

down_m20260410_receive_attempts :: Text
down_m20260410_receive_attempts =
  [r|
ALTER TABLE rcv_messages DROP COLUMN receive_attempts;
|]
