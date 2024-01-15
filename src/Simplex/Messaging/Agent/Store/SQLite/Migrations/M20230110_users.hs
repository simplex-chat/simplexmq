{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230110_users where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230110_users :: Query
m20230110_users =
  [sql|
PRAGMA ignore_check_constraints=ON;

CREATE TABLE users (
  user_id INTEGER PRIMARY KEY AUTOINCREMENT
);

INSERT INTO users (user_id) VALUES (1);

ALTER TABLE connections ADD COLUMN user_id INTEGER CHECK (user_id NOT NULL)
REFERENCES users ON DELETE CASCADE;

CREATE INDEX idx_connections_user ON connections(user_id);

CREATE INDEX idx_commands_conn_id ON commands(conn_id);

UPDATE connections SET user_id = 1;

PRAGMA ignore_check_constraints=OFF;
|]
