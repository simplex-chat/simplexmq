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

module Simplex.Messaging.Agent.Store.Postgres where

-- module Simplex.Messaging.Agent.Store.Postgres
--   ( PostgresStore (..),
--     createPostgresStore,
--     connectPostgresStore,
--     withConnection,
--     withTransaction,
--     fromTextField_,
--     firstRow,
--   )
-- where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (void)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
-- import Simplex.Messaging.Agent.Store.Postgres.Migrations (Migration)

import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.Functor (($>))
import Data.List (find, foldl')
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Database.PostgreSQL.Simple (FromRow, Only (..), Query, SqlError, ToRow)
import qualified Database.PostgreSQL.Simple as DB
import Database.PostgreSQL.Simple.Errors (constraintViolation)
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.Internal (Conversion (..), Field (..))
import Database.PostgreSQL.Simple.SqlQQ (sql)
import Database.PostgreSQL.Simple.ToField (ToField (..))
import qualified Database.PostgreSQL.Simple.TypeInfo
import Database.PostgreSQL.Simple.TypeInfo.Static (bytea, text)
import qualified Database.PostgreSQL.Simple.TypeInfo.Static
import GHC.Word (Word32)
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import qualified Simplex.Messaging.Agent.Store.Postgres.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (RatchetX448, SkippedMsgDiff (..), SkippedMsgKeys)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (blobFieldParser, parseAll)
import Simplex.Messaging.Protocol (MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (bshow, liftIOEither)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import qualified UnliftIO.Exception as E

-- * Postgres Store implementation

data PostgresStore = PostgresStore
  { dbConnInfo :: DB.ConnectInfo,
    dbConnPool :: TBQueue DB.Connection,
    dbNew :: Bool
  }

createPostgresStore :: DB.ConnectInfo -> Int -> IO PostgresStore
-- createPostgresStore :: DB.ConnectInfo -> Int -> [Migration] -> IO PostgresStore
createPostgresStore dbConnInfo poolSize = do
  st <- connectPostgresStore dbConnInfo poolSize
  -- migrateSchema st migrations
  pure st

-- migrateSchema :: PostgresStore -> [Migration] -> IO ()
-- migrateSchema st migrations = withConnection st $ \db -> do
--   Migrations.initialize db
--   Migrations.get db migrations >>= \case
--     Left e -> confirmOrExit $ "Database error: " <> e
--     Right [] -> pure ()
--     Right ms -> do
--       unless (dbNew st) $ do
--         confirmOrExit "The app has a newer version than the database - it will be backed up and upgraded."
--         -- TODO backup
--         -- let f = dbFilePath st
--         -- copyFile f (f <> ".bak")
--       Migrations.run db ms

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

connectPostgresStore :: DB.ConnectInfo -> Int -> IO PostgresStore
connectPostgresStore dbConnInfo poolSize = do
  let dbNew = True -- TODO scan migrations
  dbConnPool <- newTBQueueIO $ toEnum poolSize
  replicateM_ poolSize $
    connectDB dbConnInfo >>= atomically . writeTBQueue dbConnPool
  pure PostgresStore {dbConnInfo, dbConnPool, dbNew}

connectDB :: DB.ConnectInfo -> IO DB.Connection
connectDB = DB.connect

checkConstraint :: StoreError -> IO (Either StoreError a) -> IO (Either StoreError a)
checkConstraint err action = action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SqlError -> StoreError
handleSQLError err e = case constraintViolation e of
  Just _ -> err
  Nothing -> SEInternal $ bshow e

withConnection :: PostgresStore -> (DB.Connection -> IO a) -> IO a
withConnection PostgresStore {dbConnPool} =
  bracket
    (atomically $ readTBQueue dbConnPool)
    (atomically . writeTBQueue dbConnPool)

execute :: ToRow q => DB.Connection -> Query -> q -> IO ()
execute db query q = void $ DB.execute db query q

-- TODO not sure this logic is needed with Postgres, also no such error
-- withTransaction :: forall a. PostgresStore -> (DB.Connection -> IO a) -> IO a
-- withTransaction st action = withConnection st $ loop 100 100_000
--   where
--     loop :: Int -> Int -> DB.Connection -> IO a
--     loop t tLim db =
--       DB.withTransaction db (action db) `E.catch` \(e :: SQLError) ->
--         if tLim > t && DB.sqlError e == DB.ErrorBusy
--           then do
--             threadDelay t
--             loop (t * 9 `div` 8) (tLim - t) db
--           else E.throwIO e

withTransaction :: forall a. PostgresStore -> (DB.Connection -> IO a) -> IO a
withTransaction st action = withConnection st inTransaction
  where
    inTransaction :: DB.Connection -> IO a
    inTransaction db = DB.withTransaction db (action db)

createConn_ ::
  (MonadUnliftIO m, MonadError StoreError m) =>
  PostgresStore ->
  TVar ChaChaDRG ->
  ConnData ->
  (DB.Connection -> ByteString -> IO ()) ->
  m ByteString
createConn_ st gVar cData create =
  liftIOEither . checkConstraint SEConnDuplicate . withTransaction st $ \db ->
    case cData of
      ConnData {connId = ""} -> createWithRandomId gVar $ create db
      ConnData {connId} -> create db connId $> Right connId

instance (MonadUnliftIO m, MonadError StoreError m) => MonadAgentStore PostgresStore m where
  createRcvConn :: PostgresStore -> TVar ChaChaDRG -> ConnData -> RcvQueue -> SConnectionMode c -> m ConnId
  createRcvConn st gVar cData q@RcvQueue {server} cMode =
    createConn_ st gVar cData $ \db connId -> do
      upsertServer_ db server
      execute db "INSERT INTO connections (conn_id, conn_mode) VALUES (?, ?)" (connId, cMode)
      insertRcvQueue_ db connId q

  createSndConn :: PostgresStore -> TVar ChaChaDRG -> ConnData -> SndQueue -> m ConnId
  createSndConn st gVar cData q@SndQueue {server} =
    createConn_ st gVar cData $ \db connId -> do
      upsertServer_ db server
      execute db "INSERT INTO connections (conn_id, conn_mode) VALUES (?, ?)" (connId, SCMInvitation)
      insertSndQueue_ db connId q

  getConn :: PostgresStore -> ConnId -> m SomeConn
  getConn st connId =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId

  getRcvConn :: PostgresStore -> SMPServer -> SMP.RecipientId -> m SomeConn
  getRcvConn st SMPServer {host, port} rcvId =
    liftIOEither . withTransaction st $ \db ->
      DB.query
        db
        [sql|
          SELECT q.conn_id
          FROM rcv_queues q
          WHERE q.host = ? AND q.port = ? AND q.rcv_id = ?;
        |]
        (host, port, rcvId)
        >>= \case
          [Only connId] -> getConn_ db connId
          _ -> pure $ Left SEConnNotFound

  deleteConn :: PostgresStore -> ConnId -> m ()
  deleteConn st connId =
    liftIO . withTransaction st $ \db ->
      execute
        db
        "DELETE FROM connections WHERE conn_id = ?;"
        (Only connId)

  upgradeRcvConnToDuplex :: PostgresStore -> ConnId -> SndQueue -> m ()
  upgradeRcvConnToDuplex st connId sq@SndQueue {server} =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId >>= \case
        Right (SomeConn _ RcvConnection {}) -> do
          upsertServer_ db server
          insertSndQueue_ db connId sq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  upgradeSndConnToDuplex :: PostgresStore -> ConnId -> RcvQueue -> m ()
  upgradeSndConnToDuplex st connId rq@RcvQueue {server} =
    liftIOEither . withTransaction st $ \db ->
      getConn_ db connId >>= \case
        Right (SomeConn _ SndConnection {}) -> do
          upsertServer_ db server
          insertRcvQueue_ db connId rq
          pure $ Right ()
        Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
        _ -> pure $ Left SEConnNotFound

  setRcvQueueStatus :: PostgresStore -> RcvQueue -> QueueStatus -> m ()
  setRcvQueueStatus st RcvQueue {rcvId, server = SMPServer {host, port}} status =
    -- ? throw error if queue does not exist?
    liftIO . withTransaction st $ \db ->
      execute
        db
        [sql|
          UPDATE rcv_queues
          SET status = ?
          WHERE host = ? AND port = ? AND rcv_id = ?;
        |]
        (status, host, port, rcvId)

  setRcvQueueConfirmedE2E :: PostgresStore -> RcvQueue -> C.DhSecretX25519 -> m ()
  setRcvQueueConfirmedE2E st RcvQueue {rcvId, server = SMPServer {host, port}} e2eDhSecret =
    liftIO . withTransaction st $ \db ->
      execute
        db
        [sql|
          UPDATE rcv_queues
          SET e2e_dh_secret = ?,
              status = ?
          WHERE host = ? AND port = ? AND rcv_id = ?
        |]
        (Confirmed, e2eDhSecret, host, port, rcvId)

  setSndQueueStatus :: PostgresStore -> SndQueue -> QueueStatus -> m ()
  setSndQueueStatus st SndQueue {sndId, server = SMPServer {host, port}} status =
    -- ? throw error if queue does not exist?
    liftIO . withTransaction st $ \db ->
      execute
        db
        [sql|
          UPDATE snd_queues
          SET status = ?
          WHERE host = ? AND port = ? AND snd_id = ?;
        |]
        (status, host, port, sndId)

  createConfirmation :: PostgresStore -> TVar ChaChaDRG -> NewConfirmation -> m ConfirmationId
  createConfirmation st gVar NewConfirmation {connId, senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo}, ratchetState} =
    liftIOEither . withTransaction st $ \db ->
      createWithRandomId gVar $ \confirmationId ->
        execute
          db
          [sql|
            INSERT INTO conn_confirmations
            (confirmation_id, conn_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info, accepted) VALUES (?, ?, ?, ?, ?, ?, 0);
          |]
          (confirmationId, connId, senderKey, e2ePubKey, ratchetState, connInfo)

  acceptConfirmation :: PostgresStore -> ConfirmationId -> ConnInfo -> m AcceptedConfirmation
  acceptConfirmation st confirmationId ownConnInfo =
    liftIOEither . withTransaction st $ \db -> do
      execute
        db
        [sql|
          UPDATE conn_confirmations
          SET accepted = 1,
              own_conn_info = ?
          WHERE confirmation_id = ?;
        |]
        (ownConnInfo, confirmationId)
      firstRow confirmation SEConfirmationNotFound $
        DB.query
          db
          [sql|
            SELECT conn_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info
            FROM conn_confirmations
            WHERE confirmation_id = ?;
          |]
          (Only confirmationId)
    where
      confirmation (connId, senderKey, e2ePubKey, ratchetState, connInfo) =
        AcceptedConfirmation
          { confirmationId,
            connId,
            senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo},
            ratchetState,
            ownConnInfo
          }

  getAcceptedConfirmation :: PostgresStore -> ConnId -> m AcceptedConfirmation
  getAcceptedConfirmation st connId =
    liftIOEither . withTransaction st $ \db ->
      firstRow confirmation SEConfirmationNotFound $
        DB.query
          db
          [sql|
            SELECT confirmation_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info, own_conn_info
            FROM conn_confirmations
            WHERE conn_id = ? AND accepted = 1;
          |]
          (Only connId)
    where
      confirmation (confirmationId, senderKey, e2ePubKey, ratchetState, connInfo, ownConnInfo) =
        AcceptedConfirmation
          { confirmationId,
            connId,
            senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo},
            ratchetState,
            ownConnInfo
          }

  removeConfirmations :: PostgresStore -> ConnId -> m ()
  removeConfirmations st connId =
    liftIO . withTransaction st $ \db ->
      execute
        db
        [sql|
          DELETE FROM conn_confirmations
          WHERE conn_id = ?;
        |]
        (Only connId)

  createInvitation :: PostgresStore -> TVar ChaChaDRG -> NewInvitation -> m InvitationId
  createInvitation st gVar NewInvitation {contactConnId, connReq, recipientConnInfo} =
    liftIOEither . withTransaction st $ \db ->
      createWithRandomId gVar $ \invitationId ->
        execute
          db
          [sql|
            INSERT INTO conn_invitations
            (invitation_id,  contact_conn_id, cr_invitation, recipient_conn_info, accepted) VALUES (?, ?, ?, ?, 0);
          |]
          (invitationId, contactConnId, connReq, recipientConnInfo)

  getInvitation :: PostgresStore -> InvitationId -> m Invitation
  getInvitation st invitationId =
    liftIOEither . withTransaction st $ \db ->
      firstRow invitation SEInvitationNotFound $
        DB.query
          db
          [sql|
            SELECT contact_conn_id, cr_invitation, recipient_conn_info, own_conn_info, accepted
            FROM conn_invitations
            WHERE invitation_id = ?
              AND accepted = 0
          |]
          (Only invitationId)
    where
      invitation (contactConnId, connReq, recipientConnInfo, ownConnInfo, accepted) =
        Invitation {invitationId, contactConnId, connReq, recipientConnInfo, ownConnInfo, accepted}

  acceptInvitation :: PostgresStore -> InvitationId -> ConnInfo -> m ()
  acceptInvitation st invitationId ownConnInfo =
    liftIO . withTransaction st $ \db -> do
      execute
        db
        [sql|
          UPDATE conn_invitations
          SET accepted = 1,
              own_conn_info = ?
          WHERE invitation_id = ?
        |]
        (ownConnInfo, invitationId)

  deleteInvitation :: PostgresStore -> ConnId -> InvitationId -> m ()
  deleteInvitation st contactConnId invId =
    liftIOEither . withTransaction st $ \db ->
      runExceptT $
        ExceptT (getConn_ db contactConnId) >>= \case
          SomeConn SCContact _ ->
            liftIO $ execute db "DELETE FROM conn_invitations WHERE contact_conn_id = ? AND invitation_id = ?" (contactConnId, invId)
          _ -> throwError SEConnNotFound

  updateRcvIds :: PostgresStore -> ConnId -> m (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
  updateRcvIds st connId =
    liftIO . withTransaction st $ \db -> do
      (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash) <- retrieveLastIdsAndHashRcv_ db connId
      let internalId = InternalId $ unId lastInternalId + 1
          internalRcvId = InternalRcvId $ unRcvId lastInternalRcvId + 1
      updateLastIdsRcv_ db connId internalId internalRcvId
      pure (internalId, internalRcvId, lastExternalSndId, lastRcvHash)

  createRcvMsg :: PostgresStore -> ConnId -> RcvMsgData -> m ()
  createRcvMsg st connId rcvMsgData =
    liftIO . withTransaction st $ \db -> do
      insertRcvMsgBase_ db connId rcvMsgData
      insertRcvMsgDetails_ db connId rcvMsgData
      updateHashRcv_ db connId rcvMsgData

  updateSndIds :: PostgresStore -> ConnId -> m (InternalId, InternalSndId, PrevSndMsgHash)
  updateSndIds st connId =
    liftIO . withTransaction st $ \db -> do
      (lastInternalId, lastInternalSndId, prevSndHash) <- retrieveLastIdsAndHashSnd_ db connId
      let internalId = InternalId $ unId lastInternalId + 1
          internalSndId = InternalSndId $ unSndId lastInternalSndId + 1
      updateLastIdsSnd_ db connId internalId internalSndId
      pure (internalId, internalSndId, prevSndHash)

  createSndMsg :: PostgresStore -> ConnId -> SndMsgData -> m ()
  createSndMsg st connId sndMsgData =
    liftIO . withTransaction st $ \db -> do
      insertSndMsgBase_ db connId sndMsgData
      insertSndMsgDetails_ db connId sndMsgData
      updateHashSnd_ db connId sndMsgData

  getPendingMsgData :: PostgresStore -> ConnId -> InternalId -> m (Maybe RcvQueue, (AMsgType, MsgBody, InternalTs))
  getPendingMsgData st connId msgId =
    liftIOEither . withTransaction st $ \db -> runExceptT $ do
      rq_ <- liftIO $ getRcvQueueByConnId_ db connId
      msgData <-
        ExceptT . firstRow id SEMsgNotFound $
          DB.query
            db
            [sql|
                SELECT m.msg_type, m.msg_body, m.internal_ts
                FROM messages m
                JOIN snd_messages s ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
                WHERE m.conn_id = ? AND m.internal_id = ?
              |]
            (connId, msgId)
      pure (rq_, msgData)

  getPendingMsgs :: PostgresStore -> ConnId -> m [InternalId]
  getPendingMsgs st connId =
    liftIO . withTransaction st $ \db ->
      map fromOnly
        <$> DB.query db "SELECT internal_id FROM snd_messages WHERE conn_id = ?" (Only connId)

  checkRcvMsg :: PostgresStore -> ConnId -> InternalId -> m ()
  checkRcvMsg st connId msgId =
    liftIOEither . withTransaction st $ \db ->
      hasMsg
        <$> DB.query
          db
          [sql|
            SELECT conn_id, internal_id
            FROM rcv_messages
            WHERE conn_id = ? AND internal_id = ?
          |]
          (connId, msgId)
    where
      hasMsg :: [(ConnId, InternalId)] -> Either StoreError ()
      hasMsg r = if null r then Left SEMsgNotFound else Right ()

  deleteMsg :: PostgresStore -> ConnId -> InternalId -> m ()
  deleteMsg st connId msgId =
    liftIO . withTransaction st $ \db ->
      execute db "DELETE FROM messages WHERE conn_id = ? AND internal_id = ?;" (connId, msgId)

  createRatchetX3dhKeys :: PostgresStore -> ConnId -> C.PrivateKeyX448 -> C.PrivateKeyX448 -> m ()
  createRatchetX3dhKeys st connId x3dhPrivKey1 x3dhPrivKey2 =
    liftIO . withTransaction st $ \db ->
      execute db "INSERT INTO ratchets (conn_id, x3dh_priv_key_1, x3dh_priv_key_2) VALUES (?, ?, ?)" (connId, x3dhPrivKey1, x3dhPrivKey2)

  getRatchetX3dhKeys :: PostgresStore -> ConnId -> m (C.PrivateKeyX448, C.PrivateKeyX448)
  getRatchetX3dhKeys st connId =
    liftIOEither . withTransaction st $ \db ->
      fmap hasKeys $
        firstRow id SEX3dhKeysNotFound $
          DB.query db "SELECT x3dh_priv_key_1, x3dh_priv_key_2 FROM ratchets WHERE conn_id = ?" (Only connId)
    where
      hasKeys = \case
        Right (Just k1, Just k2) -> Right (k1, k2)
        _ -> Left SEX3dhKeysNotFound

  createRatchet :: PostgresStore -> ConnId -> RatchetX448 -> m ()
  createRatchet st connId rc =
    liftIO . withTransaction st $ \db -> do
      execute
        db
        [sql|
          INSERT INTO ratchets (conn_id, ratchet_state)
          VALUES (?, ?)
          ON CONFLICT (conn_id) DO UPDATE SET
            ratchet_state = ?,
            x3dh_priv_key_1 = NULL,
            x3dh_priv_key_2 = NULL
        |]
        (connId, rc, rc)

  getRatchet :: PostgresStore -> ConnId -> m RatchetX448
  getRatchet st connId =
    liftIOEither . withTransaction st $ \db ->
      ratchet
        <$> DB.query db "SELECT ratchet_state FROM ratchets WHERE conn_id = ?" (Only connId)
    where
      ratchet (Only (Just rc) : _) = Right rc
      ratchet _ = Left SERatchetNotFound

  getSkippedMsgKeys :: PostgresStore -> ConnId -> m SkippedMsgKeys
  getSkippedMsgKeys st connId =
    liftIO . withTransaction st $ \db ->
      skipped <$> DB.query db "SELECT header_key, msg_n, msg_key FROM skipped_messages WHERE conn_id = ?" (Only connId)
    where
      skipped ms = foldl' addSkippedKey M.empty ms
      addSkippedKey smks (hk, msgN, mk) = M.alter (Just . addMsgKey) hk smks
        where
          addMsgKey = maybe (M.singleton msgN mk) (M.insert msgN mk)

  updateRatchet :: PostgresStore -> ConnId -> RatchetX448 -> SkippedMsgDiff -> m ()
  updateRatchet st connId rc skipped =
    liftIO . withTransaction st $ \db -> do
      execute db "UPDATE ratchets SET ratchet_state = ? WHERE conn_id = ?" (rc, connId)
      case skipped of
        SMDNoChange -> pure ()
        SMDRemove hk msgN ->
          execute db "DELETE FROM skipped_messages WHERE conn_id = ? AND header_key = ? AND msg_n = ?" (connId, hk, msgN)
        SMDAdd smks ->
          forM_ (M.assocs smks) $ \(hk, mks) ->
            forM_ (M.assocs mks) $ \(msgN, mk) ->
              execute db "INSERT INTO skipped_messages (conn_id, header_key, msg_n, msg_key) VALUES (?, ?, ?, ?)" (connId, hk, msgN, mk)

-- -- * Auxiliary helpers

instance ToField QueueStatus where toField = toField . serializeQueueStatus

instance FromField QueueStatus where fromField = fromTextField_ queueStatusT

instance ToField InternalRcvId where toField (InternalRcvId x) = toField x

instance FromField InternalRcvId where fromField x = fromField x

instance ToField InternalSndId where toField (InternalSndId x) = toField x

instance FromField InternalSndId where fromField x = fromField x

instance ToField InternalId where toField (InternalId x) = toField x

instance FromField InternalId where fromField x = fromField x

instance ToField AMsgType where toField = toField . smpEncode

instance FromField AMsgType where fromField = fromByteStringField $ parseAll smpP

instance ToField MsgIntegrity where toField = toField . strEncode

instance FromField MsgIntegrity where fromField = fromByteStringField $ parseAll strP

instance ToField SMPQueueUri where toField = toField . strEncode

instance FromField SMPQueueUri where fromField = fromByteStringField $ parseAll strP

instance ToField AConnectionRequestUri where toField = toField . strEncode

instance FromField AConnectionRequestUri where fromField = fromByteStringField $ parseAll strP

instance ConnectionModeI c => ToField (ConnectionRequestUri c) where toField = toField . strEncode

instance (E.Typeable c, ConnectionModeI c) => FromField (ConnectionRequestUri c) where fromField = fromByteStringField $ parseAll strP

instance ToField ConnectionMode where toField = toField . decodeLatin1 . strEncode

instance FromField ConnectionMode where fromField = fromTextField_ connModeT

instance ToField (SConnectionMode c) where toField = toField . connMode

instance FromField AConnectionMode where fromField = fromTextField_ $ fmap connMode' . connModeT

instance FromField Word32 where fromField x = fromField x

fromTextField_ :: E.Typeable a => (Text -> Maybe a) -> Field -> Maybe ByteString -> Conversion a
fromTextField_ fromText f mdata =
  if typeOid f /= typoid text
    then returnError Incompatible f ""
    else case mdata of
      Nothing -> returnError UnexpectedNull f ""
      Just dat ->
        case fromText ((T.pack . B.unpack) dat) of
          Just x -> return x
          _ -> returnError ConversionFailed f (B.unpack dat)

-- TODO same as in Crypto
fromByteStringField :: E.Typeable a => (ByteString -> Either String a) -> Field -> Maybe ByteString -> Conversion a
fromByteStringField dec f mdata =
  if typeOid f /= typoid bytea
    then returnError Incompatible f ""
    else case mdata of
      Nothing -> returnError UnexpectedNull f ""
      Just dat ->
        case dec dat of
          Right x -> return x
          _ -> returnError ConversionFailed f (B.unpack dat)

listToEither :: e -> [a] -> Either e a
listToEither _ (x : _) = Right x
listToEither e _ = Left e

firstRow :: (a -> b) -> e -> IO [a] -> IO (Either e b)
firstRow f e a = second f . listToEither e <$> a

-- {- ORMOLU_DISABLE -}
-- -- SQLite.Simple only has these up to 10 fields, which is insufficient for some of our queries
-- instance (FromField a, FromField b, FromField c, FromField d, FromField e,
--           FromField f, FromField g, FromField h, FromField i, FromField j,
--           FromField k) =>
--   FromRow (a,b,c,d,e,f,g,h,i,j,k) where
--   fromRow = (,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
--                          <*> field <*> field <*> field <*> field <*> field
--                          <*> field

-- instance (FromField a, FromField b, FromField c, FromField d, FromField e,
--           FromField f, FromField g, FromField h, FromField i, FromField j,
--           FromField k, FromField l) =>
--   FromRow (a,b,c,d,e,f,g,h,i,j,k,l) where
--   fromRow = (,,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
--                           <*> field <*> field <*> field <*> field <*> field
--                           <*> field <*> field

-- instance (ToField a, ToField b, ToField c, ToField d, ToField e, ToField f,
--           ToField g, ToField h, ToField i, ToField j, ToField k, ToField l) =>
--   ToRow (a,b,c,d,e,f,g,h,i,j,k,l) where
--   toRow (a,b,c,d,e,f,g,h,i,j,k,l) =
--     [ toField a, toField b, toField c, toField d, toField e, toField f,
--       toField g, toField h, toField i, toField j, toField k, toField l
--     ]

-- {- ORMOLU_ENABLE -}

-- * Server upsert helper

upsertServer_ :: DB.Connection -> SMPServer -> IO ()
upsertServer_ dbConn SMPServer {host, port, keyHash} = do
  execute
    dbConn
    [sql|
      INSERT INTO servers (host, port, key_hash) VALUES (?,?,?)
      ON CONFLICT (host, port) DO UPDATE SET
        host=excluded.host,
        port=excluded.port,
        key_hash=excluded.key_hash;
    |]
    (host, port, keyHash)

-- * createRcvConn helpers

insertRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO ()
insertRcvQueue_ dbConn connId RcvQueue {..} = do
  execute
    dbConn
    [sql|
      INSERT INTO rcv_queues
        ( host, port, rcv_id, conn_id, rcv_private_key, rcv_dh_secret, e2e_priv_key, e2e_dh_secret, snd_id, status)
      VALUES
        (?,?,?,?,?,?,?,?,?,?);
    |]
    (host server, port server, rcvId, connId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status)

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO ()
insertSndQueue_ dbConn connId SndQueue {..} = do
  execute
    dbConn
    [sql|
      INSERT INTO snd_queues
        ( host, port, snd_id, conn_id, snd_private_key, e2e_dh_secret, status)
      VALUES
        (?,?,?,?,?,?,?);
    |]
    (host server, port server, sndId, connId, sndPrivateKey, e2eDhSecret, status)

-- * getConn helpers

getConn_ :: DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getConn_ dbConn connId =
  getConnData_ dbConn connId >>= \case
    Nothing -> pure $ Left SEConnNotFound
    Just (connData, cMode) -> do
      rQ <- getRcvQueueByConnId_ dbConn connId
      sQ <- getSndQueueByConnId_ dbConn connId
      pure $ case (rQ, sQ, cMode) of
        (Just rcvQ, Just sndQ, CMInvitation) -> Right $ SomeConn SCDuplex (DuplexConnection connData rcvQ sndQ)
        (Just rcvQ, Nothing, CMInvitation) -> Right $ SomeConn SCRcv (RcvConnection connData rcvQ)
        (Nothing, Just sndQ, CMInvitation) -> Right $ SomeConn SCSnd (SndConnection connData sndQ)
        (Just rcvQ, Nothing, CMContact) -> Right $ SomeConn SCContact (ContactConnection connData rcvQ)
        _ -> Left SEConnNotFound

getConnData_ :: DB.Connection -> ConnId -> IO (Maybe (ConnData, ConnectionMode))
getConnData_ dbConn connId' =
  connData
    <$> DB.query dbConn "SELECT conn_id, conn_mode FROM connections WHERE conn_id = ?;" (Only connId')
  where
    connData [(connId, cMode)] = Just (ConnData {connId}, cMode)
    connData _ = Nothing

getRcvQueueByConnId_ :: DB.Connection -> ConnId -> IO (Maybe RcvQueue)
getRcvQueueByConnId_ dbConn connId =
  rcvQueue
    <$> DB.query
      dbConn
      [sql|
        SELECT s.key_hash, q.host, q.port, q.rcv_id, q.rcv_private_key, q.rcv_dh_secret,
          q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.status
        FROM rcv_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_id = ?;
      |]
      (Only connId)
  where
    rcvQueue [(keyHash, host, port, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status)] =
      let server = SMPServer host port keyHash
       in Just RcvQueue {server, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status}
    rcvQueue _ = Nothing

getSndQueueByConnId_ :: DB.Connection -> ConnId -> IO (Maybe SndQueue)
getSndQueueByConnId_ dbConn connId =
  sndQueue
    <$> DB.query
      dbConn
      [sql|
        SELECT s.key_hash, q.host, q.port, q.snd_id, q.snd_private_key, q.e2e_dh_secret, q.status
        FROM snd_queues q
        INNER JOIN servers s ON q.host = s.host AND q.port = s.port
        WHERE q.conn_id = ?;
      |]
      (Only connId)
  where
    sndQueue [(keyHash, host, port, sndId, sndPrivateKey, e2eDhSecret, status)] =
      let server = SMPServer host port keyHash
       in Just SndQueue {server, sndId, sndPrivateKey, e2eDhSecret, status}
    sndQueue _ = Nothing

-- * updateRcvIds helpers

retrieveLastIdsAndHashRcv_ :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
retrieveLastIdsAndHashRcv_ dbConn connId = do
  [(lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)] <-
    DB.query
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash
        FROM connections
        WHERE conn_id = ?;
      |]
      (Only connId)
  return (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)

updateLastIdsRcv_ :: DB.Connection -> ConnId -> InternalId -> InternalRcvId -> IO ()
updateLastIdsRcv_ dbConn connId newInternalId newInternalRcvId =
  execute
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_rcv_msg_id = :last_internal_rcv_msg_id
      WHERE conn_id = :conn_id;
    |]
    (newInternalId, newInternalRcvId, connId)

-- * createRcvMsg helpers

insertRcvMsgBase_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgBase_ dbConn connId RcvMsgData {msgMeta, msgType, msgBody, internalRcvId} = do
  let MsgMeta {recipient = (internalId, internalTs)} = msgMeta
  execute
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_body)
      VALUES
        (?,?,?,?,NULL,?,?);
    |]
    (connId, internalId, internalTs, internalRcvId, msgType, msgBody)

insertRcvMsgDetails_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgDetails_ dbConn connId RcvMsgData {msgMeta, internalRcvId, internalHash, externalPrevSndHash} = do
  let MsgMeta {integrity, recipient, broker, sndMsgId} = msgMeta
  execute
    dbConn
    [sql|
      INSERT INTO rcv_messages
        ( conn_id, internal_rcv_id, internal_id, external_snd_id,
          broker_id, broker_ts,
          internal_hash, external_prev_snd_hash, integrity)
      VALUES
        (?,?,?,?,
         ?,?,
         ?,?,?);
    |]
    (connId, internalRcvId, fst recipient, sndMsgId, fst broker, snd broker, internalHash, externalPrevSndHash, integrity)

updateHashRcv_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connId RcvMsgData {msgMeta, internalHash, internalRcvId} =
  execute
    dbConn
    -- last_internal_rcv_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_external_snd_msg_id = ?,
          last_rcv_msg_hash = ?
      WHERE conn_id = ?
        AND last_internal_rcv_msg_id = ?;
    |]
    (sndMsgId (msgMeta :: MsgMeta), internalHash, connId, internalRcvId)

-- * updateSndIds helpers

retrieveLastIdsAndHashSnd_ :: DB.Connection -> ConnId -> IO (InternalId, InternalSndId, PrevSndMsgHash)
retrieveLastIdsAndHashSnd_ dbConn connId = do
  [(lastInternalId, lastInternalSndId, lastSndHash)] <-
    DB.query
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_snd_msg_id, last_snd_msg_hash
        FROM connections
        WHERE conn_id = ?;
      |]
      (Only connId)
  return (lastInternalId, lastInternalSndId, lastSndHash)

updateLastIdsSnd_ :: DB.Connection -> ConnId -> InternalId -> InternalSndId -> IO ()
updateLastIdsSnd_ dbConn connId newInternalId newInternalSndId =
  execute
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = ?,
          last_internal_snd_msg_id = ?
      WHERE conn_id = ?;
    |]
    (newInternalId, newInternalSndId, connId)

-- * createSndMsg helpers

insertSndMsgBase_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgBase_ dbConn connId SndMsgData {..} = do
  execute
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_body)
      VALUES
        (?,?,?,NULL,?,?, ?);
    |]
    (connId, internalId, internalTs, internalSndId, msgType, msgBody)

insertSndMsgDetails_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgDetails_ dbConn connId SndMsgData {..} =
  execute
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_id, internal_snd_id, internal_id, internal_hash, previous_msg_hash)
      VALUES
        (?,?,?,?,?);
    |]
    (connId, internalSndId, internalId, internalHash, prevMsgHash)

updateHashSnd_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
updateHashSnd_ dbConn connId SndMsgData {..} =
  execute
    dbConn
    -- last_internal_snd_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_snd_msg_hash = ?
      WHERE conn_id = ?
        AND last_internal_snd_msg_id = ?;
    |]
    (internalHash, connId, internalSndId)

-- create record with a random ID
createWithRandomId :: TVar ChaChaDRG -> (ByteString -> IO ()) -> IO (Either StoreError ByteString)
createWithRandomId gVar create = tryCreate 3
  where
    tryCreate :: Int -> IO (Either StoreError ByteString)
    tryCreate 0 = pure $ Left SEUniqueID
    tryCreate n = do
      id' <- randomId gVar 12
      E.try (create id') >>= \case
        Right _ -> pure $ Right id'
        Left e -> case constraintViolation e of
          Just _ -> tryCreate (n - 1)
          Nothing -> pure . Left . SEInternal $ bshow e

randomId :: TVar ChaChaDRG -> Int -> IO ByteString
randomId gVar n = U.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)
