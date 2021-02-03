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

-- TODO replace with ToField - it's easy to forget to use this
_serializePort :: Maybe ServiceName -> ServiceName
_serializePort = fromMaybe "_"

_deserializePort :: ServiceName -> Maybe ServiceName
_deserializePort port
  | port == "_" = Nothing
  | otherwise = Just port

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromFieldToReadable

instance ToField QueueDirection where toField = toField . show

fromFieldToReadable :: forall a. (Read a, E.Typeable a) => Field -> Ok a
fromFieldToReadable = \case
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
  let _port = _serializePort port
  DB.executeNamed
    dbConn
    _upsertServerQuery
    [":host" := host, ":port" := _port, ":key_hash" := keyHash]

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
  let _port = _serializePort $ port server
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
  let _port = _serializePort $ port server
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
  let _port = _serializePort $ port server
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
  let _port = _serializePort $ port server
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
  -- to avoid inconsistent state between queue reads
  DB.withTransaction dbConn $ do
    rcvQ <- _retrieveRcvQueueByConnAlias dbConn connAlias
    sndQ <- _retrieveSndQueueByConnAlias dbConn connAlias
    return (rcvQ, sndQ)

_retrieveRcvQueueByConnAlias :: DB.Connection -> ConnAlias -> IO (Maybe ReceiveQueue)
_retrieveRcvQueueByConnAlias dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      _retrieveRcvQueueByConnAliasQuery
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, rcvId, cAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer host (_deserializePort port) keyHash
      return . Just $ ReceiveQueue srv rcvId cAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

_retrieveRcvQueueByConnAliasQuery :: Query
_retrieveRcvQueueByConnAliasQuery =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key, q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status)
    FROM rcv_queues q
    INNER JOIN servers s ON q.host = s.host AND q.port = s.port
    WHERE q.conn_alias = :conn_alias;
  |]

_retrieveSndQueueByConnAlias :: DB.Connection -> ConnAlias -> IO (Maybe SendQueue)
_retrieveSndQueueByConnAlias dbConn connAlias = do
  r <-
    DB.queryNamed
      dbConn
      _retrieveSndQueueByConnAliasQuery
      [":conn_alias" := connAlias]
  case r of
    [(keyHash, host, port, sndId, cAlias, sndPrivateKey, encryptKey, signKey, status)] -> do
      let srv = SMPServer host (_deserializePort port) keyHash
      return . Just $ SendQueue srv sndId cAlias sndPrivateKey encryptKey signKey status
    _ -> return Nothing

_retrieveSndQueueByConnAliasQuery :: Query
_retrieveSndQueueByConnAliasQuery =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.snd_id, q.conn_alias, q.snd_private_key, q.encrypt_key, q.sign_key, q.status)
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
      _retrieveRcvQueueQuery
      [":host" := host, ":port" := _serializePort port, ":rcv_id" := rcvId]
  case r of
    [(keyHash, hst, prt, rId, connAlias, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status)] -> do
      let srv = SMPServer hst (_deserializePort prt) keyHash
      return . Just $ ReceiveQueue srv rId connAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

_retrieveRcvQueueQuery :: Query
_retrieveRcvQueueQuery =
  [sql|
    SELECT s.key_hash, q.host, q.port, q.rcv_id, q.conn_alias, q.rcv_private_key, q.snd_id, q.snd_key, q.decrypt_key, q.verify_key, q.status)
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
    queues <- retrieveConnQueues dbConn connAlias
    case queues of
      (Just _rcvQ, Nothing) -> do
        _upsertServer dbConn (server (sndQueue :: SendQueue))
        _insertSndQueue dbConn sndQueue
        _updateConnWithSndQueue dbConn connAlias sndQueue
        return $ Right ()
      (Nothing, Just _sndQ) -> return $ Left (SEBadConnType CSend)
      (Just _rcvQ, Just _sndQ) -> return $ Left (SEBadConnType CDuplex)
      _ -> return $ Left SEBadConn

_updateConnWithSndQueue :: DB.Connection -> ConnAlias -> SendQueue -> IO ()
_updateConnWithSndQueue dbConn connAlias SendQueue {server, sndId} = do
  let _port = _serializePort $ port server
  DB.executeNamed
    dbConn
    _updateConnWithSndQueueQuery
    [":snd_host" := host server, ":snd_port" := _port, ":snd_id" := sndId, ":conn_alias" := connAlias]

_updateConnWithSndQueueQuery :: Query
_updateConnWithSndQueueQuery =
  [sql|
    UPDATE connections
    SET snd_host = :snd_host, snd_port = :snd_port, snd_id = :snd_id
    WHERE conn_alias = :conn_alias;
  |]

-- ? rewrite with ExceptT?
updateSndConnWithRcvQueue :: DB.Connection -> ConnAlias -> ReceiveQueue -> IO (Either StoreError ())
updateSndConnWithRcvQueue dbConn connAlias rcvQueue =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues dbConn connAlias
    case queues of
      (Nothing, Just _sndQ) -> do
        _upsertServer dbConn (server (rcvQueue :: ReceiveQueue))
        _insertRcvQueue dbConn rcvQueue
        _updateConnWithRcvQueue dbConn connAlias rcvQueue
        return $ Right ()
      (Just _rcvQ, Nothing) -> return $ Left (SEBadConnType CReceive)
      (Just _rcvQ, Just _sndQ) -> return $ Left (SEBadConnType CDuplex)
      _ -> return $ Left SEBadConn

_updateConnWithRcvQueue :: DB.Connection -> ConnAlias -> ReceiveQueue -> IO ()
_updateConnWithRcvQueue dbConn connAlias ReceiveQueue {server, rcvId} = do
  let _port = _serializePort $ port server
  DB.executeNamed
    dbConn
    _updateConnWithRcvQueueQuery
    [":rcv_host" := host server, ":rcv_port" := _port, ":rcv_id" := rcvId, ":conn_alias" := connAlias]

_updateConnWithRcvQueueQuery :: Query
_updateConnWithRcvQueueQuery =
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
    _updateRcvQueueStatusQuery
    [":status" := status, ":host" := host, ":port" := _serializePort port, ":rcv_id" := rcvId]

_updateRcvQueueStatusQuery :: Query
_updateRcvQueueStatusQuery =
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
    _updateSndQueueStatusQuery
    [":status" := status, ":host" := host, ":port" := _serializePort port, ":snd_id" := sndId]

_updateSndQueueStatusQuery :: Query
_updateSndQueueStatusQuery =
  [sql|
    UPDATE snd_queues
    SET status = :status
    WHERE host = :host AND port = :port AND snd_id = :snd_id;
  |]

-- ? rewrite with ExceptT?
insertRcvMsg :: DB.Connection -> ConnAlias -> AgentMsgId -> AMessage -> IO (Either StoreError ())
insertRcvMsg dbConn connAlias agentMsgId aMsg =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues dbConn connAlias
    case queues of
      (Just _rcvQ, _) -> do
        _insertMsg dbConn connAlias RCV agentMsgId aMsg
        return $ Right ()
      (Nothing, Just _sndQ) -> return $ Left SEBadQueueDirection
      _ -> return $ Left SEBadConn

-- ? rewrite with ExceptT?
insertSndMsg :: DB.Connection -> ConnAlias -> AgentMsgId -> AMessage -> IO (Either StoreError ())
insertSndMsg dbConn connAlias agentMsgId aMsg =
  DB.withTransaction dbConn $ do
    queues <- retrieveConnQueues dbConn connAlias
    case queues of
      (_, Just _sndQ) -> do
        _insertMsg dbConn connAlias SND agentMsgId aMsg
        return $ Right ()
      (Just _rcvQ, Nothing) -> return $ Left SEBadQueueDirection
      _ -> return $ Left SEBadConn

-- TODO add parser and serializer for DeliveryStatus? Pass DeliveryStatus?
_insertMsg :: DB.Connection -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> IO ()
_insertMsg dbConn connAlias qDirection agentMsgId aMsg = do
  let msg = serializeAgentMessage aMsg
  ts <- liftIO getCurrentTime
  DB.executeNamed
    dbConn
    _insertMsgQuery
    [":agent_msg_id" := agentMsgId, ":conn_alias" := connAlias, ":timestamp" := ts, ":message" := msg, ":message" := qDirection]

_insertMsgQuery :: Query
_insertMsgQuery =
  [sql|
    INSERT INTO messages
      ( agent_msg_id, conn_alias, timestamp, message, direction, msg_status)
    VALUES
      (:agent_msg_id,:conn_alias,:timestamp,:message,:direction,"MDTransmitted");
  |]
