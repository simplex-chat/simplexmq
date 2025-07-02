{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250702_conn_invitations_remove_cascade_delete where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250702_conn_invitations_remove_cascade_delete :: Query
m20250702_conn_invitations_remove_cascade_delete =
  [sql|
ALTER TABLE conn_invitations ADD COLUMN user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE;
CREATE INDEX idx_conn_invitations_user_id ON conn_invitations(user_id);

UPDATE conn_invitations
SET user_id = (
    SELECT user_id
    FROM connections
    WHERE connections.conn_id = conn_invitations.contact_conn_id
);


PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(
            sql,
            'contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE',
            'contact_conn_id BLOB REFERENCES connections ON DELETE SET NULL'
          )
WHERE name = 'conn_invitations' AND type = 'table';

PRAGMA writable_schema=0;
|]

down_m20250702_conn_invitations_remove_cascade_delete :: Query
down_m20250702_conn_invitations_remove_cascade_delete =
  [sql|
DROP INDEX idx_conn_invitations_user_id;
ALTER TABLE conn_invitations DROP COLUMN user_id;


PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = replace(
            sql,
            'contact_conn_id BLOB REFERENCES connections ON DELETE SET NULL',
            'contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE'
          )
WHERE name = 'conn_invitations' AND type = 'table';

PRAGMA writable_schema=0;
|]
