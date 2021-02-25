{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite.Util
  ( createRcvQueueAndConn,
    createSndQueueAndConn,
    retrieveConnQueues,
    retrieveRcvQueue,
    deleteConnCascade,
    updateRcvConnWithSndQueue,
    updateSndConnWithRcvQueue,
    updateRcvQueueStatus,
    updateSndQueueStatus,
    insertRcvMsg,
    insertSndMsg,
  )
where

import Control.Monad.Except (MonadIO (liftIO))
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (getCurrentTime)
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import Network.Socket (HostName, ServiceName)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Protocol as SMP (RecipientId)
import Simplex.Messaging.Types (MsgBody)
import Text.Read (readMaybe)
import qualified UnliftIO.Exception as E

-- * Auxiliary helpers

-- ? replace with ToField? - it's easy to forget to use this
serializePort_ :: Maybe ServiceName -> ServiceName
serializePort_ = fromMaybe "_"

deserializePort_ :: ServiceName -> Maybe ServiceName
deserializePort_ "_" = Nothing
deserializePort_ port = Just port

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromFieldToReadable_

instance ToField RcvStatus where toField = toField . show

instance ToField SndStatus where toField = toField . show

fromFieldToReadable_ :: forall a. (Read a, E.Typeable a) => Field -> Ok a
fromFieldToReadable_ = \case
  f@(Field (SQLText t) _) ->
    let str = T.unpack t
     in case readMaybe str of
          Just x -> Ok x
          _ -> returnError ConversionFailed f ("invalid string: " <> str)
  f -> returnError ConversionFailed f "expecting SQLText column type"

{- ORMOLU_DISABLE -}
-- SQLite.Simple only has these up to 10 fields, which is insufficient for some of our queries
instance (FromField a, FromField b, FromField c, FromField d, FromField e,
          FromField f, FromField g, FromField h, FromField i, FromField j,
          FromField k) =>
  FromRow (a,b,c,d,e,f,g,h,i,j,k) where
  fromRow = (,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
                         <*> field <*> field <*> field <*> field <*> field
                         <*> field
{- ORMOLU_ENABLE -}

-- * Server upsert helper

upsertServer_ :: DB.Connection -> SMPServer -> IO ()
upsertServer_ dbConn SMPServer {host, port, keyHash} = do
  let port_ = serializePort_ port
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
      ON CONFLICT (host, port) DO UPDATE SET
        host=excluded.host,
        port=excluded.port,
        key_hash=excluded.key_hash;
    |]
    [":host" := host, ":port" := port_, ":key_hash" := keyHash]

-- * createRcvConn helpers

createRcvQueueAndConn :: DB.Connection -> ReceiveQueue -> IO ()
createRcvQueueAndConn dbConn rcvQueue =
  DB.withTransaction dbConn $ do
    upsertServer_ dbConn (server (rcvQueue :: ReceiveQueue))
    insertRcvQueue_ dbConn rcvQueue
    insertRcvConnection_ dbConn rcvQueue

insertRcvQueue_ :: DB.Connection -> ReceiveQueue -> IO ()
insertRcvQueue_ dbConn ReceiveQueue {..} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_queues
        ( host, port, rcv_id, conn_alias, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status)
      VALUES
        (:host,:port,:rcv_id,:conn_alias,:rcv_private_key,:snd_id,:snd_key,:decrypt_key,:verify_key,:status);
    |]
    [ ":host" := host server,
      ":port" := port_,
      ":rcv_id" := rcvId,
      ":conn_alias" := connAlias,
      ":rcv_private_key" := rcvPrivateKey,
      ":snd_id" := sndId,
      ":snd_key" := sndKey,
      ":decrypt_key" := decryptKey,
      ":verify_key" := verifyKey,
      ":status" := status
    ]

insertRcvConnection_ :: DB.Connection -> ReceiveQueue -> IO ()
insertRcvConnection_ dbConn ReceiveQueue {server, rcvId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id,
          last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id)
      VALUES
        (:conn_alias,:rcv_host,:rcv_port,:rcv_id,     NULL,     NULL,   NULL,
                            0,                        0,                        0);
    |]
    [":conn_alias" := connAlias, ":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId]

-- * createSndConn helpers

createSndQueueAndConn :: DB.Connection -> SendQueue -> IO ()
createSndQueueAndConn dbConn sndQueue =
  DB.withTransaction dbConn $ do
    upsertServer_ dbConn (server (sndQueue :: SendQueue))
    insertSndQueue_ dbConn sndQueue
    insertSndConnection_ dbConn sndQueue

insertSndQueue_ :: DB.Connection -> SendQueue -> IO ()
insertSndQueue_ dbConn SendQueue {..} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_queues
        ( host, port, snd_id, conn_alias, snd_private_key, encrypt_key, sign_key, status)
      VALUES
        (:host,:port,:snd_id,:conn_alias,:snd_private_key,:encrypt_key,:sign_key,:status);
    |]
    [ ":host" := host server,
      ":port" := port_,
      ":snd_id" := sndId,
      ":conn_alias" := connAlias,
      ":snd_private_key" := sndPrivateKey,
      ":encrypt_key" := encryptKey,
      ":sign_key" := signKey,
      ":status" := status
    ]

insertSndConnection_ :: DB.Connection -> SendQueue -> IO ()
insertSndConnection_ dbConn SendQueue {server, sndId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id,
          last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id)
      VALUES
        (:conn_alias,     NULL,     NULL,   NULL,:snd_host,:snd_port,:snd_id,
                            0,                        0,                        0);
    |]
    [":conn_alias" := connAlias, ":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId]

-- * getConn helpers

retrieveConnQueues :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue, Maybe SendQueue)
retrieveConnQueues dbConn connAlias =
  DB.withTransaction -- Avoid inconsistent state between queue reads
    dbConn
    $ retrieveConnQueues_ dbConn connAlias

-- Separate transactionless version of retrieveConnQueues to be reused in other functions that already wrap
-- multiple statements in transaction - otherwise they'd be attempting to start a transaction within a transaction
retrieveConnQueues_ :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue, Maybe SendQueue)
retrieveConnQueues_ dbConn connAlias = do
  rcvQ <- retrieveRcvQueueByConnAlias_ dbConn connAlias
  sndQ <- retrieveSndQueueByConnAlias_ dbConn connAlias
  return (rcvQ, sndQ)

retrieveRcvQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue)
retrieveRcvQueueByConnAlias_ dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT
          s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key,
          q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status
        FROM rcv_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, rcvId, cAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer host (deserializePort_ port) keyHash
      return . Just $ ReceiveQueue srv rcvId cAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

retrieveSndQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe SendQueue)
retrieveSndQueueByConnAlias_ dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT
          s.key_hash, q.host, q.port, q.snd_id, q.conn_alias,
          q.snd_private_key, q.encrypt_key, q.sign_key, q.status
        FROM snd_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, sndId, cAlias, sndPrivateKey, encryptKey, signKey, status)] -> do
      let srv = SMPServer host (deserializePort_ port) keyHash
      return . Just $ SendQueue srv sndId cAlias sndPrivateKey encryptKey signKey status
    _ -> return Nothing

-- * getRcvQueue helper

retrieveRcvQueue :: DB.Connection -> HostName -> Maybe ServiceName -> SMP.RecipientId -> IO (Maybe ReceiveQueue)
retrieveRcvQueue dbConn host port rcvId = do
  r <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT
          s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key,
          q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status
        FROM rcv_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.host = :host AND q.port = :port AND q.rcv_id = :rcv_id;
      |]
      [":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]
  case r of
    [(keyHash, hst, prt, rId, connAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer hst (deserializePort_ prt) keyHash
      return . Just $ ReceiveQueue srv rId connAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

-- * deleteConn helper

deleteConnCascade :: DB.Connection -> ConnAlias -> IO ()
deleteConnCascade dbConn connAlias =
  DB.executeNamed
    dbConn
    "DELETE FROM connections WHERE conn_alias = :conn_alias;"
    [":conn_alias" := connAlias]

-- * upgradeRcvConnToDuplex helpers

updateRcvConnWithSndQueue :: DB.Connection -> ConnAlias -> SendQueue -> IO (Either StoreError ())
updateRcvConnWithSndQueue dbConn connAlias sndQueue =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues_ dbConn connAlias
    case queues of
      (Just _rcvQ, Nothing) -> do
        upsertServer_ dbConn (server (sndQueue :: SendQueue))
        insertSndQueue_ dbConn sndQueue
        updateConnWithSndQueue_ dbConn connAlias sndQueue
        return $ Right ()
      (Nothing, Just _sndQ) -> return $ Left (SEBadConnType CSend)
      (Just _rcvQ, Just _sndQ) -> return $ Left (SEBadConnType CDuplex)
      _ -> return $ Left SEBadConn

updateConnWithSndQueue_ :: DB.Connection -> ConnAlias -> SendQueue -> IO ()
updateConnWithSndQueue_ dbConn connAlias SendQueue {server, sndId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET snd_host = :snd_host, snd_port = :snd_port, snd_id = :snd_id
      WHERE conn_alias = :conn_alias;
    |]
    [":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId, ":conn_alias" := connAlias]

-- * upgradeSndConnToDuplex helpers

updateSndConnWithRcvQueue :: DB.Connection -> ConnAlias -> ReceiveQueue -> IO (Either StoreError ())
updateSndConnWithRcvQueue dbConn connAlias rcvQueue =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues_ dbConn connAlias
    case queues of
      (Nothing, Just _sndQ) -> do
        upsertServer_ dbConn (server (rcvQueue :: ReceiveQueue))
        insertRcvQueue_ dbConn rcvQueue
        updateConnWithRcvQueue_ dbConn connAlias rcvQueue
        return $ Right ()
      (Just _rcvQ, Nothing) -> return $ Left (SEBadConnType CReceive)
      (Just _rcvQ, Just _sndQ) -> return $ Left (SEBadConnType CDuplex)
      _ -> return $ Left SEBadConn

updateConnWithRcvQueue_ :: DB.Connection -> ConnAlias -> ReceiveQueue -> IO ()
updateConnWithRcvQueue_ dbConn connAlias ReceiveQueue {server, rcvId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET rcv_host = :rcv_host, rcv_port = :rcv_port, rcv_id = :rcv_id
      WHERE conn_alias = :conn_alias;
    |]
    [":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId, ":conn_alias" := connAlias]

-- * setRcvQueueStatus helper

-- ? throw error if queue doesn't exist?
updateRcvQueueStatus :: DB.Connection -> ReceiveQueue -> QueueStatus -> IO ()
updateRcvQueueStatus dbConn ReceiveQueue {rcvId, server = SMPServer {host, port}} status =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE rcv_queues
      SET status = :status
      WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
    |]
    [":status" := status, ":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]

-- * setSndQueueStatus helper

-- ? throw error if queue doesn't exist?
updateSndQueueStatus :: DB.Connection -> SendQueue -> QueueStatus -> IO ()
updateSndQueueStatus dbConn SendQueue {sndId, server = SMPServer {host, port}} status =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE snd_queues
      SET status = :status
      WHERE host = :host AND port = :port AND snd_id = :snd_id;
    |]
    [":status" := status, ":host" := host, ":port" := serializePort_ port, ":snd_id" := sndId]

-- * createRcvMsg helpers

insertRcvMsg ::
  DB.Connection ->
  ConnAlias ->
  MsgBody ->
  ExternalSndId ->
  ExternalSndTs ->
  BrokerId ->
  BrokerTs ->
  IO (Either StoreError ())
insertRcvMsg dbConn connAlias msgBody externalSndId externalSndTs brokerId brokerTs =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues_ dbConn connAlias
    case queues of
      (Just _rcvQ, _) -> do
        (lastInternalId, lastInternalRcvId) <- retrieveLastInternalIdsRcv_ dbConn connAlias
        let internalId = lastInternalId + 1
        let internalRcvId = lastInternalRcvId + 1
        insertRcvMsgBase_ dbConn connAlias internalId internalRcvId msgBody
        insertRcvMsgDetails_ dbConn connAlias internalRcvId internalId externalSndId externalSndTs brokerId brokerTs
        updateLastInternalIdsRcv_ dbConn connAlias internalId internalRcvId
        return $ Right ()
      (Nothing, Just _sndQ) -> return $ Left (SEBadConnType CSend)
      _ -> return $ Left SEBadConn

retrieveLastInternalIdsRcv_ :: DB.Connection -> ConnAlias -> IO (InternalId, InternalRcvId)
retrieveLastInternalIdsRcv_ dbConn connAlias = do
  [(lastInternalId, lastInternalRcvId)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  return (lastInternalId, lastInternalRcvId)

insertRcvMsgBase_ :: DB.Connection -> ConnAlias -> InternalId -> InternalRcvId -> MsgBody -> IO ()
insertRcvMsgBase_ dbConn connAlias internalId internalRcvId msgBody = do
  internalTs <- liftIO getCurrentTime
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_alias, internal_id, internal_ts, internal_rcv_id, internal_snd_id, body)
      VALUES
        (:conn_alias,:internal_id,:internal_ts,:internal_rcv_id,            NULL,:body);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_rcv_id" := internalRcvId,
      ":body" := decodeUtf8 msgBody
    ]

insertRcvMsgDetails_ ::
  DB.Connection ->
  ConnAlias ->
  InternalRcvId ->
  InternalId ->
  ExternalSndId ->
  ExternalSndTs ->
  BrokerId ->
  BrokerTs ->
  IO ()
insertRcvMsgDetails_ dbConn connAlias internalRcvId internalId externalSndId externalSndTs brokerId brokerTs =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_messages
        ( conn_alias, internal_rcv_id, internal_id, external_snd_id, external_snd_ts,
          broker_id, broker_ts, rcv_status, ack_brocker_ts, ack_sender_ts)
      VALUES
        (:conn_alias,:internal_rcv_id,:internal_id,:external_snd_id,:external_snd_ts,
         :broker_id,:broker_ts,:rcv_status,           NULL,          NULL);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_rcv_id" := internalRcvId,
      ":internal_id" := internalId,
      ":external_snd_id" := externalSndId,
      ":external_snd_ts" := externalSndTs,
      ":broker_id" := brokerId,
      ":broker_ts" := brokerTs,
      ":rcv_status" := Received
    ]

updateLastInternalIdsRcv_ :: DB.Connection -> ConnAlias -> InternalId -> InternalRcvId -> IO ()
updateLastInternalIdsRcv_ dbConn connAlias newInternalId newInternalRcvId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id, last_internal_rcv_msg_id = :last_internal_rcv_msg_id
      WHERE conn_alias = :conn_alias;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_rcv_msg_id" := newInternalRcvId,
      ":conn_alias" := connAlias
    ]

-- * createSndMsg helpers

insertSndMsg :: DB.Connection -> ConnAlias -> MsgBody -> IO (Either StoreError ())
insertSndMsg dbConn connAlias msgBody =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues_ dbConn connAlias
    case queues of
      (_, Just _sndQ) -> do
        (lastInternalId, lastInternalSndId) <- retrieveLastInternalIdsSnd_ dbConn connAlias
        let internalId = lastInternalId + 1
        let internalSndId = lastInternalSndId + 1
        insertSndMsgBase_ dbConn connAlias internalId internalSndId msgBody
        insertSndMsgDetails_ dbConn connAlias internalSndId internalId
        updateLastInternalIdsSnd_ dbConn connAlias internalId internalSndId
        return $ Right ()
      (Just _rcvQ, Nothing) -> return $ Left (SEBadConnType CReceive)
      _ -> return $ Left SEBadConn

retrieveLastInternalIdsSnd_ :: DB.Connection -> ConnAlias -> IO (InternalId, InternalSndId)
retrieveLastInternalIdsSnd_ dbConn connAlias = do
  [(lastInternalId, lastInternalSndId)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_snd_msg_id
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  return (lastInternalId, lastInternalSndId)

insertSndMsgBase_ :: DB.Connection -> ConnAlias -> InternalId -> InternalSndId -> MsgBody -> IO ()
insertSndMsgBase_ dbConn connAlias internalId internalSndId msgBody = do
  internalTs <- liftIO getCurrentTime
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_alias, internal_id, internal_ts, internal_rcv_id, internal_snd_id, body)
      VALUES
        (:conn_alias,:internal_id,:internal_ts,            NULL,:internal_snd_id,:body);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_snd_id" := internalSndId,
      ":body" := decodeUtf8 msgBody
    ]

insertSndMsgDetails_ :: DB.Connection -> ConnAlias -> InternalSndId -> InternalId -> IO ()
insertSndMsgDetails_ dbConn connAlias internalSndId internalId =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_alias, internal_snd_id, internal_id, snd_status, sent_ts, delivered_ts)
      VALUES
        (:conn_alias,:internal_snd_id,:internal_id,:snd_status,    NULL,         NULL);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_snd_id" := internalSndId,
      ":internal_id" := internalId,
      ":snd_status" := Created
    ]

updateLastInternalIdsSnd_ :: DB.Connection -> ConnAlias -> InternalId -> InternalSndId -> IO ()
updateLastInternalIdsSnd_ dbConn connAlias newInternalId newInternalSndId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id, last_internal_snd_msg_id = :last_internal_snd_msg_id
      WHERE conn_alias = :conn_alias;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_snd_msg_id" := newInternalSndId,
      ":conn_alias" := connAlias
    ]
