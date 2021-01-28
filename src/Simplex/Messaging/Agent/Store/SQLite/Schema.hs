{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple
import Database.SQLite.Simple.QQ (sql)

-- service_name is either a service name or a port number, see Network.Socket.Info.ServiceName
servers :: Query
servers =
  [sql|
    CREATE TABLE IF NOT EXISTS servers(
      host TEXT NOT NULL,
      service_name TEXT NOT NULL,
      key_hash BLOB,
      PRIMARY KEY (host, service_name)
    ) WITHOUT ROWID;
  |]

rcvQueues :: Query
rcvQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS rcv_queues(
      host TEXT NOT NULL,
      service_name TEXT NOT NULL,
      rcv_id BLOB NOT NULL,
      conn_alias TEXT NOT NULL,
      rcv_private_key BLOB NOT NULL,
      snd_id BLOB,
      snd_key BLOB,
      decrypt_key BLOB NOT NULL,
      verify_key BLOB,
      status TEXT NOT NULL,
      PRIMARY KEY(host, service_name, rcv_id),
      FOREIGN KEY(host, service_name) REFERENCES servers(host, service_name),
      FOREIGN KEY(conn_alias)
        REFERENCES connections(conn_alias)
        DEFERRABLE INITIALLY DEFERRED,
      UNIQUE (host, service_name, snd_id)
    ) WITHOUT ROWID;
  |]

sndQueues :: Query
sndQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS snd_queues(
      host TEXT NOT NULL,
      service_name TEXT NOT NULL,
      snd_id BLOB NOT NULL,
      conn_alias TEXT NOT NULL,
      snd_private_key BLOB NOT NULL,
      encrypt_key BLOB NOT NULL,
      sign_key BLOB NOT NULL,
      status TEXT NOT NULL,
      PRIMARY KEY(host, service_name, snd_id),
      FOREIGN KEY(host, service_name) REFERENCES servers(host, service_name),
      FOREIGN KEY(conn_alias)
        REFERENCES connections(conn_alias)
        DEFERRABLE INITIALLY DEFERRED
    ) WITHOUT ROWID;
  |]

connections :: Query
connections =
  [sql|
    CREATE TABLE IF NOT EXISTS connections(
      conn_alias TEXT NOT NULL,
      rcv_host TEXT,
      rcv_service_name TEXT,
      rcv_id BLOB,
      snd_host TEXT,
      snd_service_name TEXT,
      snd_id BLOB,
      PRIMARY KEY(conn_alias),
      FOREIGN KEY(rcv_host, rcv_service_name, rcv_id)
        REFERENCES rcv_queues(host, service_name, rcv_id)
        ON DELETE CASCADE,
      FOREIGN KEY(snd_host, snd_service_name, snd_id)
        REFERENCES snd_queues(host, service_name, snd_id)
        ON DELETE CASCADE
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
  mapM_ (execute_ conn) [servers, rcvQueues, sndQueues, connections, messages]
