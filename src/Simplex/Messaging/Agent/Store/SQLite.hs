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
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Agent.Store.SQLite where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Data.Int (Int64)
import Data.Maybe
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

upsertServer :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> SMPServer -> m SMPServerId
upsertServer SQLiteStore {conn} srv@SMPServer {host, port} = do
  r <- liftIO $ do
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
    DB.queryNamed
      conn
      "SELECT server_id FROM servers WHERE host = :host AND port = :port"
      [":host" := host, ":port" := port]
  case r of
    [Only serverId] -> return serverId
    _ -> throwError SEInternal

getServer :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> SMPServerId -> m SMPServer
getServer SQLiteStore {conn} serverId = do
  r <-
    liftIO $
      DB.queryNamed
        conn
        "SELECT host, port, key_hash FROM servers WHERE server_id = :server_id"
        [":server_id" := serverId]
  case r of
    [smpServer] -> return smpServer
    _ -> throwError SENotFound

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
getRcvQueue :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> QueueRowId -> m ReceiveQueue
getRcvQueue st@SQLiteStore {conn} queueRowId = do
  r <-
    liftIO $
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
      (\srv -> (rcvQueue {server = srv} :: ReceiveQueue)) <$> getServer st serverId
    _ -> throwError SENotFound

-- TODO refactor into a single query with join
getSndQueue :: (MonadUnliftIO m, MonadError StoreError m) => SQLiteStore -> QueueRowId -> m SendQueue
getSndQueue st@SQLiteStore {conn} queueRowId = do
  r <-
    liftIO $
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
      (\srv -> (sndQueue {server = srv} :: SendQueue)) <$> getServer st serverId
    _ -> throwError SENotFound

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

insertRcvConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
insertRcvConnection store connAlias rcvQueueId =
  void $
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

insertSndConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> QueueRowId -> m ()
insertSndConnection store connAlias sndQueueId =
  void $
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

getConnection :: (MonadError StoreError m, MonadUnliftIO m) => SQLiteStore -> ConnAlias -> m (Maybe QueueRowId, Maybe QueueRowId)
getConnection SQLiteStore {conn} connAlias = do
  r <-
    liftIO $
      DB.queryNamed
        conn
        "SELECT receive_queue_id, send_queue_id FROM connections WHERE conn_alias = :conn_alias"
        [":conn_alias" := connAlias]
  case r of
    [queueIds] -> return queueIds
    _ -> throwError SEInternal

deleteRcvQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m ()
deleteRcvQueue store rcvQueueId = do
  executeWithLock
    store
    rcvQueuesLock
    "DELETE FROM receive_queues WHERE receive_queue_id = ?"
    (Only rcvQueueId)

deleteSndQueue :: MonadUnliftIO m => SQLiteStore -> QueueRowId -> m ()
deleteSndQueue store sndQueueId = do
  executeWithLock
    store
    sndQueuesLock
    "DELETE FROM send_queues WHERE send_queue_id = ?"
    (Only sndQueueId)

deleteConnection :: MonadUnliftIO m => SQLiteStore -> ConnAlias -> m ()
deleteConnection store connAlias = do
  executeWithLock
    store
    connectionsLock
    "DELETE FROM connections WHERE conn_alias = ?"
    (Only connAlias)

instance (MonadUnliftIO m, MonadError StoreError m) => MonadAgentStore SQLiteStore m where
  addServer store smpServer = upsertServer store smpServer

  createRcvConn :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m ()
  createRcvConn st connAlias rcvQueue = do
    -- TODO test for duplicate connAlias
    srvId <- upsertServer st (server (rcvQueue :: ReceiveQueue))
    rcvQId <- insertRcvQueue st srvId rcvQueue
    insertRcvConnection st connAlias rcvQId

  createSndConn :: SQLiteStore -> ConnAlias -> SendQueue -> m ()
  createSndConn st connAlias sndQueue = do
    -- TODO test for duplicate connAlias
    srvId <- upsertServer st (server (sndQueue :: SendQueue))
    sndQ <- insertSndQueue st srvId sndQueue
    insertSndConnection st connAlias sndQ

  -- TODO refactor ito a single query with join, and parse as `Only connAlias :. rcvQueue :. sndQueue`
  getConn :: SQLiteStore -> ConnAlias -> m SomeConn
  getConn st connAlias =
    getConnection st connAlias >>= \case
      (Just rcvQId, Just sndQId) -> do
        rcvQ <- getRcvQueue st rcvQId
        sndQ <- getSndQueue st sndQId
        return $ SomeConn SCDuplex (DuplexConnection connAlias rcvQ sndQ)
      (Just rcvQId, _) -> do
        rcvQ <- getRcvQueue st rcvQId
        return $ SomeConn SCReceive (ReceiveConnection connAlias rcvQ)
      (_, Just sndQId) -> do
        sndQ <- getSndQueue st sndQId
        return $ SomeConn SCSend (SendConnection connAlias sndQ)
      _ -> throwError SEBadConn

  -- TODO make transactional
  addSndQueue :: SQLiteStore -> ConnAlias -> SendQueue -> m ()
  addSndQueue st connAlias sndQueue =
    getConn st connAlias
      >>= \case
        SomeConn SCDuplex _ -> throwError (SEBadConnType CDuplex)
        SomeConn SCSend _ -> throwError (SEBadConnType CSend)
        SomeConn SCReceive _ -> do
          srvId <- upsertServer st (server (sndQueue :: SendQueue))
          sndQ <- insertSndQueue st srvId sndQueue
          updateRcvConnectionWithSndQueue st connAlias sndQ

  -- TODO make transactional
  addRcvQueue :: SQLiteStore -> ConnAlias -> ReceiveQueue -> m ()
  addRcvQueue st connAlias rcvQueue =
    getConn st connAlias
      >>= \case
        SomeConn SCDuplex _ -> throwError (SEBadConnType CDuplex)
        SomeConn SCReceive _ -> throwError (SEBadConnType CReceive)
        SomeConn SCSend _ -> do
          srvId <- upsertServer st (server (rcvQueue :: ReceiveQueue))
          rcvQ <- insertRcvQueue st srvId rcvQueue
          updateSndConnectionWithRcvQueue st connAlias rcvQ

  -- TODO think about design of one-to-one relationships between connections ans send/receive queues
  -- - Make wide `connections` table? -> Leads to inability to constrain queue fields on SQL level
  -- - Make bi-directional foreign keys deferred on queue side?
  --   * Involves populating foreign keys on queues' tables and reworking store
  --   * Enables cascade deletes
  --   ? See https://sqlite.org/foreignkeys.html#fk_deferred
  -- - Keep as is and just wrap in transaction?
  deleteConn :: SQLiteStore -> ConnAlias -> m ()
  deleteConn st connAlias = do
    (rcvQId, sndQId) <- getConnection st connAlias
    forM_ rcvQId $ deleteRcvQueue st
    forM_ sndQId $ deleteSndQueue st
    deleteConnection st connAlias
    when (isNothing rcvQId && isNothing sndQId) $ throwError SEBadConn
