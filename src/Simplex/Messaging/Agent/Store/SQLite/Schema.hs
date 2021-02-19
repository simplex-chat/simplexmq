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
      conn_alias TEXT NOT NULL,
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
      conn_alias TEXT NOT NULL,
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
      conn_alias TEXT NOT NULL,
      rcv_host TEXT,
      rcv_port TEXT,
      rcv_id BLOB,
      snd_host TEXT,
      snd_port TEXT,
      snd_id BLOB,
      last_internal_msg_id INTEGER,
      last_sending_msg_id INTEGER,
      PRIMARY KEY (conn_alias),
      FOREIGN KEY (rcv_host, rcv_port, rcv_id) REFERENCES rcv_queues (host, port, rcv_id),
      FOREIGN KEY (snd_host, snd_port, snd_id) REFERENCES snd_queues (host, port, snd_id)
    ) WITHOUT ROWID;
  |]

messages :: Query
messages =
  [sql|
    CREATE TABLE IF NOT EXISTS messages(
      conn_alias TEXT NOT NULL,
      internal_id INTEGER NOT NULL,
      internal_ts TEXT NOT NULL,
      external_senders_id INTEGER,
      external_sending_id INTEGER,
      body BLOB NOT NULL,
      status TEXT NOT NULL,
      PRIMARY KEY (conn_alias, internal_id),
      FOREIGN KEY (conn_alias) REFERENCES connections (conn_alias),
      FOREIGN KEY (conn_alias, internal_id, external_senders_id)
        REFERENCES rcv_messages (conn_alias, internal_id, senders_id)
        DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY (conn_alias, internal_id, external_sending_id)
        REFERENCES snd_messages (conn_alias, internal_id, sending_id)
        DEFERRABLE INITIALLY DEFERRED
    ) WITHOUT ROWID;
  |]

-- messages agent receives - senders_id is id of the message at sender,
-- i.e. senders_id corresponds to sending_id from the sender's side
-- TODO remove this comment
-- the order of insert into rcv_messages tables (all in transaction):
-- 1. look up 'last_internal_msg_id' from 'connections' table;
-- 2. insert into 'messages' table;
-- 3. insert into 'rcv_messages' table;
-- 4. update 'last_internal_msg_id' in 'connections' table - application is responsible for consistency.
-- * investigate if it's possible to select and update in one query in sqlite
rcvMessages :: Query
rcvMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS rcv_messages(
      conn_alias TEXT NOT NULL,
      internal_id INTEGER NOT NULL,
      senders_id INTEGER NOT NULL,
      senders_ts TEXT NOT NULL,
      broker_id INTEGER NOT NULL,
      broker_ts TEXT NOT NULL,
      PRIMARY KEY (conn_alias, internal_id, senders_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE
    ) WITHOUT ROWID;
  |]
-- ? UNIQUE (conn_alias, senders_id)
-- ? UNIQUE (conn_alias, broker_id)

-- messages agent sends - sending_id is id of the message sent / to be sent,
-- as in its number in order of sending
-- TODO remove this comment
-- the order of insert into snd_messages tables (all in transaction):
-- 1. look up 'last_internal_msg_id' and 'last_sending_msg_id' from 'connections' table;
-- 2. insert into 'messages' table;
-- 3. insert into 'snd_messages' table;
-- 4. update both 'last_..._msg_id' fields in 'connections' table - application is responsible for consistency.
sndMessages :: Query
sndMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS snd_messages(
      conn_alias TEXT NOT NULL,
      internal_id INTEGER NOT NULL,
      sending_id INTEGER NOT NULL,
      sending_ts TEXT NOT NULL,
      PRIMARY KEY (conn_alias, internal_id, sending_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE,
      UNIQUE (conn_alias, sending_id)
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
