{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_ (execute_ conn) [servers, recipientQueues, senderQueues, connections, messages]

servers :: Query
servers =
  "CREATE TABLE IF NOT EXISTS servers\
  \ ( server_id INTEGER PRIMARY KEY,\
  \   host_address TEXT\
  \ )"

recipientQueues :: Query
recipientQueues =
  "CREATE TABLE IF NOT EXISTS recipient_queues\
  \ ( recipient_queue_id INTEGER PRIMARY KEY,\
  \   server_id INTEGER REFERENCES servers(server_id),\
  \   rcv_id TEXT,\
  \   rcv_private_key TEXT,\
  \   snd_id TEXT,\
  \   snd_key TEXT,\
  \   decrypt_key TEXT,\
  \   verify_key TEXT,\
  \   status TEXT,\
  \   ack_mode INTEGER\
  \ )"

senderQueues :: Query
senderQueues =
  "CREATE TABLE IF NOT EXISTS sender_queues\
  \ ( sender_queue_id INTEGER PRIMARY KEY,\
  \   server_id INTEGER REFERENCES servers(server_id),\
  \   snd_id TEXT,\
  \   snd_private_key TEXT,\
  \   encrypt_key TEXT,\
  \   sign_key TEXT,\
  \   status TEXT,\
  \   ack_mode INTEGER\
  \ )"

connections :: Query
connections =
  "CREATE TABLE IF NOT EXISTS connections\
  \ ( connection_id INTEGER PRIMARY KEY,\
  \   conn_alias TEXT UNIQUE,\
  \   recipient_queue_id INTEGER REFERENCES recipient_queues(recipient_queue_id),\
  \   sender_queue_id INTEGER REFERENCES sender_queues(sender_queue_id)\
  \ )"

messages :: Query
messages =
  "CREATE TABLE IF NOT EXISTS messages\
  \ ( message_id INTEGER PRIMARY KEY,\
  \   conn_alias TEXT REFERENCES connections(conn_alias),\
  \   agent_msg_id INTEGER,\
  \   timestamp TEXT,\
  \   message TEXT,\
  \   direction TEXT,\
  \   msg_status TEXT\
  \ )"
