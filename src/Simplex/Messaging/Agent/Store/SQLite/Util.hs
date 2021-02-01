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

instance FromField QueueStatus where fromField = fromFieldToReadable

fromFieldToReadable :: forall a. (Read a, E.Typeable a) => Field -> Ok a
fromFieldToReadable = \case
  f@(Field (SQLText t) _) ->
    let str = T.unpack t
     in case readMaybe str of
          Just x -> Ok x
          _ -> returnError ConversionFailed f ("invalid string: " <> str)
  f -> returnError ConversionFailed f "expecting SQLText column type"

-- instance ToRow SMPServer where
--   toRow SMPServer {host, port, keyHash} = toRow (host, port, keyHash)

-- instance FromRow SMPServer where
--   fromRow = SMPServer <$> field <*> field <*> field

-- instance ToField AckMode where toField (AckMode mode) = toField $ show mode

-- instance FromField AckMode where fromField = AckMode <$$> fromFieldToReadable

-- instance ToField QueueStatus where toField = toField . show

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

createRcvQueueAndConn :: DB.Connection -> ReceiveQueue -> IO ()
createRcvQueueAndConn dbConn rcvQueue =
  DB.withTransaction dbConn $ do
    _upsertServer dbConn (server (rcvQueue :: ReceiveQueue))
    _insertRcvQueue dbConn rcvQueue
    _insertRcvConnection dbConn rcvQueue

createSndQueueAndConn :: DB.Connection -> SendQueue -> IO ()
createSndQueueAndConn dbConn sndQueue =
  DB.withTransaction dbConn $ do
    _upsertServer dbConn (server (sndQueue :: SendQueue))
    _insertSndQueue dbConn sndQueue
    _insertSndConnection dbConn sndQueue

_upsertServer :: DB.Connection -> SMPServer -> IO ()
_upsertServer dbConn SMPServer {host, port, keyHash} = do
  let _port = _convertPortOnWrite port
  DB.executeNamed
    dbConn
    _upsertServerQuery
    [":host" := host, ":port" := _port, ":key_hash" := keyHash]

-- TODO replace with ToField - it's easy to forget to use this
_convertPortOnWrite :: Maybe ServiceName -> ServiceName
_convertPortOnWrite = fromMaybe "_"

_convertPortOnRead :: ServiceName -> Maybe ServiceName
_convertPortOnRead port
  | port == "_" = Nothing
  | otherwise = Just port

_upsertServerQuery :: Query
_upsertServerQuery =
  [sql|
    INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
    ON CONFLICT (host, port) DO UPDATE SET
      host=excluded.host,
      port=excluded.port,
      key_hash=excluded.key_hash;
  |]

_insertRcvQueue :: DB.Connection -> ReceiveQueue -> IO ()
_insertRcvQueue dbConn ReceiveQueue {..} = do
  let _port = _convertPortOnWrite $ port server
  DB.executeNamed
    dbConn
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

_insertRcvConnection :: DB.Connection -> ReceiveQueue -> IO ()
_insertRcvConnection dbConn ReceiveQueue {server, rcvId, connAlias} = do
  let _port = _convertPortOnWrite $ port server
  DB.executeNamed
    dbConn
    _insertRcvConnectionQuery
    [":conn_alias" := connAlias, ":rcv_host" := host server, ":rcv_port" := _port, ":rcv_id" := rcvId]

_insertRcvConnectionQuery :: Query
_insertRcvConnectionQuery =
  [sql|
    INSERT INTO connections
      ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
    VALUES
      (:conn_alias,:rcv_host,:rcv_port,:rcv_id,     NULL,     NULL,   NULL);
  |]

_insertSndQueue :: DB.Connection -> SendQueue -> IO ()
_insertSndQueue dbConn SendQueue {..} = do
  let _port = _convertPortOnWrite $ port server
  DB.executeNamed
    dbConn
    _insertSndQueueQuery
    [":host" := host server, ":port" := _port, ":snd_id" := sndId, ":conn_alias" := connAlias, ":snd_private_key" := sndPrivateKey, ":encrypt_key" := encryptKey, ":sign_key" := signKey, ":status" := status]

_insertSndQueueQuery :: Query
_insertSndQueueQuery =
  [sql|
    INSERT INTO snd_queues
      ( host, port, snd_id, conn_alias, snd_private_key, encrypt_key, sign_key, status)
    VALUES
      (:host,:port,:snd_id,:conn_alias,:snd_private_key,:encrypt_key,:sign_key,:status);
  |]

_insertSndConnection :: DB.Connection -> SendQueue -> IO ()
_insertSndConnection dbConn SendQueue {server, sndId, connAlias} = do
  let _port = _convertPortOnWrite $ port server
  DB.executeNamed
    dbConn
    _insertSndConnectionQuery
    [":conn_alias" := connAlias, ":snd_host" := host server, ":snd_port" := _port, ":snd_id" := sndId]

_insertSndConnectionQuery :: Query
_insertSndConnectionQuery =
  [sql|
    INSERT INTO connections
      ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
    VALUES
      (:conn_alias,     NULL,     NULL,   NULL,:snd_host,:snd_port,:snd_id);
  |]

retrieveConnQueues :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue, Maybe SendQueue)
retrieveConnQueues dbConn connAlias =
  DB.withTransaction dbConn $ do
    -- to avoid inconsistent state between queue reads
    rcvQ <- _retrieveRcvQueue dbConn connAlias
    sndQ <- _retrieveSndQueue dbConn connAlias
    return (rcvQ, sndQ)

_retrieveRcvQueue :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue)
_retrieveRcvQueue dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      _retrieveRcvQueueQuery
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, rcvId, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer host (_convertPortOnRead port) keyHash
      return . Just $ ReceiveQueue srv rcvId connAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

_retrieveRcvQueueQuery :: Query
_retrieveRcvQueueQuery =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.rcv_id, q.rcv_private_key, q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status)
    FROM rcv_queues q
    INNER JOIN servers s
      ON q.host = s.host
      AND q.port = s.port
    WHERE q.conn_alias = :conn_alias;
  |]

_retrieveSndQueue :: DB.Connection -> ConnAlias -> IO (Maybe SendQueue)
_retrieveSndQueue dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      _retrieveSndQueueQuery
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, sndId, sndPrivateKey, encryptKey, signKey, status)] -> do
      let srv = SMPServer host (_convertPortOnRead port) keyHash
      return . Just $ SendQueue srv sndId connAlias sndPrivateKey encryptKey signKey status
    _ -> return Nothing

_retrieveSndQueueQuery :: Query
_retrieveSndQueueQuery =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.snd_id, q.snd_private_key, q.encrypt_key, q.sign_key, q.status)
    FROM snd_queues q
    INNER JOIN servers s
      ON q.host = s.host
      AND q.port = s.port
    WHERE q.conn_alias = :conn_alias;
  |]

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
