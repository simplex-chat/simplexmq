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
      last_rcv_msg_id INTEGER,
      last_snd_msg_id INTEGER,
      PRIMARY KEY (conn_alias),
      FOREIGN KEY (rcv_host, rcv_port, rcv_id) REFERENCES rcv_queues (host, port, rcv_id),
      FOREIGN KEY (snd_host, snd_port, snd_id) REFERENCES snd_queues (host, port, snd_id)
    ) WITHOUT ROWID;
  |]

messages :: Query
messages =
  [sql|
    CREATE TABLE IF NOT EXISTS messages(
      agent_msg_id INTEGER PRIMARY KEY,
      agent_timestamp TEXT NOT NULL,
      conn_alias TEXT NOT NULL,
      rcv_msg_id INTEGER,
      snd_msg_id INTEGER,
      message BLOB NOT NULL,
      msg_status TEXT NOT NULL,
      FOREIGN KEY (conn_alias) REFERENCES connections (conn_alias),
      FOREIGN KEY (conn_alias, rcv_msg_id) REFERENCES rcv_messages (conn_alias, rcv_msg_id),
      FOREIGN KEY (conn_alias, snd_msg_id) REFERENCES snd_messages (conn_alias, snd_msg_id),
    );
  |]

-- messages agent receives - sender_msg_id is id of the message at sender;
-- sender_msg_id corresponds to snd_msg_id from the sending side
-- TODO remove this comment
-- the order of insert into rcv_ and snd_messages tables (all in transaction):
-- 1. look up 'last_<rcv/snd>_msg_id' from 'connections' table;
-- 2. insert into 'messages' table - we get 'agent_msg_id' via autoincrement;
-- 3. insert into '<rcv/snd>_messages' table - it has deffered fk;
-- 4. update 'last_<rcv/snd>_msg_id' in 'connections' table - application is responsible for consistency.
-- * investigate if it's possible to select and update in one query in sqlite
-- ? deferred fks are in assumption it's more convenient to delete from 'messages' side using agent_msg_id,
-- ? otherwise we could've just have unique constraints on 'messages' table and no foreign keys here
rcvMessages :: Query
rcvMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS rcv_messages(
      agent_msg_id INTEGER NOT NULL,
      conn_alias TEXT NOT NULL,
      rcv_msg_id INTEGER NOT NULL,
      broker_msg_id INTEGER NOT NULL,
      broker_timestamp TEXT NOT NULL,
      sender_msg_id INTEGER NOT NULL,
      sender_timestamp TEXT NOT NULL,
      PRIMARY KEY (conn_alias, rcv_msg_id),
      FOREIGN KEY (agent_msg_id)
        REFERENCES messages (agent_msg_id)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED
    );
  |]

-- messages agent sends - snd_msg_id is id of the message sent / to be sent,
-- as in its number in order of sending
sndMessages :: Query
sndMessages =
  [sql|
    CREATE TABLE IF NOT EXISTS snd_messages(
      agent_msg_id INTEGER NOT NULL,
      conn_alias TEXT NOT NULL,
      snd_msg_id INTEGER NOT NULL,
      PRIMARY KEY (conn_alias, snd_msg_id),
      FOREIGN KEY (agent_msg_id)
        REFERENCES messages (agent_msg_id)
        ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED
    );
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
