{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230120_delete_errors where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230120_delete_errors :: Query
m20230120_delete_errors =
  [sql|
PRAGMA ignore_check_constraints=ON;

ALTER TABLE rcv_queues ADD COLUMN delete_errors INTEGER DEFAULT 0 CHECK (delete_errors NOT NULL);
UPDATE rcv_queues SET delete_errors = 0;

ALTER TABLE users ADD COLUMN deleted INTEGER DEFAULT 0 CHECK (deleted NOT NULL);
UPDATE users SET deleted = 0;

PRAGMA ignore_check_constraints=OFF;
|]
