{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite.Util where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time
import Database.SQLite.Simple hiding (Connection)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField
import Network.Socket
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util
import Text.Read
import qualified UnliftIO.Exception as E
import UnliftIO.STM

instance ToField QueueStatus where toField = toField . show

-- instance ToRow SMPServer where
--   toRow SMPServer {host, port, keyHash} = toRow (host, port, keyHash)

-- instance FromRow SMPServer where
--   fromRow = SMPServer <$> field <*> field <*> field

-- instance ToField AckMode where toField (AckMode mode) = toField $ show mode

-- instance FromField AckMode where fromField = AckMode <$$> fromFieldToReadable

-- instance ToField QueueStatus where toField = toField . show

-- instance FromField QueueStatus where fromField = fromFieldToReadable

-- instance ToRow ReceiveQueue where
--   toRow ReceiveQueue {rcvId, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status} =
--     toRow (rcvId, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)

-- instance FromRow ReceiveQueue where
--   fromRow = ReceiveQueue undefined <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

-- instance ToRow SendQueue where
--   toRow SendQueue {sndId, sndPrivateKey, encryptKey, signKey, status} =
--     toRow (sndId, sndPrivateKey, encryptKey, signKey, status)

-- instance FromRow SendQueue where
--   fromRow = SendQueue undefined <$> field <*> field <*> field <*> field <*> field <*> field

-- instance FromRow ConnAlias where
--   fromRow = field

-- instance ToField QueueDirection where toField = toField . show

-- fromFieldToReadable :: forall a. (Read a, E.Typeable a) => Field -> Ok a
-- fromFieldToReadable = \case
--   f@(Field (SQLText t) _) ->
--     let str = T.unpack t
--      in case readMaybe str of
--           Just x -> Ok x
--           _ -> returnError ConversionFailed f ("invalid string: " <> str)
--   f -> returnError ConversionFailed f "expecting SQLText column type"

-- TODO delete locks

-- withLock :: MonadUnliftIO m => SQLiteStore -> (SQLiteStore -> TMVar ()) -> (DB.Connection -> m a) -> m a
-- withLock st tableLock f = do
--   let lock = tableLock st
--   E.bracket_
--     (atomically $ takeTMVar lock)
--     (atomically $ putTMVar lock ())
--     (f $ conn st)

-- insertWithLock :: (MonadUnliftIO m, ToRow q) => SQLiteStore -> (SQLiteStore -> TMVar ()) -> DB.Query -> q -> m Int64
-- insertWithLock st tableLock queryStr q = do
--   withLock st tableLock $ \c -> liftIO $ do
--     DB.execute c queryStr q
--     DB.lastInsertRowId c

-- executeWithLock :: (MonadUnliftIO m, ToRow q) => SQLiteStore -> (SQLiteStore -> TMVar ()) -> DB.Query -> q -> m ()
-- executeWithLock st tableLock queryStr q = do
--   withLock st tableLock $ \c -> liftIO $ do
--     DB.execute c queryStr q

upsertServer :: MonadUnliftIO m => DB.Connection -> SMPServer -> m ()
upsertServer conn SMPServer {host, port, keyHash} =
  liftIO $ do
    let _port = _convertPortOnWrite port
    DB.executeNamed
      conn
      _upsertServerQuery
      [":host" := host, ":port" := _port, ":key_hash" := keyHash]

-- TODO replace with ToField - it's easy to forget to use this
_convertPortOnWrite :: Maybe ServiceName -> ServiceName
_convertPortOnWrite = fromMaybe "_"

_upsertServerQuery :: Query
_upsertServerQuery =
  [sql|
    INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
    ON CONFLICT (host, port) DO UPDATE SET
      host=excluded.host,
      port=excluded.port,
      key_hash=excluded.key_hash;
  |]

insertRcvQueue :: MonadUnliftIO m => DB.Connection -> ReceiveQueue -> m ()
insertRcvQueue conn ReceiveQueue {..} =
  liftIO $ do
    let _port = _convertPortOnWrite $ port server
    DB.executeNamed
      conn
      _insertRcvQueueQuery
      [":host" := host server, ":port" := _port, ":rcv_id" := rcvId, ":conn_alias" := connAlias, ":rcv_private_key" := rcvPrivateKey, ":snd_id" := sndId, ":snd_key" := sndKey, ":decrypt_key" := decryptKey, ":verify_key" := verifyKey, ":status" := status]

_insertRcvQueueQuery :: Query
_insertRcvQueueQuery =
  [sql|
    INSERT INTO rcv_queues
      ( host, port, rcv_id, conn_alias, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status)
    VALUES
      (:host,:port,:rcv_id,:conn_alias,:rcv_private_key,:snd_id,:snd_key,:decrypt_key,:verify_key,:status);
  |]

insertRcvConnection :: MonadUnliftIO m => DB.Connection -> ConnAlias -> ReceiveQueue -> m ()
insertRcvConnection conn connAlias ReceiveQueue {server, rcvId} =
  liftIO $ do
    let _port = _convertPortOnWrite $ port server
    DB.executeNamed
      conn
      _insertRcvConnectionQuery
      [":conn_alias" := connAlias, ":rcv_host" := host server, ":rcv_port" := _port, ":rcv_id" := rcvId]

_insertRcvConnectionQuery :: Query
_insertRcvConnectionQuery =
  [sql|
    INSERT INTO connections
      ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
    VALUES
      (:conn_alias,:rcv_host,:rcv_port,:rcv_id,NULL,NULL,NULL);
  |]

-- getServer :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> SMPServerId -> m SMPServer
-- getServer SQLiteStore {conn} serverId = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         "SELECT host, port, key_hash FROM servers WHERE server_id = :server_id"
--         [":server_id" := serverId]
--   case r of
--     [smpServer] -> return smpServer
--     _ -> throwError SENotFound

-- -- TODO refactor into a single query with join
-- getRcvQueue :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> QueueRowId -> m ReceiveQueue
-- getRcvQueue st@SQLiteStore {conn} queueRowId = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         [sql|
--         SELECT server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode
--           FROM receive_queues
--           WHERE receive_queue_id = :rowId;
--         |]
--         [":rowId" := queueRowId]
--   case r of
--     [Only serverId :. rcvQueue] ->
--       (\srv -> (rcvQueue {server = srv} :: ReceiveQueue)) <$> getServer st serverId
--     _ -> throwError SENotFound

-- getRcvQueueByRecipientId :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> RecipientId -> HostName -> Maybe ServiceName -> m ReceiveQueue
-- getRcvQueueByRecipientId st@SQLiteStore {conn} rcvId host port = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         [sql|
--           SELECT server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode
--           FROM receive_queues
--           WHERE rcv_id = :rcvId AND server_id IN (
--             SELECT server_id
--             FROM servers
--             WHERE host = :host AND port = :port
--           );
--         |]
--         [":rcvId" := rcvId, ":host" := host, ":port" := port]
--   case r of
--     [Only serverId :. rcvQueue] ->
--       (\srv -> (rcvQueue {server = srv} :: ReceiveQueue)) <$> getServer st serverId
--     _ -> throwError SENotFound

-- -- TODO refactor into a single query with join
-- getSndQueue :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> QueueRowId -> m SendQueue
-- getSndQueue st@SQLiteStore {conn} queueRowId = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         [sql|
--         SELECT server_id, snd_id, snd_private_key, encrypt_key, sign_key, status, ack_mode
--         FROM send_queues
--         WHERE send_queue_id = :rowId;
--       |]
--         [":rowId" := queueRowId]
--   case r of
--     [Only serverId :. sndQueue] ->
--       (\srv -> (sndQueue {server = srv} :: SendQueue)) <$> getServer st serverId
--     _ -> throwError SENotFound

-- addRcvQueueQuery :: Query
-- addRcvQueueQuery =
--   [sql|
--     INSERT INTO receive_queues
--       ( server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode)
--     VALUES
--       (:server_id,:rcv_id,:rcv_private_key,:snd_id,:snd_key,:decrypt_key,:verify_key,:status,:ack_mode);
--   |]

-- updateRcvConnectionWithSndQueue :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
-- updateRcvConnectionWithSndQueue store connAlias sndQueueId =
--   executeWithLock
--     store
--     connectionsLock
--     [sql|
--       UPDATE connections
--       SET send_queue_id = ?
--       WHERE conn_alias = ?;
--     |]
--     (Only sndQueueId :. Only connAlias)

-- insertSndQueue :: MonadUnliftIO m => SQLiteStore -> SMPServerId -> SendQueue -> m QueueRowId
-- insertSndQueue store serverId sndQueue =
--   insertWithLock
--     store
--     sndQueuesLock
--     [sql|
--       INSERT INTO send_queues
--         ( server_id, snd_id, snd_private_key, encrypt_key, sign_key, status, ack_mode)
--       VALUES (?,?,?,?,?,?,?);
--     |]
--     (Only serverId :. sndQueue)

-- insertSndConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
-- insertSndConnection store connAlias sndQueueId =
--   void $
--     insertWithLock
--       store
--       connectionsLock
--       "INSERT INTO connections (conn_alias, receive_queue_id, send_queue_id) VALUES (?,NULL,?);"
--       (Only connAlias :. Only sndQueueId)

-- updateSndConnectionWithRcvQueue :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
-- updateSndConnectionWithRcvQueue store connAlias rcvQueueId =
--   executeWithLock
--     store
--     connectionsLock
--     [sql|
--       UPDATE connections
--       SET receive_queue_id = ?
--       WHERE conn_alias = ?;
--     |]
--     (Only rcvQueueId :. Only connAlias)

-- getConnection :: (MonadError StoreError m, MonadUnliftIO m) => SQLiteStore -> ConnAlias -> m (Maybe QueueRowId, Maybe QueueRowId)
-- getConnection SQLiteStore {conn} connAlias = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         "SELECT receive_queue_id, send_queue_id FROM connections WHERE conn_alias = :conn_alias"
--         [":conn_alias" := connAlias]
--   case r of
--     [queueIds] -> return queueIds
--     _ -> throwError SEInternal

-- getConnAliasByRcvQueue :: (MonadError StoreError m, MonadUnliftIO m) => SQLiteStore -> RecipientId -> m ConnAlias
-- getConnAliasByRcvQueue SQLiteStore {conn} rcvId = do
--   r <-
--     liftIO $
--       DB.queryNamed
--         conn
--         [sql|
--           SELECT c.conn_alias
--           FROM connections c
--           JOIN receive_queues rq
--           ON c.receive_queue_id = rq.receive_queue_id
--           WHERE rq.rcv_id = :rcvId;
--         |]
--         [":rcvId" := rcvId]
--   case r of
--     [connAlias] -> return connAlias
--     _ -> throwError SEInternal

-- deleteRcvQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m ()
-- deleteRcvQueue store rcvQueueId = do
--   executeWithLock
--     store
--     rcvQueuesLock
--     "DELETE FROM receive_queues WHERE receive_queue_id = ?"
--     (Only rcvQueueId)

-- deleteSndQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m ()
-- deleteSndQueue store sndQueueId = do
--   executeWithLock
--     store
--     sndQueuesLock
--     "DELETE FROM send_queues WHERE send_queue_id = ?"
--     (Only sndQueueId)

-- deleteConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> m ()
-- deleteConnection store connAlias = do
--   executeWithLock
--     store
--     connectionsLock
--     "DELETE FROM connections WHERE conn_alias = ?"
--     (Only connAlias)

-- updateReceiveQueueStatus :: MonadUnliftIO m => SQLiteStore -> RecipientId -> HostName -> Maybe ServiceName -> QueueStatus -> m ()
-- updateReceiveQueueStatus store rcvQueueId host port status =
--   executeWithLock
--     store
--     rcvQueuesLock
--     [sql|
--       UPDATE receive_queues
--       SET status = ?
--       WHERE rcv_id = ?
--       AND server_id IN (
--         SELECT server_id
--         FROM servers
--         WHERE host = ? AND port = ?
--       );
--     |]
--     (Only status :. Only rcvQueueId :. Only host :. Only port)

-- updateSendQueueStatus :: MonadUnliftIO m => SQLiteStore -> SMP.SenderId -> HostName -> Maybe ServiceName -> QueueStatus -> m ()
-- updateSendQueueStatus store sndQueueId host port status =
--   executeWithLock
--     store
--     sndQueuesLock
--     [sql|
--       UPDATE send_queues
--       SET status = ?
--       WHERE snd_id = ?
--       AND server_id IN (
--         SELECT server_id
--         FROM servers
--         WHERE host = ? AND port = ?
--       );
--     |]
--     (Only status :. Only sndQueueId :. Only host :. Only port)

-- -- TODO add parser and serializer for DeliveryStatus? Pass DeliveryStatus?
-- insertMsg :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueDirection -> AgentMsgId -> Message -> m ()
-- insertMsg store connAlias qDirection agentMsgId msg = do
--   ts <- liftIO getCurrentTime
--   void $
--     insertWithLock
--       store
--       messagesLock
--       [sql|
--         INSERT INTO messages (conn_alias, agent_msg_id, timestamp, message, direction, msg_status)
--         VALUES (?,?,?,?,?,"MDTransmitted");
--       |]
--       (Only connAlias :. Only agentMsgId :. Only ts :. Only qDirection :. Only msg)
