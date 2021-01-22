{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple
import Database.SQLite.Simple.QQ (sql)

servers :: Query
servers =
  [sql|
    CREATE TABLE IF NOT EXISTS servers
      ( server_id INTEGER PRIMARY KEY,
        host TEXT NOT NULL,
        port TEXT,
        key_hash BLOB,
        UNIQUE (host, port)
      )
  |]

receiveQueues :: Query
receiveQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS receive_queues
      ( receive_queue_id INTEGER PRIMARY KEY,
        server_id INTEGER REFERENCES servers(server_id) NOT NULL,
        rcv_id BLOB NOT NULL,
        rcv_private_key BLOB NOT NULL,
        snd_id BLOB,
        snd_key BLOB,
        decrypt_key BLOB NOT NULL,
        verify_key BLOB,
        status TEXT NOT NULL,
        ack_mode INTEGER NOT NULL,
        UNIQUE (server_id, rcv_id),
        UNIQUE (server_id, snd_id)
      )
  |]

sendQueues :: Query
sendQueues =
  [sql|
    CREATE TABLE IF NOT EXISTS send_queues
      ( send_queue_id INTEGER PRIMARY KEY,
        server_id INTEGER REFERENCES servers(server_id) NOT NULL,
        snd_id BLOB NOT NULL,
        snd_private_key BLOB NOT NULL,
        encrypt_key BLOB NOT NULL,
        sign_key BLOB NOT NULL,
        status TEXT NOT NULL,
        ack_mode INTEGER NOT NULL,
        UNIQUE (server_id, snd_id)
      )
  |]

connections :: Query
connections =
  [sql|
    CREATE TABLE IF NOT EXISTS connections
      ( connection_id INTEGER PRIMARY KEY,
        conn_alias TEXT UNIQUE,
        receive_queue_id INTEGER REFERENCES recipient_queues(receive_queue_id) UNIQUE,
        send_queue_id INTEGER REFERENCES sender_queues(send_queue_id) UNIQUE
      )
  |]

messages :: Query
messages =
  [sql|
    CREATE TABLE IF NOT EXISTS messages
      ( message_id INTEGER PRIMARY KEY,
        conn_alias TEXT REFERENCES connections(conn_alias),
        agent_msg_id INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        message BLOB NOT NULL,
        direction TEXT NOT NULL,
        msg_status TEXT NOT NULL
      )
  |]

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_ (execute_ conn) [servers, receiveQueues, sendQueues, connections, messages]
