{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20231222_command_created_at where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20231222_command_created_at :: Query
m20231222_command_created_at =
  [sql|
ALTER TABLE commands ADD COLUMN created_at TEXT NOT NULL DEFAULT('1970-01-01 00:00:00');
CREATE INDEX idx_commands_server_commands ON commands(host, port, created_at, command_id);
|]

down_m20231222_command_created_at :: Query
down_m20231222_command_created_at =
  [sql|
DROP INDEX idx_commands_server_commands;
ALTER TABLE commands DROP COLUMN created_at;
|]
