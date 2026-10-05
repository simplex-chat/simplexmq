{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20260928_commands_autoincrement where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20260928_commands_autoincrement :: Query
m20260928_commands_autoincrement =
  [sql|
INSERT INTO sqlite_sequence (name, seq)
SELECT 'commands', MAX(ROWID) FROM commands;

PRAGMA writable_schema=1;

UPDATE sqlite_master SET sql = replace(sql, 'command_id INTEGER PRIMARY KEY,', 'command_id INTEGER PRIMARY KEY AUTOINCREMENT,')
WHERE name = 'commands' AND type = 'table';

PRAGMA writable_schema=RESET;
  |]

down_m20260928_commands_autoincrement :: Query
down_m20260928_commands_autoincrement =
  [sql|
DELETE FROM sqlite_sequence WHERE name = 'commands';

PRAGMA writable_schema=1;

UPDATE sqlite_master SET sql = replace(sql, 'command_id INTEGER PRIMARY KEY AUTOINCREMENT,', 'command_id INTEGER PRIMARY KEY,')
WHERE name = 'commands' AND type = 'table';

PRAGMA writable_schema=RESET;
  |]
