{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple
import Multiline (s)

servers :: Query
servers =
  [s|
    CREATE TABLE IF NOT EXISTS servers
      ( server_id INTEGER PRIMARY KEY,
        host_address TEXT NOT NULL,
        port INT NOT NULL,
        key_hash BLOB,
        UNIQUE (host_address, port)
      )
  |]

-- TODO unique constraints on (server_id, rcv_id) and (server_id, snd_id)
recipientQueues :: Query
recipientQueues =
  [s|
    CREATE TABLE IF NOT EXISTS recipient_queues
      ( recipient_queue_id INTEGER PRIMARY KEY,
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

senderQueues :: Query
senderQueues =
  [s|
    CREATE TABLE IF NOT EXISTS sender_queues
      ( sender_queue_id INTEGER PRIMARY KEY,
        server_id INTEGER REFERENCES servers(server_id) NOT NULL,
        snd_id BLOB NOT NULL,
        snd_private_key BLOB NOT NULL,
        encrypt_key BLOB NOT NULL,
        sign_key BLOB NOT NULL,
        status TEXT NOT NULL,
        ack_mode INTEGER NOT NULL
      )
  |]

connections :: Query
connections =
  [s|
    CREATE TABLE IF NOT EXISTS connections
      ( connection_id INTEGER PRIMARY KEY,
        conn_alias TEXT UNIQUE,
        recipient_queue_id INTEGER REFERENCES recipient_queues(recipient_queue_id),
        sender_queue_id INTEGER REFERENCES sender_queues(sender_queue_id)
      )
  |]

messages :: Query
messages =
  [s|
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
  mapM_ (execute_ conn) [servers, recipientQueues, senderQueues, connections, messages]
