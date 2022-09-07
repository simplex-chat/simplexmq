{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220905_commands where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220905_commands :: Query
m20220905_commands =
  [sql|
CREATE TABLE commands (
  command_id INTEGER PRIMARY KEY,
  host TEXT,
  port TEXT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  command TEXT NOT NULL,
  command_version INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (host, port) REFERENCES servers
    ON DELETE RESTRICT ON UPDATE CASCADE
);
|]
