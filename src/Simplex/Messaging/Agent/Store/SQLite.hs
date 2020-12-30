{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite where

import Control.Monad.IO.Unlift
import Database.SQLite.Simple (NamedParam (..))
import qualified Database.SQLite.Simple as DB
import Multiline (s)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission

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

newtype SQLiteStore = SQLiteStore {conn :: DB.Connection}

instance MonadUnliftIO m => MonadAgentStore SQLiteStore m where
  addServer :: SQLiteStore -> SMPServer -> m (Either StoreError SMPServerId)
  addServer store SMPServer {host, port, keyHash} = liftIO $ do
    DB.executeNamed (conn store) addServerQuery [":host_address" := host, ":port" := port, ":key_hash" := keyHash]
    Right <$> DB.lastInsertRowId (conn store)

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
