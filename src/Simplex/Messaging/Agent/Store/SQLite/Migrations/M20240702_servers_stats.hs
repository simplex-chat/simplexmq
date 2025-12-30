{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240702_servers_stats where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- servers_stats_id: dummy id, there should always only be one record with servers_stats_id = 1
-- servers_stats: overall accumulated stats, past and session, reset to null on stats reset
-- started_at: starting point of tracking stats, reset on stats reset
m20240702_servers_stats :: Query
m20240702_servers_stats =
    [sql|
CREATE TABLE servers_stats(
  servers_stats_id INTEGER PRIMARY KEY,
  servers_stats TEXT,
  started_at TEXT NOT NULL DEFAULT(datetime('now')),
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);

INSERT INTO servers_stats (servers_stats_id) VALUES (1);
|]

down_m20240702_servers_stats :: Query
down_m20240702_servers_stats =
    [sql|
DROP TABLE servers_stats;
|]
