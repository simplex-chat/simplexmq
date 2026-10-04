{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260929_skipped_messages_index where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260929_skipped_messages_index :: Text
m20260929_skipped_messages_index =
  [r|
DROP INDEX idx_skipped_messages_conn_id;
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id, skipped_message_id);
|]

down_m20260929_skipped_messages_index :: Text
down_m20260929_skipped_messages_index =
  [r|
DROP INDEX idx_skipped_messages_conn_id;
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id);
|]
