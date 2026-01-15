{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250702_conn_invitations_remove_cascade_delete where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250702_conn_invitations_remove_cascade_delete :: Query
m20250702_conn_invitations_remove_cascade_delete =
  [sql|
PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(
            sql,
            'contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE',
            'contact_conn_id BLOB REFERENCES connections ON DELETE SET NULL'
          )
WHERE name = 'conn_invitations' AND type = 'table';

PRAGMA writable_schema=RESET;
|]

down_m20250702_conn_invitations_remove_cascade_delete :: Query
down_m20250702_conn_invitations_remove_cascade_delete =
  [sql|
PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(
            sql,
            'contact_conn_id BLOB REFERENCES connections ON DELETE SET NULL',
            'contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE'
          )
WHERE name = 'conn_invitations' AND type = 'table';

PRAGMA writable_schema=RESET;
|]
