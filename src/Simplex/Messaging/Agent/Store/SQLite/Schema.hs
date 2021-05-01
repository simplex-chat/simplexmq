{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema (createSchema) where

import Database.SQLite.Simple (Connection, Query, execute_)
import Database.SQLite.Simple.QQ (sql)

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_
    (execute_ conn)
    [ servers,
      rcvQueues,
      sndQueues,
      connections,
      messages,
      rcvMessages,
      sndMessages
    ]

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
      last_external_snd_msg_id INTEGER NOT NULL,
      last_rcv_msg_hash BLOB NOT NULL,
      last_snd_msg_hash BLOB NOT NULL,
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
      hash BLOB NOT NULL,
      prev_snd_hash BLOB NOT NULL,
      integrity BLOB NOT NULL,
      PRIMARY KEY (conn_alias, internal_rcv_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE
    ) WITHOUT ROWID;
  |]

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
      hash BLOB NOT NULL,
      PRIMARY KEY (conn_alias, internal_snd_id),
      FOREIGN KEY (conn_alias, internal_id)
        REFERENCES messages (conn_alias, internal_id)
        ON DELETE CASCADE
    ) WITHOUT ROWID;
  |]
