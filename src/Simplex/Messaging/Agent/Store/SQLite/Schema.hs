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

-- TODO unique constraints on (server_id, rcv_id) and (server_id, snd_id)
recipientQueues :: Query
recipientQueues =
  "CREATE TABLE IF NOT EXISTS recipient_queues\
  \ ( recipient_queue_id INTEGER PRIMARY KEY,\
  \   server_id INTEGER REFERENCES servers(server_id),\
  \   rcv_id BLOB,\
  \   rcv_private_key BLOB,\
  \   snd_id BLOB,\
  \   snd_key BLOB,\
  \   decrypt_key BLOB,\
  \   verify_key BLOB,\
  \   status TEXT,\
  \   ack_mode INTEGER\
  \ )"

senderQueues :: Query
senderQueues =
  "CREATE TABLE IF NOT EXISTS sender_queues\
  \ ( sender_queue_id INTEGER PRIMARY KEY,\
  \   server_id INTEGER REFERENCES servers(server_id),\
  \   snd_id BLOB,\
  \   snd_private_key BLOB,\
  \   encrypt_key BLOB,\
  \   sign_key BLOB,\
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
