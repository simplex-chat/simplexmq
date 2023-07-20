{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230720_delete_expired_messages where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230720_delete_expired_messages :: Query
m20230720_delete_expired_messages =
  [sql|
CREATE INDEX idx_messages_internal_snd_id_ts ON messages(internal_snd_id, internal_ts);

DELETE FROM messages WHERE internal_snd_id IS NOT NULL AND internal_ts < datetime('now', '-3 days');
|]

down_m20230720_delete_expired_messages :: Query
down_m20230720_delete_expired_messages =
  [sql|
DROP INDEX idx_messages_internal_snd_id_ts;
|]
