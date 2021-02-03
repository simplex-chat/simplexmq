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
import Data.Time (getCurrentTime)
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import Network.Socket (HostName, ServiceName)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Protocol as SMP (RecipientId)
import Text.Read (readMaybe)
import qualified UnliftIO.Exception as E

-- ? replace with ToField? - it's easy to forget to use this
serializePort_ :: Maybe ServiceName -> ServiceName
serializePort_ = fromMaybe "_"

deserializePort_ :: ServiceName -> Maybe ServiceName
deserializePort_ port
  | port == "_" = Nothing
  | otherwise = Just port

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromFieldToReadable_

instance ToField QueueDirection where toField = toField . show

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

createRcvQueueAndConn :: DB.Connection -> ReceiveQueue -> IO ()
createRcvQueueAndConn dbConn rcvQueue =
  DB.withTransaction dbConn $ do
    upsertServer_ dbConn (server (rcvQueue :: ReceiveQueue))
    insertRcvQueue_ dbConn rcvQueue
    insertRcvConnection_ dbConn rcvQueue

createSndQueueAndConn :: DB.Connection -> SendQueue -> IO ()
createSndQueueAndConn dbConn sndQueue =
  DB.withTransaction dbConn $ do
    upsertServer_ dbConn (server (sndQueue :: SendQueue))
    insertSndQueue_ dbConn sndQueue
    insertSndConnection_ dbConn sndQueue

upsertServer_ :: DB.Connection -> SMPServer -> IO ()
upsertServer_ dbConn SMPServer {host, port, keyHash} = do
  let port_ = serializePort_ port
  DB.executeNamed
    dbConn
    upsertServerQuery_
    [":host" := host, ":port" := port_, ":key_hash" := keyHash]

upsertServerQuery_ :: Query
upsertServerQuery_ =
  [sql|
    INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
    ON CONFLICT (host, port) DO UPDATE SET
      host=excluded.host,
      port=excluded.port,
      key_hash=excluded.key_hash;
  |]

insertRcvQueue_ :: DB.Connection -> ReceiveQueue -> IO ()
insertRcvQueue_ dbConn ReceiveQueue {..} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    insertRcvQueueQuery_
    [":host" := host server, ":port" := port_, ":rcv_id" := rcvId, ":conn_alias" := connAlias, ":rcv_private_key" := rcvPrivateKey, ":snd_id" := sndId, ":snd_key" := sndKey, ":decrypt_key" := decryptKey, ":verify_key" := verifyKey, ":status" := status]

insertRcvQueueQuery_ :: Query
insertRcvQueueQuery_ =
  [sql|
    INSERT INTO rcv_queues
      ( host, port, rcv_id, conn_alias, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status)
    VALUES
      (:host,:port,:rcv_id,:conn_alias,:rcv_private_key,:snd_id,:snd_key,:decrypt_key,:verify_key,:status);
  |]

insertRcvConnection_ :: DB.Connection -> ReceiveQueue -> IO ()
insertRcvConnection_ dbConn ReceiveQueue {server, rcvId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    insertRcvConnectionQuery_
    [":conn_alias" := connAlias, ":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId]

insertRcvConnectionQuery_ :: Query
insertRcvConnectionQuery_ =
  [sql|
    INSERT INTO connections
      ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
    VALUES
      (:conn_alias,:rcv_host,:rcv_port,:rcv_id,     NULL,     NULL,   NULL);
  |]

insertSndQueue_ :: DB.Connection -> SendQueue -> IO ()
insertSndQueue_ dbConn SendQueue {..} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    insertSndQueueQuery_
    [":host" := host server, ":port" := port_, ":snd_id" := sndId, ":conn_alias" := connAlias, ":snd_private_key" := sndPrivateKey, ":encrypt_key" := encryptKey, ":sign_key" := signKey, ":status" := status]

insertSndQueueQuery_ :: Query
insertSndQueueQuery_ =
  [sql|
    INSERT INTO snd_queues
      ( host, port, snd_id, conn_alias, snd_private_key, encrypt_key, sign_key, status)
    VALUES
      (:host,:port,:snd_id,:conn_alias,:snd_private_key,:encrypt_key,:sign_key,:status);
  |]

insertSndConnection_ :: DB.Connection -> SendQueue -> IO ()
insertSndConnection_ dbConn SendQueue {server, sndId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    insertSndConnectionQuery_
    [":conn_alias" := connAlias, ":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId]

insertSndConnectionQuery_ :: Query
insertSndConnectionQuery_ =
  [sql|
    INSERT INTO connections
      ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id)
    VALUES
      (:conn_alias,     NULL,     NULL,   NULL,:snd_host,:snd_port,:snd_id);
  |]

retrieveConnQueues :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue, Maybe SendQueue)
retrieveConnQueues dbConn connAlias =
  DB.withTransaction -- Avoid inconsistent state between queue reads
    dbConn
    $ retrieveConnQueuesTransactionless_ dbConn connAlias

-- Separate transactionless version of retrieveConnQueues to be reused in other functions that already wrap
-- multiple statements in transaction - otherwise they'd be attempting to start a transaction within a transaction
retrieveConnQueuesTransactionless_ :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue, Maybe SendQueue)
retrieveConnQueuesTransactionless_ dbConn connAlias = do
  rcvQ <- retrieveRcvQueueByConnAlias_ dbConn connAlias
  sndQ <- retrieveSndQueueByConnAlias_ dbConn connAlias
  return (rcvQ, sndQ)

retrieveRcvQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue)
retrieveRcvQueueByConnAlias_ dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      retrieveRcvQueueByConnAliasQuery_
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, rcvId, cAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer host (deserializePort_ port) keyHash
      return . Just $ ReceiveQueue srv rcvId cAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

retrieveRcvQueueByConnAliasQuery_ :: Query
retrieveRcvQueueByConnAliasQuery_ =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key, q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status
    FROM rcv_queues q
    INNER JOIN servers s ON q.host = s.host AND q.port = s.port
    WHERE q.conn_alias = :conn_alias;
  |]

retrieveSndQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe SendQueue)
retrieveSndQueueByConnAlias_ dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      retrieveSndQueueByConnAliasQuery_
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, sndId, cAlias, sndPrivateKey, encryptKey, signKey, status)] -> do
      let srv = SMPServer host (deserializePort_ port) keyHash
      return . Just $ SendQueue srv sndId cAlias sndPrivateKey encryptKey signKey status
    _ -> return Nothing

retrieveSndQueueByConnAliasQuery_ :: Query
retrieveSndQueueByConnAliasQuery_ =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.snd_id, q.conn_alias, q.snd_private_key, q.encrypt_key, q.sign_key, q.status
    FROM snd_queues q
    INNER JOIN servers s ON q.host = s.host AND q.port = s.port
    WHERE q.conn_alias = :conn_alias;
  |]

-- ? make server an argument and pass it for the queue instead of joining with 'servers'?
-- ? the downside would be the queue having an outdated 'key_hash' if it has changed,
-- ? but maybe it's unwanted behavior?
retrieveRcvQueue :: DB.Connection -> HostName -> Maybe ServiceName -> SMP.RecipientId -> IO (Maybe ReceiveQueue)
retrieveRcvQueue dbConn host port rcvId = do
  r <-
    DB.queryNamed
      dbConn
      retrieveRcvQueueQuery_
      [":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]
  case r of
    [(keyHash, hst, prt, rId, connAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer hst (deserializePort_ prt) keyHash
      return . Just $ ReceiveQueue srv rId connAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

retrieveRcvQueueQuery_ :: Query
retrieveRcvQueueQuery_ =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key, q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status
    FROM rcv_queues q
    INNER JOIN servers s ON q.host = s.host AND q.port = s.port
    WHERE q.host = :host AND q.port = :port AND q.rcv_id = :rcv_id;
  |]

deleteConnCascade :: DB.Connection -> ConnAlias -> IO ()
deleteConnCascade dbConn connAlias =
  DB.executeNamed
    dbConn
    "DELETE FROM connections WHERE conn_alias = :conn_alias;"
    [":conn_alias" := connAlias]

-- ? rewrite with ExceptT?
updateRcvConnWithSndQueue :: DB.Connection -> ConnAlias -> SendQueue -> IO (Either StoreError ())
updateRcvConnWithSndQueue dbConn connAlias sndQueue =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueuesTransactionless_ dbConn connAlias
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
    updateConnWithSndQueueQuery_
    [":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId, ":conn_alias" := connAlias]

updateConnWithSndQueueQuery_ :: Query
updateConnWithSndQueueQuery_ =
  [sql|
    UPDATE connections
    SET snd_host = :snd_host, snd_port = :snd_port, snd_id = :snd_id
    WHERE conn_alias = :conn_alias;
  |]

-- ? rewrite with ExceptT?
updateSndConnWithRcvQueue :: DB.Connection -> ConnAlias -> ReceiveQueue -> IO (Either StoreError ())
updateSndConnWithRcvQueue dbConn connAlias rcvQueue =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueuesTransactionless_ dbConn connAlias
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
    updateConnWithRcvQueueQuery_
    [":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId, ":conn_alias" := connAlias]

updateConnWithRcvQueueQuery_ :: Query
updateConnWithRcvQueueQuery_ =
  [sql|
    UPDATE connections
    SET rcv_host = :rcv_host, rcv_port = :rcv_port, rcv_id = :rcv_id
    WHERE conn_alias = :conn_alias;
  |]

-- ? throw error if queue doesn't exist?
updateRcvQueueStatus :: DB.Connection -> ReceiveQueue -> QueueStatus -> IO ()
updateRcvQueueStatus dbConn ReceiveQueue {rcvId, server = SMPServer {host, port}} status =
  DB.executeNamed
    dbConn
    updateRcvQueueStatusQuery_
    [":status" := status, ":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]

updateRcvQueueStatusQuery_ :: Query
updateRcvQueueStatusQuery_ =
  [sql|
    UPDATE rcv_queues
    SET status = :status
    WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
  |]

-- ? throw error if queue doesn't exist?
updateSndQueueStatus :: DB.Connection -> SendQueue -> QueueStatus -> IO ()
updateSndQueueStatus dbConn SendQueue {sndId, server = SMPServer {host, port}} status =
  DB.executeNamed
    dbConn
    updateSndQueueStatusQuery_
    [":status" := status, ":host" := host, ":port" := serializePort_ port, ":snd_id" := sndId]

updateSndQueueStatusQuery_ :: Query
updateSndQueueStatusQuery_ =
  [sql|
    UPDATE snd_queues
    SET status = :status
    WHERE host = :host AND port = :port AND snd_id = :snd_id;
  |]

-- ? rewrite with ExceptT?
insertRcvMsg :: DB.Connection -> ConnAlias -> AgentMsgId -> AMessage -> IO (Either StoreError ())
insertRcvMsg dbConn connAlias agentMsgId aMsg =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueuesTransactionless_ dbConn connAlias
    case queues of
      (Just _rcvQ, _) -> do
        insertMsg_ dbConn connAlias RCV agentMsgId aMsg
        return $ Right ()
      (Nothing, Just _sndQ) -> return $ Left SEBadQueueDirection
      _ -> return $ Left SEBadConn

-- ? rewrite with ExceptT?
insertSndMsg :: DB.Connection -> ConnAlias -> AgentMsgId -> AMessage -> IO (Either StoreError ())
insertSndMsg dbConn connAlias agentMsgId aMsg =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueuesTransactionless_ dbConn connAlias
    case queues of
      (_, Just _sndQ) -> do
        insertMsg_ dbConn connAlias SND agentMsgId aMsg
        return $ Right ()
      (Just _rcvQ, Nothing) -> return $ Left SEBadQueueDirection
      _ -> return $ Left SEBadConn

-- TODO add parser and serializer for DeliveryStatus? Pass DeliveryStatus?
insertMsg_ :: DB.Connection -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> IO ()
insertMsg_ dbConn connAlias qDirection agentMsgId aMsg = do
  let msg = serializeAgentMessage aMsg
  ts <- liftIO getCurrentTime
  DB.executeNamed
    dbConn
    insertMsgQuery_
    [":agent_msg_id" := agentMsgId, ":conn_alias" := connAlias, ":timestamp" := ts, ":message" := msg, ":direction" := qDirection]

insertMsgQuery_ :: Query
insertMsgQuery_ =
  [sql|
    INSERT INTO messages
      ( agent_msg_id, conn_alias, timestamp, message, direction, msg_status)
    VALUES
      (:agent_msg_id,:conn_alias,:timestamp,:message,:direction,"MDTransmitted");
  |]
