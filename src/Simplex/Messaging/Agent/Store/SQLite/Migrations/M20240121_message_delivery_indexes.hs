{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240121_message_delivery_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240121_message_delivery_indexes :: Query
m20240121_message_delivery_indexes =
    [sql|
CREATE INDEX idx_messages_snd_expired ON messages(conn_id, internal_snd_id, internal_ts);
CREATE INDEX idx_snd_message_deliveries_expired ON snd_message_deliveries(conn_id, snd_queue_id, failed, internal_id);
|]

down_m20240121_message_delivery_indexes :: Query
down_m20240121_message_delivery_indexes =
    [sql|
DROP INDEX idx_messages_snd_expired;
DROP INDEX idx_snd_message_deliveries_expired;
|]
