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

ALTER TABLE connections ADD COLUMN user_id INTEGER DEFAULT 1 CHECK (user_id NOT NULL)
REFERENCES users ON DELETE CASCADE;

CREATE INDEX idx_connections_user ON connections(user_id);
CREATE INDEX idx_rcv_queues_conn_id ON rcv_queues(conn_id);
CREATE INDEX idx_snd_queues_conn_id ON snd_queues(conn_id);
CREATE INDEX idx_messages_conn_id ON messages(conn_id);
CREATE INDEX idx_messages_rcv_message ON messages(conn_id, internal_rcv_id);
CREATE INDEX idx_messages_snd_message ON messages(conn_id, internal_snd_id);
CREATE INDEX idx_rcv_messages_message ON rcv_messages(conn_id, internal_id);
CREATE INDEX idx_snd_messages_message ON snd_messages(conn_id, internal_id);
CREATE INDEX idx_conn_confirmations_conn_id on conn_confirmations(conn_id);
CREATE INDEX idx_conn_invitations_conn_id on conn_invitations(contact_conn_id);
CREATE INDEX idx_ratchets_conn_id on ratchets(conn_id);
CREATE INDEX idx_skipped_messages_conn_id on skipped_messages(conn_id);
CREATE INDEX idx_commands_conn_id on commands(conn_id);

UPDATE connections SET user_id = 1;

PRAGMA ignore_check_constraints=OFF;
|]
