{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite where

import Control.Monad.IO.Unlift
import Data.Int (Int64)
import Database.SQLite.Simple (NamedParam (..))
import qualified Database.SQLite.Simple as DB
import Multiline (s)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Schema
import Simplex.Messaging.Agent.Transmission
import qualified UnliftIO.Exception as E
import UnliftIO.STM

addServerQuery :: DB.Query
addServerQuery =
  [s|
    INSERT INTO servers (host_address, port, key_hash)
    VALUES (:host_address, :port, :key_hash)
    ON CONFLICT(host_address, port) DO UPDATE SET
      host_address=excluded.host_address,
      port=excluded.port,
      key_hash=excluded.key_hash;
  |]

data SQLiteStore = SQLiteStore
  { conn :: DB.Connection,
    serversLock :: TMVar (),
    recipientQueuesLock :: TMVar (),
    senderQueuesLock :: TMVar (),
    connectionsLock :: TMVar (),
    messagesLock :: TMVar ()
  }

newSQLiteStore :: MonadUnliftIO m => String -> m SQLiteStore
newSQLiteStore dbFile = do
  conn <- liftIO $ DB.open dbFile
  liftIO $ createSchema conn
  serversLock <- newTMVarIO ()
  recipientQueuesLock <- newTMVarIO ()
  senderQueuesLock <- newTMVarIO ()
  connectionsLock <- newTMVarIO ()
  messagesLock <- newTMVarIO ()
  return
    SQLiteStore
      { conn,
        serversLock,
        recipientQueuesLock,
        senderQueuesLock,
        connectionsLock,
        messagesLock
      }

withLock :: MonadUnliftIO m => SQLiteStore -> (SQLiteStore -> TMVar ()) -> (DB.Connection -> m a) -> m a
withLock st tableLock f = do
  let lock = tableLock st
  E.bracket_
    (atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())
    (f $ conn st)

insertWithLock :: MonadUnliftIO m => SQLiteStore -> (SQLiteStore -> TMVar ()) -> DB.Query -> [DB.NamedParam] -> m Int64
insertWithLock st tableLock q qParams = do
  withLock st tableLock $ \c -> liftIO $ do
    DB.executeNamed c q qParams
    DB.lastInsertRowId c

instance MonadUnliftIO m => MonadAgentStore SQLiteStore m where
  addServer :: SQLiteStore -> SMPServer -> m (Either StoreError SMPServerId)
  addServer st SMPServer {host, port, keyHash} =
    Right <$> insertWithLock st serversLock addServerQuery [":host_address" := host, ":port" := port, ":key_hash" := keyHash]

--   createRcvConn :: DB.Connection -> Maybe ConnAlias -> ReceiveQueue -> m (Either StoreError (Connection CReceive))
--   createRcvConn conn connAlias q = do
--     id <- query conn "INSERT ..."
--     query conn "INSERT ..."

-- sqlite queries to create server, queue and connection

-- *** step 1 - insert server before create request to server

-- ! "INSERT OR REPLACE INTO" with autoincrement apparently would change id,
-- ! so going with "ON CONFLICT UPDATE" here

-- INSERT INTO servers (host_address, port, key_hash)
-- VALUES ({host_address}, {port}, {key_hash})
-- ON CONFLICT(host_address, port) DO UPDATE SET
--   host_address=excluded.host_address,
--   port=excluded.port,
--   key_hash=excluded.key_hash;

-- *** step 2 - insert queue and connection after server's response

-- BEGIN TRANSACTION;

-- INSERT INTO recipient_queues (
--   server_id,
--   rcv_id,
--   rcv_private_key,
--   snd_id,
--   snd_key,
--   decrypt_key,
--   verify_key,
--   status,
--   ack_mode
-- )
-- VALUES (
--   {server_id},
--   {rcv_id},
--   {rcv_private_key},
--   {snd_id},
--   {snd_key},
--   {decrypt_key},
--   {verify_key},
--   {status},
--   {ack_mode}
-- );

-- INSERT INTO connections (
--   conn_alias,
--   recipient_queue_id,
--   sender_queue_id
-- )
-- VALUES (
--   {conn_alias},
--   {recipient_queue_id},
--   NULL
-- );

-- COMMIT;

-- ***
