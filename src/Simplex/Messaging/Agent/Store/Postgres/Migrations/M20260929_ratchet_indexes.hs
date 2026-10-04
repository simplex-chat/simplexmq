{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20260929_ratchet_indexes where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20260929_ratchet_indexes :: Text
m20260929_ratchet_indexes =
  [r|
DROP INDEX idx_skipped_messages_conn_id;
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id, skipped_message_id);
CREATE INDEX idx_processed_ratchet_key_hashes_conn_id ON processed_ratchet_key_hashes(conn_id, processed_ratchet_key_hash_id);
|]

down_m20260929_ratchet_indexes :: Text
down_m20260929_ratchet_indexes =
  [r|
DROP INDEX idx_processed_ratchet_key_hashes_conn_id;
DROP INDEX idx_skipped_messages_conn_id;
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id);
|]
