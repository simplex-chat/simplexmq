{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20220202_initial where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220202_initial :: Query
m20220202_initial =
  [sql|
-- for easy testing
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

CREATE TABLE servers (
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  key_hash BYTEA NOT NULL,
  PRIMARY KEY (host, port)
);

CREATE TABLE connections (
  conn_id BYTEA NOT NULL PRIMARY KEY,
  conn_mode TEXT NOT NULL,
  last_internal_msg_id INTEGER NOT NULL DEFAULT 0,
  last_internal_rcv_msg_id INTEGER NOT NULL DEFAULT 0,
  last_internal_snd_msg_id INTEGER NOT NULL DEFAULT 0,
  last_external_snd_msg_id INTEGER NOT NULL DEFAULT 0,
  last_rcv_msg_hash BYTEA NOT NULL DEFAULT '',
  last_snd_msg_hash BYTEA NOT NULL DEFAULT '',
  smp_agent_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE rcv_queues (
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BYTEA NOT NULL,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  rcv_private_key BYTEA NOT NULL,
  rcv_dh_secret BYTEA NOT NULL,
  e2e_priv_key BYTEA NOT NULL,
  e2e_dh_secret BYTEA,
  snd_id BYTEA NOT NULL,
  snd_key BYTEA,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER,
  PRIMARY KEY (host, port, rcv_id),
  FOREIGN KEY (host, port) REFERENCES servers
    ON DELETE RESTRICT ON UPDATE CASCADE,
  UNIQUE (host, port, snd_id)
);

CREATE TABLE snd_queues (
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BYTEA NOT NULL,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_private_key BYTEA NOT NULL,
  e2e_dh_secret BYTEA NOT NULL,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (host, port, snd_id),
  FOREIGN KEY (host, port) REFERENCES servers
    ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE messages (
  conn_id BYTEA NOT NULL REFERENCES connections (conn_id)
    ON DELETE CASCADE,
  internal_id INTEGER NOT NULL,
  internal_ts TIMESTAMP NOT NULL,
  internal_rcv_id INTEGER,
  internal_snd_id INTEGER,
  msg_type BYTEA NOT NULL, -- (H)ELLO, (R)EPLY, (D)ELETE. Should SMP confirmation be saved too?
  msg_body BYTEA NOT NULL DEFAULT '',
  PRIMARY KEY (conn_id, internal_id)
);

CREATE TABLE rcv_messages (
  conn_id BYTEA NOT NULL,
  internal_rcv_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  external_snd_id INTEGER NOT NULL,
  broker_id BYTEA NOT NULL,
  broker_ts TIMESTAMP NOT NULL,
  internal_hash BYTEA NOT NULL,
  external_prev_snd_hash BYTEA NOT NULL,
  integrity BYTEA NOT NULL, -- in the list of keywords
  PRIMARY KEY (conn_id, internal_rcv_id),
  FOREIGN KEY (conn_id, internal_id) REFERENCES messages
    ON DELETE CASCADE
);

ALTER TABLE messages
ADD CONSTRAINT fk_messages_rcv_messages
  FOREIGN KEY (conn_id, internal_rcv_id) REFERENCES rcv_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE snd_messages (
  conn_id BYTEA NOT NULL,
  internal_snd_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  internal_hash BYTEA NOT NULL,
  previous_msg_hash BYTEA NOT NULL DEFAULT '',
  PRIMARY KEY (conn_id, internal_snd_id),
  FOREIGN KEY (conn_id, internal_id) REFERENCES messages
    ON DELETE CASCADE
);

ALTER TABLE messages
ADD CONSTRAINT fk_messages_snd_messages
  FOREIGN KEY (conn_id, internal_snd_id) REFERENCES snd_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY deferred;

CREATE TABLE conn_confirmations (
  confirmation_id BYTEA NOT NULL PRIMARY KEY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  e2e_snd_pub_key BYTEA NOT NULL, -- TODO per-queue key. Split?
  sender_key BYTEA NOT NULL, -- TODO per-queue key. Split?
  ratchet_state BYTEA NOT NULL,
  sender_conn_info BYTEA NOT NULL,
  accepted INTEGER NOT NULL,
  own_conn_info BYTEA,
  created_at TIMESTAMP NOT NULL DEFAULT (now())
);

CREATE TABLE conn_invitations (
  invitation_id BYTEA NOT NULL PRIMARY KEY,
  contact_conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  cr_invitation BYTEA NOT NULL,
  recipient_conn_info BYTEA NOT NULL,
  accepted INTEGER NOT NULL DEFAULT 0,
  own_conn_info BYTEA,
  created_at TIMESTAMP NOT NULL DEFAULT (now())
);

CREATE TABLE ratchets (
  conn_id BYTEA NOT NULL PRIMARY KEY REFERENCES connections
    ON DELETE CASCADE,
  -- x3dh keys are not saved on the sending side (the side accepting the connection)
  x3dh_priv_key_1 BYTEA,
  x3dh_priv_key_2 BYTEA,
  -- ratchet is initially empty on the receiving side (the side offering the connection)
  ratchet_state BYTEA,
  e2e_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE skipped_messages (
  skipped_message_id INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES ratchets
    ON DELETE CASCADE,
  header_key BYTEA NOT NULL,
  msg_n INTEGER NOT NULL,
  msg_key BYTEA NOT NULL
);
|]
