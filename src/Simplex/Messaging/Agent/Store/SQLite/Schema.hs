{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema (createSchema) where

import Database.SQLite.Simple (Connection, Query, execute_)
import Database.SQLite.Simple.QQ (sql)

enableFKs :: Query
enableFKs = "PRAGMA foreign_keys = ON;"

-- port is either a port number or a service name, see Network.Socket.Info.ServiceName
servers :: Query
servers =
  [sql|
    CREATE TABLE IF NOT EXISTS servers(
      host TEXT NOT NULL,
      port TEXT NOT NULL,
      key_hash BLOB,
      PRIMARY KEY (host, port)
    ) WITHOUT ROWID;
  |]

rcvQueues :: Query
rcvQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS rcv_queues(
      host TEXT NOT NULL,
      port TEXT NOT NULL,
      rcv_id BLOB NOT NULL,
      conn_alias BLOB NOT NULL,
      rcv_private_key BLOB NOT NULL,
      snd_id BLOB,
      snd_key BLOB,
      decrypt_key BLOB NOT NULL,
      verify_key BLOB,
      status TEXT NOT NULL,
      PRIMARY KEY (host, port, rcv_id),
      FOREIGN KEY (host, port) REFERENCES servers (host, port),
      FOREIGN KEY (conn_alias)
        REFERENCES connections (conn_alias)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED,
      UNIQUE (host, port, snd_id)
    ) WITHOUT ROWID;
  |]

sndQueues :: Query
sndQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS snd_queues(
      host TEXT NOT NULL,
      port TEXT NOT NULL,
      snd_id BLOB NOT NULL,
      conn_alias BLOB NOT NULL,
      snd_private_key BLOB NOT NULL,
      encrypt_key BLOB NOT NULL,
      sign_key BLOB NOT NULL,
      status TEXT NOT NULL,
      PRIMARY KEY (host, port, snd_id),
      FOREIGN KEY (host, port) REFERENCES servers (host, port),
      FOREIGN KEY (conn_alias)
        REFERENCES connections (conn_alias)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED
    ) WITHOUT ROWID;
  |]

connections :: Query
connections =
  [sql|
    CREATE TABLE IF NOT EXISTS connections(
      conn_alias BLOB NOT NULL,
      rcv_host TEXT,
      rcv_port TEXT,
      rcv_id BLOB,
      snd_host TEXT,
      snd_port TEXT,
      snd_id BLOB,
      last_internal_msg_id INTEGER NOT NULL,
      last_internal_rcv_msg_id INTEGER NOT NULL,
      last_internal_snd_msg_id INTEGER NOT NULL,
      PRIMARY KEY (conn_alias),
      FOREIGN KEY (rcv_host, rcv_port, rcv_id) REFERENCES rcv_queues (host, port, rcv_id),
      FOREIGN KEY (snd_host, snd_port, snd_id) REFERENCES snd_queues (host, port, snd_id)
    ) WITHOUT ROWID;
  |]

messages :: Query
messages =
  [sql|
    CREATE TABLE IF NOT EXISTS messages(
      conn_alias BLOB NOT NULL,
      internal_id INTEGER NOT NULL,
      internal_ts TEXT NOT NULL,
      internal_rcv_id INTEGER,
      internal_snd_id INTEGER,
      body TEXT NOT NULL,
      PRIMARY KEY (conn_alias, internal_id),
      FOREIGN KEY (conn_alias)
        REFERENCES connections (conn_alias)
        ON DELETE CASCADE,
      FOREIGN KEY (conn_alias, internal_rcv_id)
        REFERENCES rcv_messages (conn_alias, internal_rcv_id)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY (conn_alias, internal_snd_id)
        REFERENCES snd_messages (conn_alias, internal_snd_id)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED
    ) WITHOUT ROWID;
  |]

-- table containing metadata of messages agent receives
-- * external_snd_id
--   id of the message at sender, i.e. 'external_snd_id' corresponds to 'internal_snd_id' from the sender's side.
-- * rcv_status
--   one of [semantically]: "received", "acknowledged to broker", "acknowledged to sender", changed in this order.
-- * ack_brocker_ts
--   ts of acknowledgement to broker, corresponds to "acknowledged to broker" status, should be null until that;
--   do not mix up with 'broker_ts' - ts created at broker after broker receives the message from sender.
-- * ack_sender_ts
--   ts of acknowledgement to sender, corresponds to "acknowledged to sender" status, should be null until that;
--   do not mix up with 'external_snd_ts' - ts created at sender before sending (which corresponds to 'internal_ts').
--
-- the order of inserting rcv messages - in transaction do:
-- 1. look up 'last_internal_msg_id' and 'last_internal_rcv_msg_id' from 'connections' table;
-- 2. increment internal ids and insert into 'messages' table;
-- 3. insert into 'rcv_messages' table;
-- 4. update internal ids in 'connections' table - application is responsible for consistency.
rcvMessages :: Query
rcvMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS rcv_messages(
      conn_alias BLOB NOT NULL,
      internal_rcv_id INTEGER NOT NULL,
      internal_id INTEGER NOT NULL,
      external_snd_id INTEGER NOT NULL,
      external_snd_ts TEXT NOT NULL,
      broker_id BLOB NOT NULL,
      broker_ts TEXT NOT NULL,
      rcv_status TEXT NOT NULL,
      ack_brocker_ts TEXT,
      ack_sender_ts TEXT,
      PRIMARY KEY (conn_alias, internal_rcv_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE
    ) WITHOUT ROWID;
  |]

-- table containing metadata of messages agent sends
-- * internal_snd_id
--   id of the message sent / to be sent, as in its number in order of sending.
-- * snd_status
--   one of [semantically]: "created", "sent", "delivered", changed in this order.
-- * sent_ts
--   ts of msg received by broker, corresponds to "sent" status, should be null until that.
-- * delivered_ts
--   ts of msg received by recipient, corresponds to "delivered" status, should be null until that.
--
-- the order of inserting snd messages - in transaction do:
-- 1. look up 'last_internal_msg_id' and 'last_internal_snd_msg_id' from 'connections' table;
-- 2. increment internal ids and insert into 'messages' table;
-- 3. insert into 'snd_messages' table;
-- 4. update internal ids in 'connections' table - application is responsible for consistency.
sndMessages :: Query
sndMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS snd_messages(
      conn_alias BLOB NOT NULL,
      internal_snd_id INTEGER NOT NULL,
      internal_id INTEGER NOT NULL,
      snd_status TEXT NOT NULL,
      sent_ts TEXT,
      delivered_ts TEXT,
      PRIMARY KEY (conn_alias, internal_snd_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE
    ) WITHOUT ROWID;
  |]

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_
    (execute_ conn)
    [ enableFKs,
      servers,
      rcvQueues,
      sndQueues,
      connections,
      messages,
      rcvMessages,
      sndMessages
    ]
