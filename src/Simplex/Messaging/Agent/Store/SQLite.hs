{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( SQLiteStore (..),
    createSQLiteStore,
    connectSQLiteStore,
    withConnection,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (join, replicateM_, unless, when)
import Control.Monad.Except (MonadError (throwError), MonadIO (liftIO))
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 (encode)
import Data.Char (toLower)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
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
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Migrations (Migration)
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Parsers (blobFieldParser)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (bshow, liftIOEither)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import Text.Read (readMaybe)
import qualified UnliftIO.Exception as E

-- * SQLite Store implementation

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbConnPool :: TBQueue DB.Connection,
    dbNew :: Bool
  }

createSQLiteStore :: FilePath -> Int -> [Migration] -> IO SQLiteStore
createSQLiteStore dbFilePath poolSize migrations = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing False dbDir
  st <- connectSQLiteStore dbFilePath poolSize
  checkThreadsafe st
  migrateSchema st migrations
  pure st

checkThreadsafe :: SQLiteStore -> IO ()
checkThreadsafe st = withConnection st $ \db -> do
  compileOptions <- DB.query_ db "pragma COMPILE_OPTIONS;" :: IO [[Text]]
  let threadsafeOption = find (T.isPrefixOf "THREADSAFE=") (concat compileOptions)
  case threadsafeOption of
    Just "THREADSAFE=0" -> confirmOrExit "SQLite compiled with non-threadsafe code."
    Nothing -> putStrLn "Warning: SQLite THREADSAFE compile option not found"
    _ -> return ()

migrateSchema :: SQLiteStore -> [Migration] -> IO ()
migrateSchema st migrations = withConnection st $ \db -> do
  Migrations.initialize db
  Migrations.get db migrations >>= \case
    Left e -> confirmOrExit $ "Database error: " <> e
    Right [] -> pure ()
    Right ms -> do
      unless (dbNew st) $ do
        confirmOrExit "The app has a newer version than the database - it will be backed up and upgraded."
        let f = dbFilePath st
        copyFile f (f <> ".bak")
      Migrations.run db ms

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

connectSQLiteStore :: FilePath -> Int -> IO SQLiteStore
connectSQLiteStore dbFilePath poolSize = do
  dbNew <- not <$> doesFileExist dbFilePath
  dbConnPool <- newTBQueueIO $ toEnum poolSize
  replicateM_ poolSize $
    connectDB dbFilePath >>= atomically . writeTBQueue dbConnPool
  pure SQLiteStore {dbFilePath, dbConnPool, dbNew}

connectDB :: FilePath -> IO DB.Connection
connectDB path = do
  dbConn <- DB.open path
  DB.execute_ dbConn "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;"
  pure dbConn

checkConstraint :: StoreError -> IO (Either StoreError a) -> IO (Either StoreError a)
checkConstraint err action = action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SQLError -> StoreError
handleSQLError err e
  | DB.sqlError e == DB.ErrorConstraint = err
  | otherwise = SEInternal $ bshow e

withConnection :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withConnection SQLiteStore {dbConnPool} =
  bracket
    (atomically $ readTBQueue dbConnPool)
    (atomically . writeTBQueue dbConnPool)

withTransaction :: forall a. SQLiteStore -> (DB.Connection -> IO a) -> IO a
withTransaction st action = withConnection st $ loop 100 100_000
  where
    loop :: Int -> Int -> DB.Connection -> IO a
    loop t tLim db =
      DB.withImmediateTransaction db (action db) `E.catch` \(e :: SQLError) ->
        if tLim > t && DB.sqlError e == DB.ErrorBusy
          then do
            threadDelay t
            loop (t * 9 `div` 8) (tLim - t) db
          else E.throwIO e

instance (MonadUnliftIO m, MonadError StoreError m) => MonadAgentStore SQLiteStore m where
  createRcvConn :: SQLiteStore -> TVar ChaChaDRG -> ConnData -> RcvQueue -> m ConnId
  createRcvConn st gVar cData q@RcvQueue {server} =
    -- TODO if schema has to be restarted, this function can be refactored
    -- to create connection first using createWithRandomId
    liftIOEither . checkConstraint SEConnDuplicate . withTransaction st $ \db ->
      getConnId_ db gVar cData >>= traverse (create db)
    where
      create :: DB.Connection -> ConnId -> IO ConnId
      create db connId = do
        upsertServer_ db server
        insertRcvQueue_ db connId q
        insertRcvConnection_ db cData {connId} q
        pure connId

  createSndConn :: SQLiteStore -> TVar ChaChaDRG -> ConnData -> SndQueue -> m ConnId
  createSndConn st gVar cData q@SndQueue {server} =
    -- TODO if schema has to be restarted, this function can be refactored
    -- to create connection first using createWithRandomId
    liftIOEither . checkConstraint SEConnDuplicate . withTransaction st $ \db ->
      getConnId_ db gVar cData >>= traverse (create db)
    where
      create :: DB.Connection -> ConnId -> IO ConnId
      create db connId = do
        upsertServer_ db server
        insertSndQueue_ db connId q
        insertSndConnection_ db cData {connId} q
        pure connId

  getConn :: SQLiteStore -> ConnId -> m SomeConn
  getConn st connId =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId

  getAllConnIds :: SQLiteStore -> m [ConnId]
  getAllConnIds st =
    liftIO . withConnection st $ \db ->
      concat <$> (DB.query_ db "SELECT conn_alias FROM connections;" :: IO [[ConnId]])

  getRcvConn :: SQLiteStore -> SMPServer -> SMP.RecipientId -> m SomeConn
  getRcvConn st SMPServer {host, port} rcvId =
    liftIOEither . withTransaction st $ \db ->
      DB.queryNamed
        db
        [sql|
          SELECT q.conn_alias
          FROM rcv_queues q
          WHERE q.host = :host AND q.port = :port AND q.rcv_id = :rcv_id;
        |]
        [":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]
        >>= \case
          [Only connId] -> getConn_ db connId
          _ -> pure $ Left SEConnNotFound

  deleteConn :: SQLiteStore -> ConnId -> m ()
  deleteConn st connId =
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        "DELETE FROM connections WHERE conn_alias = :conn_alias;"
        [":conn_alias" := connId]

  upgradeRcvConnToDuplex :: SQLiteStore -> ConnId -> SndQueue -> m ()
  upgradeRcvConnToDuplex st connId sq@SndQueue {server} =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId >>= \case
        Right (SomeConn _ RcvConnection {}) -> do
          upsertServer_ db server
          insertSndQueue_ db connId sq
          updateConnWithSndQueue_ db connId sq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  upgradeSndConnToDuplex :: SQLiteStore -> ConnId -> RcvQueue -> m ()
  upgradeSndConnToDuplex st connId rq@RcvQueue {server} =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId >>= \case
        Right (SomeConn _ SndConnection {}) -> do
          upsertServer_ db server
          insertRcvQueue_ db connId rq
          updateConnWithRcvQueue_ db connId rq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  setRcvQueueStatus :: SQLiteStore -> RcvQueue -> QueueStatus -> m ()
  setRcvQueueStatus st RcvQueue {rcvId, server = SMPServer {host, port}} status =
    -- ? throw error if queue does not exist?
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          UPDATE rcv_queues
          SET status = :status
          WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
        |]
        [":status" := status, ":host" := host, ":port" := serializePort_ port, ":rcv_id" := rcvId]

  setRcvQueueActive :: SQLiteStore -> RcvQueue -> VerificationKey -> m ()
  setRcvQueueActive st RcvQueue {rcvId, server = SMPServer {host, port}} verifyKey =
    -- ? throw error if queue does not exist?
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
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
  setSndQueueStatus st SndQueue {sndId, server = SMPServer {host, port}} status =
    -- ? throw error if queue does not exist?
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          UPDATE snd_queues
          SET status = :status
          WHERE host = :host AND port = :port AND snd_id = :snd_id;
        |]
        [":status" := status, ":host" := host, ":port" := serializePort_ port, ":snd_id" := sndId]

  createConfirmation :: SQLiteStore -> TVar ChaChaDRG -> NewConfirmation -> m ConfirmationId
  createConfirmation st gVar NewConfirmation {connId, senderKey, senderConnInfo} =
    liftIOEither . withConnection st $ \db ->
      createWithRandomId gVar $ \confirmationId ->
        DB.execute
          db
          [sql|
            INSERT INTO conn_confirmations
            (confirmation_id, conn_alias, sender_key, sender_conn_info, approved) VALUES (?, ?, ?, ?, 0);
          |]
          (confirmationId, connId, senderKey, senderConnInfo)

  getConfirmation :: SQLiteStore -> ConfirmationId -> m Confirmation
  getConfirmation st confirmationId =
    liftIOEither . withConnection st $ \db ->
      confirmation
        <$> DB.query
          db
          [sql|
            SELECT conn_alias, sender_key, sender_conn_info, own_conn_info
            FROM conn_confirmations
            WHERE confirmation_id = ?;
          |]
          (Only confirmationId)
    where
      confirmation [(connId, senderKey, senderConnInfo, ownConnInfo)] =
        Right $ Confirmation {confirmationId, connId, senderKey, senderConnInfo, ownConnInfo}
      confirmation _ = Left SEConfirmationNotFound

  approveConfirmation :: SQLiteStore -> ConfirmationId -> ConnInfo -> m ()
  approveConfirmation st confirmationId ownConnInfo =
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          UPDATE conn_confirmations
          SET approved = 1,
              own_conn_info = :own_conn_info
          WHERE confirmation_id = :confirmation_id;
        |]
        [ ":own_conn_info" := ownConnInfo,
          ":confirmation_id" := confirmationId
        ]

  getApprovedConfirmation :: SQLiteStore -> ConnId -> m Confirmation
  getApprovedConfirmation st connId =
    liftIOEither . withConnection st $ \db ->
      confirmation
        <$> DB.query
          db
          [sql|
            SELECT confirmation_id, sender_key, sender_conn_info, own_conn_info
            FROM conn_confirmations
            WHERE conn_alias = ? AND approved = 1;
          |]
          (Only connId)
    where
      confirmation [(confirmationId, senderKey, senderConnInfo, ownConnInfo)] =
        Right $ Confirmation {confirmationId, connId, senderKey, senderConnInfo, ownConnInfo}
      confirmation _ = Left SEConfirmationNotFound

  removeApprovedConfirmation :: SQLiteStore -> ConnId -> m ()
  removeApprovedConfirmation st connId =
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          DELETE FROM conn_confirmations
          WHERE conn_alias = :conn_alias AND approved = 1;
        |]
        [":conn_alias" := connId]

  updateRcvIds :: SQLiteStore -> ConnId -> m (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
  updateRcvIds st connId =
    liftIO . withTransaction st $ \db -> do
      (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash) <- retrieveLastIdsAndHashRcv_ db connId
      let internalId = InternalId $ unId lastInternalId + 1
          internalRcvId = InternalRcvId $ unRcvId lastInternalRcvId + 1
      updateLastIdsRcv_ db connId internalId internalRcvId
      pure (internalId, internalRcvId, lastExternalSndId, lastRcvHash)

  createRcvMsg :: SQLiteStore -> ConnId -> RcvMsgData -> m ()
  createRcvMsg st connId rcvMsgData =
    liftIO . withTransaction st $ \db -> do
      insertRcvMsgBase_ db connId rcvMsgData
      insertRcvMsgDetails_ db connId rcvMsgData
      updateHashRcv_ db connId rcvMsgData

  updateSndIds :: SQLiteStore -> ConnId -> m (InternalId, InternalSndId, PrevSndMsgHash)
  updateSndIds st connId =
    liftIO . withTransaction st $ \db -> do
      (lastInternalId, lastInternalSndId, prevSndHash) <- retrieveLastIdsAndHashSnd_ db connId
      let internalId = InternalId $ unId lastInternalId + 1
          internalSndId = InternalSndId $ unSndId lastInternalSndId + 1
      updateLastIdsSnd_ db connId internalId internalSndId
      pure (internalId, internalSndId, prevSndHash)

  createSndMsg :: SQLiteStore -> ConnId -> SndMsgData -> m ()
  createSndMsg st connId sndMsgData =
    liftIO . withTransaction st $ \db -> do
      insertSndMsgBase_ db connId sndMsgData
      insertSndMsgDetails_ db connId sndMsgData
      updateHashSnd_ db connId sndMsgData

  getMsg :: SQLiteStore -> ConnId -> InternalId -> m Msg
  getMsg _st _connAlias _id = throwError SENotImplemented

  createIntro :: SQLiteStore -> TVar ChaChaDRG -> NewIntroduction -> m IntroId
  createIntro st gVar NewIntroduction {toConn, reConn, reInfo} =
    liftIOEither . withConnection st $ \db ->
      createWithRandomId gVar $ \introId ->
        DB.execute
          db
          [sql|
            INSERT INTO conn_intros
            (intro_id, to_conn, re_conn, re_info) VALUES (?, ?, ?, ?);
          |]
          (introId, toConn, reConn, reInfo)

  getIntro :: SQLiteStore -> IntroId -> m Introduction
  getIntro st introId =
    liftIOEither . withConnection st $ \db ->
      intro
        <$> DB.query
          db
          [sql|
            SELECT to_conn, to_info, to_status, re_conn, re_info, re_status, queue_info
            FROM conn_intros
            WHERE intro_id = ?;
          |]
          (Only introId)
    where
      intro [(toConn, toInfo, toStatus, reConn, reInfo, reStatus, qInfo)] =
        Right $ Introduction {introId, toConn, toInfo, toStatus, reConn, reInfo, reStatus, qInfo}
      intro _ = Left SEIntroNotFound

  addIntroInvitation :: SQLiteStore -> IntroId -> ConnInfo -> SMPQueueInfo -> m ()
  addIntroInvitation st introId toInfo qInfo =
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          UPDATE conn_intros
          SET to_info = :to_info,
              queue_info = :queue_info,
              to_status = :to_status
          WHERE intro_id = :intro_id;
        |]
        [ ":to_info" := toInfo,
          ":queue_info" := Just qInfo,
          ":to_status" := IntroInv,
          ":intro_id" := introId
        ]

  setIntroToStatus :: SQLiteStore -> IntroId -> IntroStatus -> m ()
  setIntroToStatus st introId toStatus =
    liftIO . withConnection st $ \db ->
      DB.execute
        db
        [sql|
          UPDATE conn_intros
          SET to_status = ?
          WHERE intro_id = ?;
        |]
        (toStatus, introId)

  setIntroReStatus :: SQLiteStore -> IntroId -> IntroStatus -> m ()
  setIntroReStatus st introId reStatus =
    liftIO . withConnection st $ \db ->
      DB.execute
        db
        [sql|
          UPDATE conn_intros
          SET re_status = ?
          WHERE intro_id = ?;
        |]
        (reStatus, introId)

  createInvitation :: SQLiteStore -> TVar ChaChaDRG -> NewInvitation -> m InvitationId
  createInvitation st gVar NewInvitation {viaConn, externalIntroId, connInfo, qInfo} =
    liftIOEither . withConnection st $ \db ->
      createWithRandomId gVar $ \invId ->
        DB.execute
          db
          [sql|
            INSERT INTO conn_invitations
            (inv_id, via_conn, external_intro_id, conn_info, queue_info) VALUES (?, ?, ?, ?, ?);
          |]
          (invId, viaConn, externalIntroId, connInfo, qInfo)

  getInvitation :: SQLiteStore -> InvitationId -> m Invitation
  getInvitation st invId =
    liftIOEither . withConnection st $ \db ->
      invitation
        <$> DB.query
          db
          [sql|
            SELECT via_conn, external_intro_id, conn_info, queue_info, conn_id, status
            FROM conn_invitations
            WHERE inv_id = ?;
          |]
          (Only invId)
    where
      invitation [(viaConn, externalIntroId, connInfo, qInfo, connId, status)] =
        Right $ Invitation {invId, viaConn, externalIntroId, connInfo, qInfo, connId, status}
      invitation _ = Left SEInvitationNotFound

  addInvitationConn :: SQLiteStore -> InvitationId -> ConnId -> m ()
  addInvitationConn st invId connId =
    liftIO . withConnection st $ \db ->
      DB.executeNamed
        db
        [sql|
          UPDATE conn_invitations
          SET conn_id = :conn_id, status = :status
          WHERE inv_id = :inv_id;
        |]
        [":conn_id" := connId, ":status" := InvAcpt, ":inv_id" := invId]

  getConnInvitation :: SQLiteStore -> ConnId -> m (Maybe (Invitation, Connection 'CDuplex))
  getConnInvitation st cId =
    liftIO . withTransaction st $ \db ->
      DB.query
        db
        [sql|
          SELECT inv_id, via_conn, external_intro_id, conn_info, queue_info, status
          FROM conn_invitations
          WHERE conn_id = ?;
        |]
        (Only cId)
        >>= fmap join . traverse (getViaConn db) . invitation
    where
      invitation [(invId, viaConn, externalIntroId, connInfo, qInfo, status)] =
        Just $ Invitation {invId, viaConn, externalIntroId, connInfo, qInfo, connId = Just cId, status}
      invitation _ = Nothing
      getViaConn :: DB.Connection -> Invitation -> IO (Maybe (Invitation, Connection 'CDuplex))
      getViaConn db inv@Invitation {viaConn} = fmap (inv,) . duplexConn <$> getConn_ db viaConn
      duplexConn :: Either StoreError SomeConn -> Maybe (Connection 'CDuplex)
      duplexConn (Right (SomeConn SCDuplex conn)) = Just conn
      duplexConn _ = Nothing

  setInvitationStatus :: SQLiteStore -> InvitationId -> InvitationStatus -> m ()
  setInvitationStatus st invId status =
    liftIO . withConnection st $ \db ->
      DB.execute
        db
        [sql|
          UPDATE conn_invitations
          SET status = ? WHERE inv_id = ?;
        |]
        (status, invId)

-- * Auxiliary helpers

-- ? replace with ToField? - it's easy to forget to use this
serializePort_ :: Maybe ServiceName -> ServiceName
serializePort_ = fromMaybe "_"

deserializePort_ :: ServiceName -> Maybe ServiceName
deserializePort_ "_" = Nothing
deserializePort_ port = Just port

instance ToField QueueStatus where toField = toField . show

instance FromField QueueStatus where fromField = fromTextField_ $ readMaybe . T.unpack

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

instance ToField IntroStatus where toField = toField . serializeIntroStatus

instance FromField IntroStatus where fromField = fromTextField_ introStatusT

instance ToField InvitationStatus where toField = toField . serializeInvStatus

instance FromField InvitationStatus where fromField = fromTextField_ invStatusT

instance ToField SMPQueueInfo where toField = toField . serializeSmpQueueInfo

instance FromField SMPQueueInfo where fromField = blobFieldParser smpQueueInfoP

fromTextField_ :: (E.Typeable a) => (Text -> Maybe a) -> Field -> Ok a
fromTextField_ fromText = \case
  f@(Field (SQLText t) _) ->
    case fromText t of
      Just x -> Ok x
      _ -> returnError ConversionFailed f ("invalid text: " <> T.unpack t)
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

insertRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO ()
insertRcvQueue_ dbConn connId RcvQueue {..} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_queues
        ( host, port, rcv_id, conn_alias, rcv_private_key, snd_id, decrypt_key, verify_key, status)
      VALUES
        (:host,:port,:rcv_id,:conn_alias,:rcv_private_key,:snd_id,:decrypt_key,:verify_key,:status);
    |]
    [ ":host" := host server,
      ":port" := port_,
      ":rcv_id" := rcvId,
      ":conn_alias" := connId,
      ":rcv_private_key" := rcvPrivateKey,
      ":snd_id" := sndId,
      ":decrypt_key" := decryptKey,
      ":verify_key" := verifyKey,
      ":status" := status
    ]

insertRcvConnection_ :: DB.Connection -> ConnData -> RcvQueue -> IO ()
insertRcvConnection_ dbConn ConnData {connId, viaInv, connLevel} RcvQueue {server, rcvId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id, via_inv, conn_level, last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id, last_external_snd_msg_id, last_rcv_msg_hash, last_snd_msg_hash)
      VALUES
        (:conn_alias,:rcv_host,:rcv_port,:rcv_id, NULL,     NULL,     NULL,  :via_inv,:conn_level, 0, 0, 0, 0, x'', x'');
    |]
    [ ":conn_alias" := connId,
      ":rcv_host" := host server,
      ":rcv_port" := port_,
      ":rcv_id" := rcvId,
      ":via_inv" := viaInv,
      ":conn_level" := connLevel
    ]

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO ()
insertSndQueue_ dbConn connId SndQueue {..} = do
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
      ":conn_alias" := connId,
      ":snd_private_key" := sndPrivateKey,
      ":encrypt_key" := encryptKey,
      ":sign_key" := signKey,
      ":status" := status
    ]

insertSndConnection_ :: DB.Connection -> ConnData -> SndQueue -> IO ()
insertSndConnection_ dbConn ConnData {connId, viaInv, connLevel} SndQueue {server, sndId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO connections
        ( conn_alias, rcv_host, rcv_port, rcv_id, snd_host, snd_port, snd_id, via_inv, conn_level, last_internal_msg_id, last_internal_rcv_msg_id, last_internal_snd_msg_id, last_external_snd_msg_id, last_rcv_msg_hash, last_snd_msg_hash)
      VALUES
        (:conn_alias, NULL,     NULL,     NULL,  :snd_host,:snd_port,:snd_id,:via_inv,:conn_level, 0, 0, 0, 0, x'', x'');
    |]
    [ ":conn_alias" := connId,
      ":snd_host" := host server,
      ":snd_port" := port_,
      ":snd_id" := sndId,
      ":via_inv" := viaInv,
      ":conn_level" := connLevel
    ]

-- * getConn helpers

getConn_ :: DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getConn_ dbConn connId =
  getConnData_ dbConn connId >>= \case
    Nothing -> pure $ Left SEConnNotFound
    Just connData -> do
      rQ <- getRcvQueueByConnAlias_ dbConn connId
      sQ <- getSndQueueByConnAlias_ dbConn connId
      pure $ case (rQ, sQ) of
        (Just rcvQ, Just sndQ) -> Right $ SomeConn SCDuplex (DuplexConnection connData rcvQ sndQ)
        (Just rcvQ, Nothing) -> Right $ SomeConn SCRcv (RcvConnection connData rcvQ)
        (Nothing, Just sndQ) -> Right $ SomeConn SCSnd (SndConnection connData sndQ)
        _ -> Left SEConnNotFound

getConnData_ :: DB.Connection -> ConnId -> IO (Maybe ConnData)
getConnData_ dbConn connId =
  connData
    <$> DB.query dbConn "SELECT via_inv, conn_level FROM connections WHERE conn_alias = ?;" (Only connId)
  where
    connData [(viaInv, connLevel)] = Just ConnData {connId, viaInv, connLevel}
    connData _ = Nothing

getRcvQueueByConnAlias_ :: DB.Connection -> ConnId -> IO (Maybe RcvQueue)
getRcvQueueByConnAlias_ dbConn connId =
  rcvQueue
    <$> DB.query
      dbConn
      [sql|
        SELECT s.key_hash, q.host, q.port, q.rcv_id, q.rcv_private_key,
          q.snd_id, q.decrypt_key, q.verify_key, q.status
        FROM rcv_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_alias = ?;
      |]
      (Only connId)
  where
    rcvQueue [(keyHash, host, port, rcvId, rcvPrivateKey, sndId, decryptKey, verifyKey, status)] =
      let srv = SMPServer host (deserializePort_ port) keyHash
       in Just $ RcvQueue srv rcvId rcvPrivateKey sndId decryptKey verifyKey status
    rcvQueue _ = Nothing

getSndQueueByConnAlias_ :: DB.Connection -> ConnId -> IO (Maybe SndQueue)
getSndQueueByConnAlias_ dbConn connId =
  sndQueue
    <$> DB.query
      dbConn
      [sql|
        SELECT s.key_hash, q.host, q.port, q.snd_id, q.snd_private_key, q.encrypt_key, q.sign_key, q.status
        FROM snd_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_alias = ?;
      |]
      (Only connId)
  where
    sndQueue [(keyHash, host, port, sndId, sndPrivateKey, encryptKey, signKey, status)] =
      let srv = SMPServer host (deserializePort_ port) keyHash
       in Just $ SndQueue srv sndId sndPrivateKey encryptKey signKey status
    sndQueue _ = Nothing

-- * upgradeRcvConnToDuplex helpers

updateConnWithSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO ()
updateConnWithSndQueue_ dbConn connId SndQueue {server, sndId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET snd_host = :snd_host, snd_port = :snd_port, snd_id = :snd_id
      WHERE conn_alias = :conn_alias;
    |]
    [":snd_host" := host server, ":snd_port" := port_, ":snd_id" := sndId, ":conn_alias" := connId]

-- * upgradeSndConnToDuplex helpers

updateConnWithRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO ()
updateConnWithRcvQueue_ dbConn connId RcvQueue {server, rcvId} = do
  let port_ = serializePort_ $ port server
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET rcv_host = :rcv_host, rcv_port = :rcv_port, rcv_id = :rcv_id
      WHERE conn_alias = :conn_alias;
    |]
    [":rcv_host" := host server, ":rcv_port" := port_, ":rcv_id" := rcvId, ":conn_alias" := connId]

-- * updateRcvIds helpers

retrieveLastIdsAndHashRcv_ :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
retrieveLastIdsAndHashRcv_ dbConn connId = do
  [(lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connId]
  return (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)

updateLastIdsRcv_ :: DB.Connection -> ConnId -> InternalId -> InternalRcvId -> IO ()
updateLastIdsRcv_ dbConn connId newInternalId newInternalRcvId =
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
      ":conn_alias" := connId
    ]

-- * createRcvMsg helpers

insertRcvMsgBase_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgBase_ dbConn connId RcvMsgData {..} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_alias, internal_id, internal_ts, internal_rcv_id, internal_snd_id, body)
      VALUES
        (:conn_alias,:internal_id,:internal_ts,:internal_rcv_id,            NULL,:body);
    |]
    [ ":conn_alias" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_rcv_id" := internalRcvId,
      ":body" := decodeUtf8 msgBody
    ]

insertRcvMsgDetails_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgDetails_ dbConn connId RcvMsgData {..} =
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
    [ ":conn_alias" := connId,
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

updateHashRcv_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connId RcvMsgData {..} =
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
      ":conn_alias" := connId,
      ":last_internal_rcv_msg_id" := internalRcvId
    ]

-- * updateSndIds helpers

retrieveLastIdsAndHashSnd_ :: DB.Connection -> ConnId -> IO (InternalId, InternalSndId, PrevSndMsgHash)
retrieveLastIdsAndHashSnd_ dbConn connId = do
  [(lastInternalId, lastInternalSndId, lastSndHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_snd_msg_id, last_snd_msg_hash
        FROM connections
        WHERE conn_alias = :conn_alias;
      |]
      [":conn_alias" := connId]
  return (lastInternalId, lastInternalSndId, lastSndHash)

updateLastIdsSnd_ :: DB.Connection -> ConnId -> InternalId -> InternalSndId -> IO ()
updateLastIdsSnd_ dbConn connId newInternalId newInternalSndId =
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
      ":conn_alias" := connId
    ]

-- * createSndMsg helpers

insertSndMsgBase_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgBase_ dbConn connId SndMsgData {..} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_alias, internal_id, internal_ts, internal_rcv_id, internal_snd_id, body)
      VALUES
        (:conn_alias,:internal_id,:internal_ts,            NULL,:internal_snd_id,:body);
    |]
    [ ":conn_alias" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_snd_id" := internalSndId,
      ":body" := decodeUtf8 msgBody
    ]

insertSndMsgDetails_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgDetails_ dbConn connId SndMsgData {..} =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_alias, internal_snd_id, internal_id, snd_status, sent_ts, delivered_ts, internal_hash)
      VALUES
        (:conn_alias,:internal_snd_id,:internal_id,:snd_status,    NULL,         NULL,:internal_hash);
    |]
    [ ":conn_alias" := connId,
      ":internal_snd_id" := internalSndId,
      ":internal_id" := internalId,
      ":snd_status" := Created,
      ":internal_hash" := internalHash
    ]

updateHashSnd_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
updateHashSnd_ dbConn connId SndMsgData {..} =
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
      ":conn_alias" := connId,
      ":last_internal_snd_msg_id" := internalSndId
    ]

-- create record with a random ID

getConnId_ :: DB.Connection -> TVar ChaChaDRG -> ConnData -> IO (Either StoreError ConnId)
getConnId_ dbConn gVar ConnData {connId = ""} = getUniqueRandomId gVar $ getConnData_ dbConn
getConnId_ _ _ ConnData {connId} = pure $ Right connId

getUniqueRandomId :: TVar ChaChaDRG -> (ByteString -> IO (Maybe a)) -> IO (Either StoreError ByteString)
getUniqueRandomId gVar get = tryGet 3
  where
    tryGet :: Int -> IO (Either StoreError ByteString)
    tryGet 0 = pure $ Left SEUniqueID
    tryGet n = do
      id' <- randomId gVar 12
      get id' >>= \case
        Nothing -> pure $ Right id'
        Just _ -> tryGet (n - 1)

createWithRandomId :: TVar ChaChaDRG -> (ByteString -> IO ()) -> IO (Either StoreError ByteString)
createWithRandomId gVar create = tryCreate 3
  where
    tryCreate :: Int -> IO (Either StoreError ByteString)
    tryCreate 0 = pure $ Left SEUniqueID
    tryCreate n = do
      id' <- randomId gVar 12
      E.try (create id') >>= \case
        Right _ -> pure $ Right id'
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> pure . Left . SEInternal $ bshow e

randomId :: TVar ChaChaDRG -> Int -> IO ByteString
randomId gVar n = encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)
