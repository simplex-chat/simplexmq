{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Store.SQLite where

import Control.Monad.IO.Unlift
import Data.Int (Int64)
import qualified Data.Text as T
import Database.SQLite.Simple hiding (Connection)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok
import Database.SQLite.Simple.ToField
import Multiline (s)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Schema
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server.Transmission (PublicKey, QueueId)
import Simplex.Messaging.Util
import Text.Read
import qualified UnliftIO.Exception as E
import UnliftIO.STM

addRcvQueueQuery :: Query
addRcvQueueQuery =
  [s|
    INSERT INTO receive_queues
      ( server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode)
    VALUES
      (:server_id,:rcv_id,:rcv_private_key,:snd_id,:snd_key,:decrypt_key,:verify_key,:status,:ack_mode);
  |]

data SQLiteStore = SQLiteStore
  { conn :: DB.Connection,
    serversLock :: TMVar (),
    rcvQueuesLock :: TMVar (),
    sndQueuesLock :: TMVar (),
    connectionsLock :: TMVar (),
    messagesLock :: TMVar ()
  }

newSQLiteStore :: MonadUnliftIO m => String -> m SQLiteStore
newSQLiteStore dbFile = do
  conn <- liftIO $ DB.open dbFile
  liftIO $ createSchema conn
  serversLock <- newTMVarIO ()
  rcvQueuesLock <- newTMVarIO ()
  sndQueuesLock <- newTMVarIO ()
  connectionsLock <- newTMVarIO ()
  messagesLock <- newTMVarIO ()
  return
    SQLiteStore
      { conn,
        serversLock,
        rcvQueuesLock,
        sndQueuesLock,
        connectionsLock,
        messagesLock
      }

type QueueRowId = Int64

type ConnectionRowId = Int64

fromFieldToReadable :: forall a. (Read a, E.Typeable a) => Field -> Ok a
fromFieldToReadable = \case
  f@(Field (SQLText t) _) ->
    let s = T.unpack t
     in case readMaybe s of
          Just x -> Ok x
          _ -> returnError ConversionFailed f ("invalid string: " ++ s)
  f -> returnError ConversionFailed f "expecting SQLText column type"

withLock :: MonadUnliftIO m => SQLiteStore -> (SQLiteStore -> TMVar ()) -> (DB.Connection -> m a) -> m a
withLock st tableLock f = do
  let lock = tableLock st
  E.bracket_
    (atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())
    (f $ conn st)

insertWithLock :: (MonadUnliftIO m, ToRow q) => SQLiteStore -> (SQLiteStore -> TMVar ()) -> DB.Query -> q -> m Int64
insertWithLock st tableLock queryStr q = do
  withLock st tableLock $ \c -> liftIO $ do
    DB.execute c queryStr q
    DB.lastInsertRowId c

executeWithLock :: (MonadUnliftIO m, ToRow q) => SQLiteStore -> (SQLiteStore -> TMVar ()) -> DB.Query -> q -> m ()
executeWithLock st tableLock queryStr q = do
  withLock st tableLock $ \c -> liftIO $ do
    DB.execute c queryStr q

instance ToRow SMPServer where
  toRow SMPServer {host, port, keyHash} = toRow (host, port, keyHash)

instance FromRow SMPServer where
  fromRow = SMPServer <$> field <*> field <*> field

upsertServer :: MonadUnliftIO m => SQLiteStore -> SMPServer -> m (Either StoreError SMPServerId)
upsertServer SQLiteStore {conn} srv@SMPServer {host, port} = liftIO $ do
  DB.execute
    conn
    [s|
      INSERT INTO servers (host, port, key_hash) VALUES (?, ?, ?)
      ON CONFLICT (host, port) DO UPDATE SET
        host=excluded.host,
        port=excluded.port,
        key_hash=excluded.key_hash;
    |]
    srv
  r <-
    DB.queryNamed
      conn
      "SELECT server_id FROM servers WHERE host = :host AND port = :port"
      [":host" := host, ":port" := port]
  return $ case r of
    [Only serverId] -> Right serverId
    _ -> Left SEInternal

getServer :: MonadUnliftIO m => SQLiteStore -> SMPServerId -> m (Either StoreError SMPServer)
getServer SQLiteStore {conn} serverId = liftIO $ do
  r <-
    DB.queryNamed
      conn
      "SELECT host, port, key_hash FROM servers WHERE server_id = :server_id"
      [":server_id" := serverId]
  return $ case r of
    [smpServer] -> Right smpServer
    _ -> Left SENotFound

instance ToField AckMode where toField (AckMode mode) = toField $ show mode

instance FromField AckMode where fromField = AckMode <$$> fromFieldToReadable

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromFieldToReadable

instance ToRow ReceiveQueue where
  toRow ReceiveQueue {rcvId, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status, ackMode} =
    toRow (rcvId, rcvPrivateKey, sndId, sndKey, decryptKey, verifyKey, status, ackMode)

instance FromRow ReceiveQueue where
  fromRow = ReceiveQueue undefined <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

-- TODO refactor into a single query with join
getRcvQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m (Either StoreError ReceiveQueue)
getRcvQueue st@SQLiteStore {conn} queueRowId = liftIO $ do
  r <-
    DB.queryNamed
      conn
      [s|
        SELECT server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode
        FROM receive_queues
        WHERE receive_queue_id = :rowId;
      |]
      [":rowId" := queueRowId]
  case r of
    [Only serverId :. rcvQueue] ->
      (\srv -> (rcvQueue {server = srv} :: ReceiveQueue)) <$$> getServer st serverId
    _ -> return (Left SENotFound)

-- TODO refactor into a single query with join
getSndQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m (Either StoreError SendQueue)
getSndQueue st@SQLiteStore {conn} queueRowId = liftIO $ do
  r <-
    DB.queryNamed
      conn
      [s|
        SELECT server_id, snd_id, snd_private_key, encrypt_key, sign_key, status, ack_mode
        FROM send_queues
        WHERE send_queue_id = :rowId;
      |]
      [":rowId" := queueRowId]
  case r of
    [Only serverId :. sndQueue] ->
      (\srv -> (sndQueue {server = srv} :: SendQueue)) <$$> getServer st serverId
    _ -> return (Left SENotFound)

insertRcvQueue :: MonadUnliftIO m => SQLiteStore -> SMPServerId -> ReceiveQueue -> m QueueRowId
insertRcvQueue store serverId rcvQueue =
  insertWithLock
    store
    rcvQueuesLock
    [s|
      INSERT INTO receive_queues
        ( server_id, rcv_id, rcv_private_key, snd_id, snd_key, decrypt_key, verify_key, status, ack_mode)
      VALUES (?,?,?,?,?,?,?,?,?);
    |]
    (Only serverId :. rcvQueue)

insertRcvConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ConnectionRowId
insertRcvConnection store connAlias rcvQueueId =
  insertWithLock
    store
    connectionsLock
    "INSERT INTO connections (conn_alias, receive_queue_id, send_queue_id) VALUES (?,?,NULL);"
    (Only connAlias :. Only rcvQueueId)

updateRcvConnectionWithSndQueue :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
updateRcvConnectionWithSndQueue store connAlias sndQueueId =
  executeWithLock
    store
    connectionsLock
    [s|
      UPDATE connections
      SET send_queue_id = ?
      WHERE conn_alias = ?;
    |]
    (Only sndQueueId :. Only connAlias)

instance ToRow SendQueue where
  toRow SendQueue {sndId, sndPrivateKey, encryptKey, signKey, status, ackMode} =
    toRow (sndId, sndPrivateKey, encryptKey, signKey, status, ackMode)

instance FromRow SendQueue where
  fromRow = SendQueue undefined <$> field <*> field <*> field <*> field <*> field <*> field

insertSndQueue :: MonadUnliftIO m => SQLiteStore -> SMPServerId -> SendQueue -> m QueueRowId
insertSndQueue store serverId sndQueue =
  insertWithLock
    store
    sndQueuesLock
    [s|
      INSERT INTO send_queues
        ( server_id, snd_id, snd_private_key, encrypt_key, sign_key, status, ack_mode)
      VALUES (?,?,?,?,?,?,?);
    |]
    (Only serverId :. sndQueue)

insertSndConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ConnectionRowId
insertSndConnection store connAlias sndQueueId =
  insertWithLock
    store
    connectionsLock
    "INSERT INTO connections (conn_alias, receive_queue_id, send_queue_id) VALUES (?,NULL,?);"
    (Only connAlias :. Only sndQueueId)

updateSndConnectionWithRcvQueue :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
updateSndConnectionWithRcvQueue store connAlias rcvQueueId =
  executeWithLock
    store
    connectionsLock
    [s|
      UPDATE connections
      SET receive_queue_id = ?
      WHERE conn_alias = ?;
    |]
    (Only rcvQueueId :. Only connAlias)

getConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> m (Either StoreError (Maybe QueueRowId, Maybe QueueRowId))
getConnection SQLiteStore {conn} connAlias = liftIO $ do
  r <-
    DB.queryNamed
      conn
      "SELECT receive_queue_id, send_queue_id FROM connections WHERE conn_alias = :conn_alias"
      [":conn_alias" := connAlias]
  return $ case r of
    [queueIds] -> Right queueIds
    _ -> Left SEInternal

instance MonadUnliftIO m => MonadAgentStore SQLiteStore m where
  addServer store smpServer = upsertServer store smpServer

  createRcvConn :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m (Either StoreError (Connection CReceive))
  createRcvConn st connAlias rcvQueue =
    upsertServer st (server (rcvQueue :: ReceiveQueue))
      >>= either (return . Left) (fmap Right . addConnection)
    where
      addConnection serverId = do
        qId <- insertRcvQueue st serverId rcvQueue -- TODO test for duplicate connAlias
        insertRcvConnection st connAlias qId
        return $ ReceiveConnection connAlias rcvQueue

  createSndConn :: SQLiteStore -> ConnAlias -> SendQueue -> m (Either StoreError (Connection CSend))
  createSndConn st connAlias sndQueue =
    upsertServer st (server (sndQueue :: SendQueue))
      >>= either (return . Left) (fmap Right . addConnection)
    where
      addConnection serverId = do
        qId <- insertSndQueue st serverId sndQueue -- TODO test for duplicate connAlias
        insertSndConnection st connAlias qId
        return $ SendConnection connAlias sndQueue

  -- TODO refactor ito a single query with join, and parse as `Only connAlias :. rcvQueue :. sndQueue`
  getConn :: SQLiteStore -> ConnAlias -> m (Either StoreError SomeConn)
  getConn st connAlias =
    getConnection st connAlias >>= \case
      Left e -> return $ Left e
      Right (Just rcvQId, Just sndQId) -> do
        rcvQ <- getRcvQueue st rcvQId
        sndQ <- getSndQueue st sndQId
        return $ SomeConn SCDuplex <$> (DuplexConnection connAlias <$> rcvQ <*> sndQ)
      Right (Just rcvQId, _) ->
        getRcvQueue st rcvQId
          >>= return . fmap (SomeConn SCReceive . ReceiveConnection connAlias)
      Right (_, Just sndQId) ->
        getSndQueue st sndQId
          >>= return . fmap (SomeConn SCSend . SendConnection connAlias)
      Right (_, _) -> return $ Left SEBadConn

  -- TODO make transactional
  addSndQueue :: SQLiteStore -> ConnAlias -> SendQueue -> m (Either StoreError ())
  addSndQueue st connAlias sndQueue =
    getConn st connAlias
      >>= either (return . Left) checkUpdateConn
    where
      checkUpdateConn :: SomeConn -> m (Either StoreError ())
      checkUpdateConn = \case
        SomeConn SCDuplex _ -> return $ Left (SEBadConnType CDuplex)
        SomeConn SCSend _ -> return $ Left (SEBadConnType CSend)
        SomeConn SCReceive _ ->
          upsertServer st (server (sndQueue :: SendQueue))
            >>= either (return . Left) (fmap Right . updateConn)

      updateConn :: SMPServerId -> m ()
      updateConn servId =
        insertSndQueue st servId sndQueue
          >>= updateRcvConnectionWithSndQueue st connAlias

  -- TODO make transactional
  addRcvQueue :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m (Either StoreError ())
  addRcvQueue st connAlias rcvQueue =
    getConn st connAlias
      >>= either (return . Left) checkUpdateConn
    where
      checkUpdateConn :: SomeConn -> m (Either StoreError ())
      checkUpdateConn = \case
        SomeConn SCDuplex _ -> return $ Left (SEBadConnType CDuplex)
        SomeConn SCReceive _ -> return $ Left (SEBadConnType CReceive)
        SomeConn SCSend _ ->
          upsertServer st (server (rcvQueue :: ReceiveQueue))
            >>= either (return . Left) (fmap Right . updateConn)

      updateConn :: SMPServerId -> m ()
      updateConn servId =
        insertRcvQueue st servId rcvQueue
          >>= updateSndConnectionWithRcvQueue st connAlias
