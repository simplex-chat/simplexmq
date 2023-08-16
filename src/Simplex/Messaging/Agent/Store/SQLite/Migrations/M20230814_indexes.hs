{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230814_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230814_indexes :: Query
m20230814_indexes =
  [sql|
DROP INDEX idx_messages_internal_snd_id_ts;

CREATE INDEX idx_messages_internal_ts ON messages(internal_ts);
|]

down_m20230814_indexes :: Query
down_m20230814_indexes =
  [sql|
DROP INDEX idx_messages_internal_ts;

CREATE INDEX idx_messages_internal_snd_id_ts ON messages(internal_snd_id, internal_ts);
|]
