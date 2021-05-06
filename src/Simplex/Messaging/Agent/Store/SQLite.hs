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
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( SQLiteStore (..),
    createSQLiteStore,
    connectSQLiteStore,
  )
where

import Control.Monad (when)
import Control.Monad.Except (MonadError (throwError), MonadIO (liftIO))
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Bifunctor (first)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (isPrefixOf)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Database.SQLite.Simple (FromRow, NamedParam (..), Only (..), SQLData (..), SQLError, field)
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import Network.Socket (ServiceName)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Schema (createSchema)
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Parsers (blobFieldParser)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (bshow, liftIOEither)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath (takeDirectory)
import Text.Read (readMaybe)
import UnliftIO.Directory (createDirectoryIfMissing)
import qualified UnliftIO.Exception as E

-- * SQLite Store implementation

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbConn :: DB.Connection
  }

createSQLiteStore :: MonadUnliftIO m => FilePath -> m SQLiteStore
createSQLiteStore dbFilePath = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing False dbDir
  store <- connectSQLiteStore dbFilePath
  compileOptions <- liftIO (DB.query_ (dbConn store) "pragma COMPILE_OPTIONS;" :: IO [[T.Text]])
  let threadsafeOption = find (isPrefixOf "THREADSAFE=") (concat compileOptions)
  liftIO $ case threadsafeOption of
    Just "THREADSAFE=0" -> do
      putStrLn "SQLite compiled with not threadsafe code, continue (y/n):"
      s <- getLine
      when (s /= "y") (exitWith $ ExitFailure 2)
    Nothing -> putStrLn "Warning: SQLite THREADSAFE compile option not found"
    _ -> return ()
  liftIO . createSchema $ dbConn store
  return store

connectSQLiteStore :: MonadUnliftIO m => FilePath -> m SQLiteStore
connectSQLiteStore dbFilePath = do
  dbConn <- liftIO $ DB.open dbFilePath
  liftIO $ DB.execute_ dbConn "PRAGMA foreign_keys = ON;"
  return SQLiteStore {dbFilePath, dbConn}

checkDuplicate :: (MonadUnliftIO m, MonadError StoreError m) => IO () -> m ()
checkDuplicate action = liftIOEither $ first handleError <$> E.try action
  where
    handleError :: SQLError -> StoreError
    handleError e
      | DB.sqlError e == DB.ErrorConstraint = SEConnDuplicate
      | otherwise = SEInternal $ bshow e

instance (MonadUnliftIO m, MonadError StoreError m) => MonadAgentStore SQLiteStore m where
  createRcvConn :: SQLiteStore -> RcvQueue -> m ()
  createRcvConn SQLiteStore {dbConn} q@RcvQueue {server} =
    checkDuplicate $
      DB.withTransaction dbConn $ do
        upsertServer_ dbConn server
        insertRcvQueue_ dbConn q
        insertRcvConnection_ dbConn q

  createSndConn :: SQLiteStore -> SndQueue -> m ()
  createSndConn SQLiteStore {dbConn} q@SndQueue {server} =
    checkDuplicate $
      DB.withTransaction dbConn $ do
        upsertServer_ dbConn server
        insertSndQueue_ dbConn q
        insertSndConnection_ dbConn q

  getConn :: SQLiteStore -> ConnAlias -> m SomeConn
  getConn SQLiteStore {dbConn} connAlias =
    liftIOEither . DB.withTransaction dbConn $
      getConn_ dbConn connAlias

  getAllConnAliases :: SQLiteStore -> m [ConnAlias]
  getAllConnAliases SQLiteStore {dbConn} =
    liftIO $ do
      r <- DB.query_ dbConn "SELECT conn_alias FROM connections;" :: IO [[ConnAlias]]
      return (concat r)

  getRcvConn :: SQLiteStore -> SMPServer -> SMP.RecipientId -> m SomeConn
  getRcvConn SQLiteStore {dbConn} SMPServer {host, port} rcvId =
    liftIOEither . DB.withTransaction dbConn $
      DB.queryNamed
        dbConn
        [sql|
          SELECT q.conn_alias
          FROM rcv_queues q
          WHERE q.host = :host AND q.port = :port AND q.rcv_id = :rcv_id;
        |]
        [":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]
        >>= \case
          [Only connAlias] -> getConn_ dbConn connAlias
          _ -> pure $ Left SEConnNotFound

  deleteConn :: SQLiteStore -> ConnAlias -> m ()
  deleteConn SQLiteStore {dbConn} connAlias =
    liftIO $
      DB.executeNamed
        dbConn
        "DELETE FROM connections WHERE conn_alias = :conn_alias;"
        [":conn_alias" := connAlias]

  upgradeRcvConnToDuplex :: SQLiteStore -> ConnAlias -> SndQueue -> m ()
  upgradeRcvConnToDuplex SQLiteStore {dbConn} connAlias sq@SndQueue {server} =
    liftIOEither . DB.withTransaction dbConn $
      getConn_ dbConn connAlias >>= \case
        Right (SomeConn SCRcv (RcvConnection _ _)) -> do
          upsertServer_ dbConn server
          insertSndQueue_ dbConn sq
          updateConnWithSndQueue_ dbConn connAlias sq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  upgradeSndConnToDuplex :: SQLiteStore -> ConnAlias -> RcvQueue -> m ()
  upgradeSndConnToDuplex SQLiteStore {dbConn} connAlias rq@RcvQueue {server} =
    liftIOEither . DB.withTransaction dbConn $
      getConn_ dbConn connAlias >>= \case
        Right (SomeConn SCSnd (SndConnection _ _)) -> do
          upsertServer_ dbConn server
          insertRcvQueue_ dbConn rq
          updateConnWithRcvQueue_ dbConn connAlias rq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  setRcvQueueStatus :: SQLiteStore -> RcvQueue -> QueueStatus -> m ()
  setRcvQueueStatus SQLiteStore {dbConn} RcvQueue {rcvId, server = SMPServer {host, port}} status =
    -- ? throw error if queue doesn't exist?
    liftIO $
      DB.executeNamed
        dbConn
        [sql|
          UPDATE rcv_queues
          SET status = :status
          WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
        |]
        [":status" := status, ":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]

  setRcvQueueActive :: SQLiteStore -> RcvQueue -> VerificationKey -> m ()
  setRcvQueueActive SQLiteStore {dbConn} RcvQueue {rcvId, server = SMPServer {host, port}} verifyKey =
    -- ? throw error if queue doesn't exist?
    liftIO $
      DB.executeNamed
        dbConn
        [sql|
          UPDATE rcv_queues
          SET verify_key = :verify_key, status = :status
          WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
        |]
        [ ":verify_key" := Just verifyKey,
          ":status" := Active,
          ":host" := host,
          ":port" := serializePort_ port,
          ":rcv_id" := rcvId
        ]

  setSndQueueStatus :: SQLiteStore -> SndQueue -> QueueStatus -> m ()
  setSndQueueStatus SQLiteStore {dbConn} SndQueue {sndId, server = SMPServer {host, port}} status =
    -- ? throw error if queue doesn't exist?
    liftIO $
      DB.executeNamed
        dbConn
        [sql|
          UPDATE snd_queues
          SET status = :status
          WHERE host = :host AND port = :port AND snd_id = :snd_id;
        |]
        [":status" := status, ":host" := host, ":port" := serializePort_ port, ":snd_id" := sndId]

  updateRcvIds :: SQLiteStore -> RcvQueue -> m (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
  updateRcvIds SQLiteStore {dbConn} RcvQueue {connAlias} =
    liftIO . DB.withTransaction dbConn $ do
      (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash) <- retrieveLastIdsAndHashRcv_ dbConn connAlias
      let internalId = InternalId $ unId lastInternalId + 1
          internalRcvId = InternalRcvId $ unRcvId lastInternalRcvId + 1
      updateLastIdsRcv_ dbConn connAlias internalId internalRcvId
      pure (internalId, internalRcvId, lastExternalSndId, lastRcvHash)

  createRcvMsg :: SQLiteStore -> RcvQueue -> RcvMsgData -> m ()
  createRcvMsg SQLiteStore {dbConn} RcvQueue {connAlias} rcvMsgData =
    liftIO . DB.withTransaction dbConn $ do
      insertRcvMsgBase_ dbConn connAlias rcvMsgData
      insertRcvMsgDetails_ dbConn connAlias rcvMsgData
      updateHashRcv_ dbConn connAlias rcvMsgData

  updateSndIds :: SQLiteStore -> SndQueue -> m (InternalId, InternalSndId, PrevSndMsgHash)
  updateSndIds SQLiteStore {dbConn} SndQueue {connAlias} =
    liftIO . DB.withTransaction dbConn $ do
      (lastInternalId, lastInternalSndId, prevSndHash) <- retrieveLastIdsAndHashSnd_ dbConn connAlias
      let internalId = InternalId $ unId lastInternalId + 1
          internalSndId = InternalSndId $ unSndId lastInternalSndId + 1
      updateLastIdsSnd_ dbConn connAlias internalId internalSndId
      pure (internalId, internalSndId, prevSndHash)

  createSndMsg :: SQLiteStore -> SndQueue -> SndMsgData -> m ()
  createSndMsg SQLiteStore {dbConn} SndQueue {connAlias} sndMsgData =
    liftIO . DB.withTransaction dbConn $ do
      insertSndMsgBase_ dbConn connAlias sndMsgData
      insertSndMsgDetails_ dbConn connAlias sndMsgData
      updateHashSnd_ dbConn connAlias sndMsgData

  getMsg :: SQLiteStore -> ConnAlias -> InternalId -> m Msg
  getMsg _st _connAlias _id = throwError SENotImplemented

-- * Auxiliary helpers

-- ? replace with ToField? - it's easy to forget to use this
serializePort_ :: Maybe ServiceName -> ServiceName
serializePort_ = fromMaybe "_"

deserializePort_ :: ServiceName -> Maybe ServiceName
deserializePort_ "_" = Nothing
deserializePort_ port = Just port

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromFieldToReadable_

instance ToField InternalRcvId where toField (InternalRcvId x) = toField x

instance FromField InternalRcvId where fromField x = InternalRcvId <$> fromField x

instance ToField InternalSndId where toField (InternalSndId x) = toField x

instance FromField InternalSndId where fromField x = InternalSndId <$> fromField x

instance ToField InternalId where toField (InternalId x) = toField x

instance FromField InternalId where fromField x = InternalId <$> fromField x

instance ToField RcvMsgStatus where toField = toField . show

instance ToField SndMsgStatus where toField = toField . show

instance ToField MsgIntegrity where toField = toField . serializeMsgIntegrity

instance FromField MsgIntegrity where fromField = blobFieldParser msgIntegrityP

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

insertRcvQueue_ :: DB.Connection -> RcvQueue -> IO ()
insertRcvQueue_ dbConn RcvQueue {..} = do
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

insertRcvConnection_ :: DB.Connection -> RcvQueue -> IO ()
insertRcvConnection_ dbConn RcvQueue {server, rcvId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id,
          last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id,
          last_external_snd_msg_id, last_rcv_msg_hash, last_snd_msg_hash)
      VALUES
        (:conn_alias,:rcv_host,:rcv_port,:rcv_id,     NULL,     NULL,   NULL,
          0, 0, 0, 0, x'', x'');
    |]
    [":conn_alias" := connAlias, ":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId]

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> SndQueue -> IO ()
insertSndQueue_ dbConn SndQueue {..} = do
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

insertSndConnection_ :: DB.Connection -> SndQueue -> IO ()
insertSndConnection_ dbConn SndQueue {server, sndId, connAlias} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id,
          last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id,
          last_external_snd_msg_id, last_rcv_msg_hash, last_snd_msg_hash)
      VALUES
        (:conn_alias,     NULL,     NULL,   NULL,:snd_host,:snd_port,:snd_id,
          0, 0, 0, 0, x'', x'');
    |]
    [":conn_alias" := connAlias, ":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId]

-- * getConn helpers

getConn_ :: DB.Connection -> ConnAlias -> IO (Either StoreError SomeConn)
getConn_ dbConn connAlias = do
  rQ <- retrieveRcvQueueByConnAlias_ dbConn connAlias
  sQ <- retrieveSndQueueByConnAlias_ dbConn connAlias
  pure $ case (rQ, sQ) of
    (Just rcvQ, Just sndQ) -> Right $ SomeConn SCDuplex (DuplexConnection connAlias rcvQ sndQ)
    (Just rcvQ, Nothing) -> Right $ SomeConn SCRcv (RcvConnection connAlias rcvQ)
    (Nothing, Just sndQ) -> Right $ SomeConn SCSnd (SndConnection connAlias sndQ)
    _ -> Left SEConnNotFound

retrieveRcvQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe RcvQueue)
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
      return . Just $ RcvQueue srv rcvId cAlias rcvPrivateKey sndId sndKey decryptKey verifyKey status
    _ -> return Nothing

retrieveSndQueueByConnAlias_ :: DB.Connection -> ConnAlias -> IO (Maybe SndQueue)
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
      return . Just $ SndQueue srv sndId cAlias sndPrivateKey encryptKey signKey status
    _ -> return Nothing

-- * upgradeRcvConnToDuplex helpers

updateConnWithSndQueue_ :: DB.Connection -> ConnAlias -> SndQueue -> IO ()
updateConnWithSndQueue_ dbConn connAlias SndQueue {server, sndId} = do
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

updateConnWithRcvQueue_ :: DB.Connection -> ConnAlias -> RcvQueue -> IO ()
updateConnWithRcvQueue_ dbConn connAlias RcvQueue {server, rcvId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET rcv_host = :rcv_host, rcv_port = :rcv_port, rcv_id = :rcv_id
      WHERE conn_alias = :conn_alias;
    |]
    [":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId, ":conn_alias" := connAlias]

-- * updateRcvIds helpers

retrieveLastIdsAndHashRcv_ :: DB.Connection -> ConnAlias -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
retrieveLastIdsAndHashRcv_ dbConn connAlias = do
  [(lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  return (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)

updateLastIdsRcv_ :: DB.Connection -> ConnAlias -> InternalId -> InternalRcvId -> IO ()
updateLastIdsRcv_ dbConn connAlias newInternalId newInternalRcvId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_rcv_msg_id = :last_internal_rcv_msg_id
      WHERE conn_alias = :conn_alias;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_rcv_msg_id" := newInternalRcvId,
      ":conn_alias" := connAlias
    ]

-- * createRcvMsg helpers

insertRcvMsgBase_ :: DB.Connection -> ConnAlias -> RcvMsgData -> IO ()
insertRcvMsgBase_ dbConn connAlias RcvMsgData {..} = do
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

insertRcvMsgDetails_ :: DB.Connection -> ConnAlias -> RcvMsgData -> IO ()
insertRcvMsgDetails_ dbConn connAlias RcvMsgData {..} =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_messages
        ( conn_alias, internal_rcv_id, internal_id, external_snd_id, external_snd_ts,
          broker_id, broker_ts, rcv_status, ack_brocker_ts, ack_sender_ts,
          internal_hash, external_prev_snd_hash, integrity)
      VALUES
        (:conn_alias,:internal_rcv_id,:internal_id,:external_snd_id,:external_snd_ts,
         :broker_id,:broker_ts,:rcv_status,           NULL,          NULL,
         :internal_hash,:external_prev_snd_hash,:integrity);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_rcv_id" := internalRcvId,
      ":internal_id" := internalId,
      ":external_snd_id" := fst senderMeta,
      ":external_snd_ts" := snd senderMeta,
      ":broker_id" := fst brokerMeta,
      ":broker_ts" := snd brokerMeta,
      ":rcv_status" := Received,
      ":internal_hash" := internalHash,
      ":external_prev_snd_hash" := externalPrevSndHash,
      ":integrity" := msgIntegrity
    ]

updateHashRcv_ :: DB.Connection -> ConnAlias -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connAlias RcvMsgData {..} =
  DB.executeNamed
    dbConn
    -- last_internal_rcv_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_external_snd_msg_id = :last_external_snd_msg_id,
          last_rcv_msg_hash = :last_rcv_msg_hash
      WHERE conn_alias = :conn_alias
        AND last_internal_rcv_msg_id = :last_internal_rcv_msg_id;
    |]
    [ ":last_external_snd_msg_id" := fst senderMeta,
      ":last_rcv_msg_hash" := internalHash,
      ":conn_alias" := connAlias,
      ":last_internal_rcv_msg_id" := internalRcvId
    ]

-- * updateSndIds helpers

retrieveLastIdsAndHashSnd_ :: DB.Connection -> ConnAlias -> IO (InternalId, InternalSndId, PrevSndMsgHash)
retrieveLastIdsAndHashSnd_ dbConn connAlias = do
  [(lastInternalId, lastInternalSndId, lastSndHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_snd_msg_id, last_snd_msg_hash
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connAlias]
  return (lastInternalId, lastInternalSndId, lastSndHash)

updateLastIdsSnd_ :: DB.Connection -> ConnAlias -> InternalId -> InternalSndId -> IO ()
updateLastIdsSnd_ dbConn connAlias newInternalId newInternalSndId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_snd_msg_id = :last_internal_snd_msg_id
      WHERE conn_alias = :conn_alias;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_snd_msg_id" := newInternalSndId,
      ":conn_alias" := connAlias
    ]

-- * createSndMsg helpers

insertSndMsgBase_ :: DB.Connection -> ConnAlias -> SndMsgData -> IO ()
insertSndMsgBase_ dbConn connAlias SndMsgData {..} = do
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

insertSndMsgDetails_ :: DB.Connection -> ConnAlias -> SndMsgData -> IO ()
insertSndMsgDetails_ dbConn connAlias SndMsgData {..} =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_alias, internal_snd_id, internal_id, snd_status, sent_ts, delivered_ts, internal_hash)
      VALUES
        (:conn_alias,:internal_snd_id,:internal_id,:snd_status,    NULL,         NULL,:internal_hash);
    |]
    [ ":conn_alias" := connAlias,
      ":internal_snd_id" := internalSndId,
      ":internal_id" := internalId,
      ":snd_status" := Created,
      ":internal_hash" := internalHash
    ]

updateHashSnd_ :: DB.Connection -> ConnAlias -> SndMsgData -> IO ()
updateHashSnd_ dbConn connAlias SndMsgData {..} =
  DB.executeNamed
    dbConn
    -- last_internal_snd_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_snd_msg_hash = :last_snd_msg_hash
      WHERE conn_alias = :conn_alias
        AND last_internal_snd_msg_id = :last_internal_snd_msg_id;
    |]
    [ ":last_snd_msg_hash" := internalHash,
      ":conn_alias" := connAlias,
      ":last_internal_snd_msg_id" := internalSndId
    ]
