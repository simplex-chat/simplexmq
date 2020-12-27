{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Database.SQLite.Simple

createSchema :: Connection -> IO ()
createSchema conn =
  mapM_
    (execute_ conn)
    [ recipientQueues --,
    -- senderQueues,
    -- connections,
    -- messages
    ]

recipientQueues :: Query
recipientQueues =
  "CREATE TABLE IF NOT EXISTS recipient_queues\
  \ ( id INTEGER PRIMARY KEY,\
  \   rcvId TEXT\
  \ )"

senderQueues :: Query
senderQueues = ""

connections :: Query
connections = ""

messages :: Query
messages = ""
