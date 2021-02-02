{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple
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
      PRIMARY KEY(host, port, rcv_id),
      FOREIGN KEY(host, port) REFERENCES servers(host, port),
      FOREIGN KEY(conn_alias)
        REFERENCES connections(conn_alias)
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
      PRIMARY KEY(host, port, snd_id),
      FOREIGN KEY(host, port) REFERENCES servers(host, port),
      FOREIGN KEY(conn_alias)
        REFERENCES connections(conn_alias)
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
      PRIMARY KEY(conn_alias),
      FOREIGN KEY(rcv_host, rcv_port, rcv_id) REFERENCES rcv_queues(host, port, rcv_id),
      FOREIGN KEY(snd_host, snd_port, snd_id) REFERENCES snd_queues(host, port, snd_id)
    ) WITHOUT ROWID;
  |]

messages :: Query
messages =
  [sql|
    CREATE TABLE IF NOT EXISTS messages(
      agent_msg_id INTEGER NOT NULL,
      conn_alias TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      message BLOB NOT NULL,
      direction TEXT NOT NULL,
      msg_status TEXT NOT NULL,
      PRIMARY KEY(agent_msg_id, conn_alias),
      FOREIGN KEY(conn_alias) REFERENCES connections(conn_alias)
    ) WITHOUT ROWID;
  |]

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_ (execute_ conn) [enableFKs, servers, rcvQueues, sndQueues, connections, messages]
