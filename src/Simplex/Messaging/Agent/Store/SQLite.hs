{-# LANGUAGE ConstraintKinds #-}
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
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( SQLiteStore (..),
    createSQLiteStore,
    connectSQLiteStore,
    closeSQLiteStore,
    sqlString,
    execSQL,

    -- * Users
    createUserRecord,
    deleteUserRecord,
    setUserDeleted,
    deleteUserWithoutConns,
    deleteUsersWithoutConns,
    checkUser,

    -- * Queues and connections
    createNewConn,
    updateNewConnRcv,
    updateNewConnSnd,
    createRcvConn,
    createSndConn,
    getConn,
    getDeletedConn,
    getConns,
    getDeletedConns,
    getConnData,
    setConnDeleted,
    getDeletedConnIds,
    getRcvConn,
    deleteConn,
    upgradeRcvConnToDuplex,
    upgradeSndConnToDuplex,
    addConnRcvQueue,
    addConnSndQueue,
    setRcvQueueStatus,
    setRcvQueueConfirmedE2E,
    setSndQueueStatus,
    setRcvQueuePrimary,
    setSndQueuePrimary,
    deleteConnRcvQueue,
    incRcvDeleteErrors,
    deleteConnSndQueue,
    getPrimaryRcvQueue,
    getRcvQueue,
    setRcvQueueNtfCreds,
    -- Confirmations
    createConfirmation,
    acceptConfirmation,
    getAcceptedConfirmation,
    removeConfirmations,
    setHandshakeVersion,
    -- Invitations - sent via Contact connections
    createInvitation,
    getInvitation,
    acceptInvitation,
    unacceptInvitation,
    deleteInvitation,
    -- Messages
    updateRcvIds,
    createRcvMsg,
    updateSndIds,
    createSndMsg,
    createSndMsgDelivery,
    getPendingMsgData,
    getPendingMsgs,
    deletePendingMsgs,
    setMsgUserAck,
    getLastMsg,
    deleteMsg,
    deleteSndMsgDelivery,
    -- Double ratchet persistence
    createRatchetX3dhKeys,
    getRatchetX3dhKeys,
    createRatchet,
    getRatchet,
    getSkippedMsgKeys,
    updateRatchet,
    -- Async commands
    createCommand,
    getPendingCommands,
    getPendingCommand,
    deleteCommand,
    -- Notification device token persistence
    createNtfToken,
    getSavedNtfToken,
    updateNtfTokenRegistration,
    updateDeviceToken,
    updateNtfMode,
    updateNtfToken,
    removeNtfToken,
    -- Notification subscription persistence
    getNtfSubscription,
    createNtfSubscription,
    supervisorUpdateNtfSub,
    supervisorUpdateNtfAction,
    updateNtfSubscription,
    setNullNtfSubscriptionAction,
    deleteNtfSubscription,
    getNextNtfSubNTFAction,
    getNextNtfSubSMPAction,
    getActiveNtfToken,
    getNtfRcvQueue,
    setConnectionNtfs,

    -- * utilities
    withConnection,
    withTransaction,
    firstRow,
    firstRow',
    maybeFirstRow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (stateTVar)
import Control.Monad.Except
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import Data.Char (toLower)
import Data.Function (on)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import Data.List (foldl', groupBy, sortBy)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.SQLite.Simple (FromRow, NamedParam (..), Only (..), Query (..), SQLError, ToRow, field, (:.) (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import qualified Database.SQLite3 as SQLite3
import Network.Socket (ServiceName)
import Simplex.FileTransfer.Description (FileDescription)
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Migrations (Migration)
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (RatchetX448, SkippedMsgDiff (..), SkippedMsgKeys)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfSubscriptionId, NtfTknStatus (..), NtfTokenId, SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (blobFieldParser, fromTextField_)
import Simplex.Messaging.Protocol (MsgBody, MsgFlags, NtfServer, ProtocolServer (..), RcvNtfDhSecret, SndPublicVerifyKey, pattern NtfServer)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (bshow, eitherToMaybe, ($>>=), (<$$>))
import Simplex.Messaging.Version
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import UnliftIO.Exception (bracket, onException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM
import Simplex.FileTransfer.Types

-- * SQLite Store implementation

data SQLiteStore = SQLiteStore
  { dbFilePath :: FilePath,
    dbEncrypted :: TVar Bool,
    dbConnection :: TMVar DB.Connection,
    dbNew :: Bool
  }

createSQLiteStore :: FilePath -> String -> [Migration] -> Bool -> IO SQLiteStore
createSQLiteStore dbFilePath dbKey migrations yesToMigrations = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing False dbDir
  st <- connectSQLiteStore dbFilePath dbKey
  migrateSchema st migrations yesToMigrations `onException` closeSQLiteStore st
  pure st

migrateSchema :: SQLiteStore -> [Migration] -> Bool -> IO ()
migrateSchema st migrations yesToMigrations = withConnection st $ \db -> do
  Migrations.initialize db
  Migrations.get db migrations >>= \case
    Left e -> confirmOrExit $ "Database error: " <> e
    Right [] -> pure ()
    Right ms -> do
      unless (dbNew st) $ do
        unless yesToMigrations $
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

connectSQLiteStore :: FilePath -> String -> IO SQLiteStore
connectSQLiteStore dbFilePath dbKey = do
  dbNew <- not <$> doesFileExist dbFilePath
  dbConnection <- newTMVarIO =<< connectDB dbFilePath dbKey
  dbEncrypted <- newTVarIO . not $ null dbKey
  pure SQLiteStore {dbFilePath, dbEncrypted, dbConnection, dbNew}

connectDB :: FilePath -> String -> IO DB.Connection
connectDB path key = do
  db <- DB.open path
  prepare db `onException` DB.close db
  -- _printPragmas db path
  pure db
  where
    prepare db = do
      let exec = SQLite3.exec $ DB.connectionHandle db
      unless (null key) . exec $ "PRAGMA key = " <> sqlString key <> ";"
      exec . fromQuery $
        [sql|
          PRAGMA foreign_keys = ON;
          -- PRAGMA trusted_schema = OFF;
          PRAGMA secure_delete = ON;
          PRAGMA auto_vacuum = FULL;
        |]

closeSQLiteStore :: SQLiteStore -> IO ()
closeSQLiteStore st = atomically (takeTMVar $ dbConnection st) >>= DB.close

sqlString :: String -> Text
sqlString s = quote <> T.replace quote "''" (T.pack s) <> quote
  where
    quote = "'"

-- _printPragmas :: DB.Connection -> FilePath -> IO ()
-- _printPragmas db path = do
--   foreign_keys <- DB.query_ db "PRAGMA foreign_keys;" :: IO [[Int]]
--   print $ path <> " foreign_keys: " <> show foreign_keys
--   -- when run via sqlite-simple query for trusted_schema seems to return empty list
--   trusted_schema <- DB.query_ db "PRAGMA trusted_schema;" :: IO [[Int]]
--   print $ path <> " trusted_schema: " <> show trusted_schema
--   secure_delete <- DB.query_ db "PRAGMA secure_delete;" :: IO [[Int]]
--   print $ path <> " secure_delete: " <> show secure_delete
--   auto_vacuum <- DB.query_ db "PRAGMA auto_vacuum;" :: IO [[Int]]
--   print $ path <> " auto_vacuum: " <> show auto_vacuum

execSQL :: DB.Connection -> Text -> IO [Text]
execSQL db query = do
  rs <- newIORef []
  SQLite3.execWithCallback (DB.connectionHandle db) query (addSQLResultRow rs)
  reverse <$> readIORef rs

addSQLResultRow :: IORef [Text] -> SQLite3.ColumnIndex -> [Text] -> [Maybe Text] -> IO ()
addSQLResultRow rs _count names values = modifyIORef' rs $ \case
  [] -> [showValues values, T.intercalate "|" names]
  rs' -> showValues values : rs'
  where
    showValues = T.intercalate "|" . map (fromMaybe "")

checkConstraint :: StoreError -> IO (Either StoreError a) -> IO (Either StoreError a)
checkConstraint err action = action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SQLError -> StoreError
handleSQLError err e
  | DB.sqlError e == DB.ErrorConstraint = err
  | otherwise = SEInternal $ bshow e

withConnection :: SQLiteStore -> (DB.Connection -> IO a) -> IO a
withConnection SQLiteStore {dbConnection} =
  bracket
    (atomically $ takeTMVar dbConnection)
    (atomically . putTMVar dbConnection)

withTransaction :: forall a. SQLiteStore -> (DB.Connection -> IO a) -> IO a
withTransaction st action = withConnection st $ loop 500 3_000_000
  where
    loop :: Int -> Int -> DB.Connection -> IO a
    loop t tLim db =
      DB.withImmediateTransaction db (action db) `E.catch` \(e :: SQLError) ->
        if tLim > t && DB.sqlError e == DB.ErrorBusy
          then do
            threadDelay t
            loop (t * 9 `div` 8) (tLim - t) db
          else E.throwIO e

createUserRecord :: DB.Connection -> IO UserId
createUserRecord db = do
  DB.execute_ db "INSERT INTO users DEFAULT VALUES"
  insertedRowId db

checkUser :: DB.Connection -> UserId -> IO (Either StoreError ())
checkUser db userId =
  firstRow (\(_ :: Only Int64) -> ()) SEUserNotFound $
    DB.query db "SELECT user_id FROM users WHERE user_id = ? AND deleted = ?" (userId, False)

deleteUserRecord :: DB.Connection -> UserId -> IO (Either StoreError ())
deleteUserRecord db userId = runExceptT $ do
  ExceptT $ checkUser db userId
  liftIO $ DB.execute db "DELETE FROM users WHERE user_id = ?" (Only userId)

setUserDeleted :: DB.Connection -> UserId -> IO (Either StoreError [ConnId])
setUserDeleted db userId = runExceptT $ do
  ExceptT $ checkUser db userId
  liftIO $ do
    DB.execute db "UPDATE users SET deleted = ? WHERE user_id = ?" (True, userId)
    map fromOnly <$> DB.query db "SELECT conn_id FROM connections WHERE user_id = ?" (Only userId)

deleteUserWithoutConns :: DB.Connection -> UserId -> IO Bool
deleteUserWithoutConns db userId = do
  userId_ :: Maybe Int64 <-
    maybeFirstRow fromOnly $
      DB.query
        db
        [sql|
          SELECT user_id FROM users u
          WHERE u.user_id = ?
            AND u.deleted = ?
            AND NOT EXISTS (SELECT c.conn_id FROM connections c WHERE c.user_id = u.user_id)
        |]
        (userId, True)
  case userId_ of
    Just _ -> DB.execute db "DELETE FROM users WHERE user_id = ?" (Only userId) $> True
    _ -> pure False

deleteUsersWithoutConns :: DB.Connection -> IO [Int64]
deleteUsersWithoutConns db = do
  userIds <-
    map fromOnly
      <$> DB.query
        db
        [sql|
          SELECT user_id FROM users u
          WHERE u.deleted = ?
            AND NOT EXISTS (SELECT c.conn_id FROM connections c WHERE c.user_id = u.user_id)
        |]
        (Only True)
  forM_ userIds $ DB.execute db "DELETE FROM users WHERE user_id = ?" . Only
  pure userIds

createConn_ ::
  TVar ChaChaDRG ->
  ConnData ->
  (ByteString -> IO ()) ->
  IO (Either StoreError ByteString)
createConn_ gVar cData create = checkConstraint SEConnDuplicate $ case cData of
  ConnData {connId = ""} -> createWithRandomId gVar create
  ConnData {connId} -> create connId $> Right connId

createNewConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> SConnectionMode c -> IO (Either StoreError ConnId)
createNewConn db gVar cData@ConnData {userId, connAgentVersion, enableNtfs, duplexHandshake} cMode =
  createConn_ gVar cData $ \connId -> do
    DB.execute db "INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?,?,?,?,?,?)" (userId, connId, cMode, connAgentVersion, enableNtfs, duplexHandshake)

updateNewConnRcv :: DB.Connection -> ConnId -> RcvQueue -> IO (Either StoreError Int64)
updateNewConnRcv db connId rq =
  getConn db connId $>>= \case
    (SomeConn _ NewConnection {}) -> updateConn
    (SomeConn _ RcvConnection {}) -> updateConn -- to allow retries
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
  where
    updateConn :: IO (Either StoreError Int64)
    updateConn = Right <$> addConnRcvQueue_ db connId rq

updateNewConnSnd :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError Int64)
updateNewConnSnd db connId sq =
  getConn db connId $>>= \case
    (SomeConn _ NewConnection {}) -> updateConn
    (SomeConn _ SndConnection {}) -> updateConn -- to allow retries
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
  where
    updateConn :: IO (Either StoreError Int64)
    updateConn = Right <$> addConnSndQueue_ db connId sq

createRcvConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> RcvQueue -> SConnectionMode c -> IO (Either StoreError ConnId)
createRcvConn db gVar cData@ConnData {userId, connAgentVersion, enableNtfs, duplexHandshake} q@RcvQueue {server} cMode =
  createConn_ gVar cData $ \connId -> do
    upsertServer_ db server
    DB.execute db "INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?,?,?,?,?,?)" (userId, connId, cMode, connAgentVersion, enableNtfs, duplexHandshake)
    void $ insertRcvQueue_ db connId q

createSndConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> SndQueue -> IO (Either StoreError ConnId)
createSndConn db gVar cData@ConnData {userId, connAgentVersion, enableNtfs, duplexHandshake} q@SndQueue {server} =
  createConn_ gVar cData $ \connId -> do
    upsertServer_ db server
    DB.execute db "INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?,?,?,?,?,?)" (userId, connId, SCMInvitation, connAgentVersion, enableNtfs, duplexHandshake)
    void $ insertSndQueue_ db connId q

getRcvConn :: DB.Connection -> SMPServer -> SMP.RecipientId -> IO (Either StoreError (RcvQueue, SomeConn))
getRcvConn db ProtocolServer {host, port} rcvId = runExceptT $ do
  rq@RcvQueue {connId} <-
    ExceptT . firstRow toRcvQueue SEConnNotFound $
      DB.query db (rcvQueueQuery <> " WHERE q.host = ? AND q.port = ? AND q.rcv_id = ?") (host, port, rcvId)
  (rq,) <$> ExceptT (getConn db connId)

deleteConn :: DB.Connection -> ConnId -> IO ()
deleteConn db connId =
  DB.executeNamed
    db
    "DELETE FROM connections WHERE conn_id = :conn_id;"
    [":conn_id" := connId]

upgradeRcvConnToDuplex :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError Int64)
upgradeRcvConnToDuplex db connId sq =
  getConn db connId $>>= \case
    (SomeConn _ RcvConnection {}) -> Right <$> addConnSndQueue_ db connId sq
    (SomeConn c _) -> pure . Left . SEBadConnType $ connType c

upgradeSndConnToDuplex :: DB.Connection -> ConnId -> RcvQueue -> IO (Either StoreError Int64)
upgradeSndConnToDuplex db connId rq =
  getConn db connId >>= \case
    Right (SomeConn _ SndConnection {}) -> Right <$> addConnRcvQueue_ db connId rq
    Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
    _ -> pure $ Left SEConnNotFound

addConnRcvQueue :: DB.Connection -> ConnId -> RcvQueue -> IO (Either StoreError Int64)
addConnRcvQueue db connId rq =
  getConn db connId >>= \case
    Right (SomeConn _ DuplexConnection {}) -> Right <$> addConnRcvQueue_ db connId rq
    Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
    _ -> pure $ Left SEConnNotFound

addConnRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO Int64
addConnRcvQueue_ db connId rq@RcvQueue {server} = do
  upsertServer_ db server
  insertRcvQueue_ db connId rq

addConnSndQueue :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError Int64)
addConnSndQueue db connId sq =
  getConn db connId >>= \case
    Right (SomeConn _ DuplexConnection {}) -> Right <$> addConnSndQueue_ db connId sq
    Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
    _ -> pure $ Left SEConnNotFound

addConnSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO Int64
addConnSndQueue_ db connId sq@SndQueue {server} = do
  upsertServer_ db server
  insertSndQueue_ db connId sq

setRcvQueueStatus :: DB.Connection -> RcvQueue -> QueueStatus -> IO ()
setRcvQueueStatus db RcvQueue {rcvId, server = ProtocolServer {host, port}} status =
  -- ? return error if queue does not exist?
  DB.executeNamed
    db
    [sql|
      UPDATE rcv_queues
      SET status = :status
      WHERE host = :host AND port = :port AND rcv_id = :rcv_id;
    |]
    [":status" := status, ":host" := host, ":port" := port, ":rcv_id" := rcvId]

setRcvQueueConfirmedE2E :: DB.Connection -> RcvQueue -> C.DhSecretX25519 -> Version -> IO ()
setRcvQueueConfirmedE2E db RcvQueue {rcvId, server = ProtocolServer {host, port}} e2eDhSecret smpClientVersion =
  DB.executeNamed
    db
    [sql|
      UPDATE rcv_queues
      SET e2e_dh_secret = :e2e_dh_secret,
          status = :status,
          smp_client_version = :smp_client_version
      WHERE host = :host AND port = :port AND rcv_id = :rcv_id
    |]
    [ ":status" := Confirmed,
      ":e2e_dh_secret" := e2eDhSecret,
      ":smp_client_version" := smpClientVersion,
      ":host" := host,
      ":port" := port,
      ":rcv_id" := rcvId
    ]

setSndQueueStatus :: DB.Connection -> SndQueue -> QueueStatus -> IO ()
setSndQueueStatus db SndQueue {sndId, server = ProtocolServer {host, port}} status =
  -- ? return error if queue does not exist?
  DB.executeNamed
    db
    [sql|
      UPDATE snd_queues
      SET status = :status
      WHERE host = :host AND port = :port AND snd_id = :snd_id;
    |]
    [":status" := status, ":host" := host, ":port" := port, ":snd_id" := sndId]

setRcvQueuePrimary :: DB.Connection -> ConnId -> RcvQueue -> IO ()
setRcvQueuePrimary db connId RcvQueue {dbQueueId} = do
  DB.execute db "UPDATE rcv_queues SET rcv_primary = ? WHERE conn_id = ?" (False, connId)
  DB.execute
    db
    "UPDATE rcv_queues SET rcv_primary = ?, replace_rcv_queue_id = ? WHERE conn_id = ? AND rcv_queue_id = ?"
    (True, Nothing :: Maybe Int64, connId, dbQueueId)

setSndQueuePrimary :: DB.Connection -> ConnId -> SndQueue -> IO ()
setSndQueuePrimary db connId SndQueue {dbQueueId} = do
  DB.execute db "UPDATE snd_queues SET snd_primary = ? WHERE conn_id = ?" (False, connId)
  DB.execute
    db
    "UPDATE snd_queues SET snd_primary = ?, replace_snd_queue_id = ? WHERE conn_id = ? AND snd_queue_id = ?"
    (True, Nothing :: Maybe Int64, connId, dbQueueId)

incRcvDeleteErrors :: DB.Connection -> RcvQueue -> IO ()
incRcvDeleteErrors db RcvQueue {connId, dbQueueId} =
  DB.execute db "UPDATE rcv_queues SET delete_errors = delete_errors + 1 WHERE conn_id = ? AND rcv_queue_id = ?" (connId, dbQueueId)

deleteConnRcvQueue :: DB.Connection -> RcvQueue -> IO ()
deleteConnRcvQueue db RcvQueue {connId, dbQueueId} =
  DB.execute db "DELETE FROM rcv_queues WHERE conn_id = ? AND rcv_queue_id = ?" (connId, dbQueueId)

deleteConnSndQueue :: DB.Connection -> ConnId -> SndQueue -> IO ()
deleteConnSndQueue db connId SndQueue {dbQueueId} = do
  DB.execute db "DELETE FROM snd_queues WHERE conn_id = ? AND snd_queue_id = ?" (connId, dbQueueId)
  DB.execute db "DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ?" (connId, dbQueueId)

getPrimaryRcvQueue :: DB.Connection -> ConnId -> IO (Either StoreError RcvQueue)
getPrimaryRcvQueue db connId =
  maybe (Left SEConnNotFound) (Right . L.head) <$> getRcvQueuesByConnId_ db connId

getRcvQueue :: DB.Connection -> ConnId -> SMPServer -> SMP.RecipientId -> IO (Either StoreError RcvQueue)
getRcvQueue db connId (SMPServer host port _) rcvId =
  firstRow toRcvQueue SEConnNotFound $
    DB.query db (rcvQueueQuery <> "WHERE q.conn_id = ? AND q.host = ? AND q.port = ? AND q.rcv_id = ?") (connId, host, port, rcvId)

setRcvQueueNtfCreds :: DB.Connection -> ConnId -> Maybe ClientNtfCreds -> IO ()
setRcvQueueNtfCreds db connId clientNtfCreds =
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET ntf_public_key = ?, ntf_private_key = ?, ntf_id = ?, rcv_ntf_dh_secret = ?
      WHERE conn_id = ?
    |]
    (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_, connId)
  where
    (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_) = case clientNtfCreds of
      Just ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret} -> (Just ntfPublicKey, Just ntfPrivateKey, Just notifierId, Just rcvNtfDhSecret)
      Nothing -> (Nothing, Nothing, Nothing, Nothing)

type SMPConfirmationRow = (SndPublicVerifyKey, C.PublicKeyX25519, ConnInfo, Maybe [SMPQueueInfo], Maybe Version)

smpConfirmation :: SMPConfirmationRow -> SMPConfirmation
smpConfirmation (senderKey, e2ePubKey, connInfo, smpReplyQueues_, smpClientVersion_) =
  SMPConfirmation
    { senderKey,
      e2ePubKey,
      connInfo,
      smpReplyQueues = fromMaybe [] smpReplyQueues_,
      smpClientVersion = fromMaybe 1 smpClientVersion_
    }

createConfirmation :: DB.Connection -> TVar ChaChaDRG -> NewConfirmation -> IO (Either StoreError ConfirmationId)
createConfirmation db gVar NewConfirmation {connId, senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues, smpClientVersion}, ratchetState} =
  createWithRandomId gVar $ \confirmationId ->
    DB.execute
      db
      [sql|
        INSERT INTO conn_confirmations
        (confirmation_id, conn_id, sender_key, e2e_snd_pub_key, ratchet_state, sender_conn_info, smp_reply_queues, smp_client_version, accepted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0);
      |]
      (confirmationId, connId, senderKey, e2ePubKey, ratchetState, connInfo, smpReplyQueues, smpClientVersion)

acceptConfirmation :: DB.Connection -> ConfirmationId -> ConnInfo -> IO (Either StoreError AcceptedConfirmation)
acceptConfirmation db confirmationId ownConnInfo = do
  DB.executeNamed
    db
    [sql|
      UPDATE conn_confirmations
      SET accepted = 1,
          own_conn_info = :own_conn_info
      WHERE confirmation_id = :confirmation_id;
    |]
    [ ":own_conn_info" := ownConnInfo,
      ":confirmation_id" := confirmationId
    ]
  firstRow confirmation SEConfirmationNotFound $
    DB.query
      db
      [sql|
        SELECT conn_id, ratchet_state, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
        FROM conn_confirmations
        WHERE confirmation_id = ?;
      |]
      (Only confirmationId)
  where
    confirmation ((connId, ratchetState) :. confRow) =
      AcceptedConfirmation
        { confirmationId,
          connId,
          senderConf = smpConfirmation confRow,
          ratchetState,
          ownConnInfo
        }

getAcceptedConfirmation :: DB.Connection -> ConnId -> IO (Either StoreError AcceptedConfirmation)
getAcceptedConfirmation db connId =
  firstRow confirmation SEConfirmationNotFound $
    DB.query
      db
      [sql|
        SELECT confirmation_id, ratchet_state, own_conn_info, sender_key, e2e_snd_pub_key, sender_conn_info, smp_reply_queues, smp_client_version
        FROM conn_confirmations
        WHERE conn_id = ? AND accepted = 1;
      |]
      (Only connId)
  where
    confirmation ((confirmationId, ratchetState, ownConnInfo) :. confRow) =
      AcceptedConfirmation
        { confirmationId,
          connId,
          senderConf = smpConfirmation confRow,
          ratchetState,
          ownConnInfo
        }

removeConfirmations :: DB.Connection -> ConnId -> IO ()
removeConfirmations db connId =
  DB.executeNamed
    db
    [sql|
      DELETE FROM conn_confirmations
      WHERE conn_id = :conn_id;
    |]
    [":conn_id" := connId]

setHandshakeVersion :: DB.Connection -> ConnId -> Version -> Bool -> IO ()
setHandshakeVersion db connId aVersion duplexHS =
  DB.execute db "UPDATE connections SET smp_agent_version = ?, duplex_handshake = ? WHERE conn_id = ?" (aVersion, duplexHS, connId)

createInvitation :: DB.Connection -> TVar ChaChaDRG -> NewInvitation -> IO (Either StoreError InvitationId)
createInvitation db gVar NewInvitation {contactConnId, connReq, recipientConnInfo} =
  createWithRandomId gVar $ \invitationId ->
    DB.execute
      db
      [sql|
        INSERT INTO conn_invitations
        (invitation_id,  contact_conn_id, cr_invitation, recipient_conn_info, accepted) VALUES (?, ?, ?, ?, 0);
      |]
      (invitationId, contactConnId, connReq, recipientConnInfo)

getInvitation :: DB.Connection -> InvitationId -> IO (Either StoreError Invitation)
getInvitation db invitationId =
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

acceptInvitation :: DB.Connection -> InvitationId -> ConnInfo -> IO ()
acceptInvitation db invitationId ownConnInfo =
  DB.executeNamed
    db
    [sql|
      UPDATE conn_invitations
      SET accepted = 1,
          own_conn_info = :own_conn_info
      WHERE invitation_id = :invitation_id
    |]
    [ ":own_conn_info" := ownConnInfo,
      ":invitation_id" := invitationId
    ]

unacceptInvitation :: DB.Connection -> InvitationId -> IO ()
unacceptInvitation db invitationId =
  DB.execute db "UPDATE conn_invitations SET accepted = 0, own_conn_info = NULL WHERE invitation_id = ?" (Only invitationId)

deleteInvitation :: DB.Connection -> ConnId -> InvitationId -> IO (Either StoreError ())
deleteInvitation db contactConnId invId =
  getConn db contactConnId $>>= \case
    SomeConn SCContact _ ->
      Right <$> DB.execute db "DELETE FROM conn_invitations WHERE contact_conn_id = ? AND invitation_id = ?" (contactConnId, invId)
    _ -> pure $ Left SEConnNotFound

updateRcvIds :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
updateRcvIds db connId = do
  (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash) <- retrieveLastIdsAndHashRcv_ db connId
  let internalId = InternalId $ unId lastInternalId + 1
      internalRcvId = InternalRcvId $ unRcvId lastInternalRcvId + 1
  updateLastIdsRcv_ db connId internalId internalRcvId
  pure (internalId, internalRcvId, lastExternalSndId, lastRcvHash)

createRcvMsg :: DB.Connection -> ConnId -> RcvQueue -> RcvMsgData -> IO ()
createRcvMsg db connId rq rcvMsgData = do
  insertRcvMsgBase_ db connId rcvMsgData
  insertRcvMsgDetails_ db connId rq rcvMsgData
  updateHashRcv_ db connId rcvMsgData

updateSndIds :: DB.Connection -> ConnId -> IO (InternalId, InternalSndId, PrevSndMsgHash)
updateSndIds db connId = do
  (lastInternalId, lastInternalSndId, prevSndHash) <- retrieveLastIdsAndHashSnd_ db connId
  let internalId = InternalId $ unId lastInternalId + 1
      internalSndId = InternalSndId $ unSndId lastInternalSndId + 1
  updateLastIdsSnd_ db connId internalId internalSndId
  pure (internalId, internalSndId, prevSndHash)

createSndMsg :: DB.Connection -> ConnId -> SndMsgData -> IO ()
createSndMsg db connId sndMsgData = do
  insertSndMsgBase_ db connId sndMsgData
  insertSndMsgDetails_ db connId sndMsgData
  updateHashSnd_ db connId sndMsgData

createSndMsgDelivery :: DB.Connection -> ConnId -> SndQueue -> InternalId -> IO ()
createSndMsgDelivery db connId SndQueue {dbQueueId} msgId =
  DB.execute db "INSERT INTO snd_message_deliveries (conn_id, snd_queue_id, internal_id) VALUES (?, ?, ?)" (connId, dbQueueId, msgId)

getPendingMsgData :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError (Maybe RcvQueue, PendingMsgData))
getPendingMsgData db connId msgId = do
  rq_ <- L.head <$$> getRcvQueuesByConnId_ db connId
  (rq_,) <$$> firstRow pendingMsgData SEMsgNotFound getMsgData_
  where
    getMsgData_ =
      DB.query
        db
        [sql|
          SELECT m.msg_type, m.msg_flags, m.msg_body, m.internal_ts
          FROM messages m
          JOIN snd_messages s ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
          WHERE m.conn_id = ? AND m.internal_id = ?
        |]
        (connId, msgId)
    pendingMsgData :: (AgentMessageType, Maybe MsgFlags, MsgBody, InternalTs) -> PendingMsgData
    pendingMsgData (msgType, msgFlags_, msgBody, internalTs) =
      let msgFlags = fromMaybe SMP.noMsgFlags msgFlags_
       in PendingMsgData {msgId, msgType, msgFlags, msgBody, internalTs}

getPendingMsgs :: DB.Connection -> ConnId -> SndQueue -> IO [InternalId]
getPendingMsgs db connId SndQueue {dbQueueId} =
  map fromOnly
    <$> DB.query db "SELECT internal_id FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ?" (connId, dbQueueId)

deletePendingMsgs :: DB.Connection -> ConnId -> SndQueue -> IO ()
deletePendingMsgs db connId SndQueue {dbQueueId} =
  DB.execute db "DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ?" (connId, dbQueueId)

setMsgUserAck :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError (RcvQueue, SMP.MsgId))
setMsgUserAck db connId agentMsgId = runExceptT $ do
  liftIO $ DB.execute db "UPDATE rcv_messages SET user_ack = ? WHERE conn_id = ? AND internal_id = ?" (True, connId, agentMsgId)
  (dbRcvId, srvMsgId) <-
    ExceptT . firstRow id SEMsgNotFound $
      DB.query db "SELECT rcv_queue_id, broker_id FROM rcv_messages WHERE conn_id = ? AND internal_id = ?" (connId, agentMsgId)
  rq <- ExceptT $ getRcvQueueById_ db connId dbRcvId
  pure (rq, srvMsgId)

getLastMsg :: DB.Connection -> ConnId -> SMP.MsgId -> IO (Maybe RcvMsg)
getLastMsg db connId msgId =
  maybeFirstRow rcvMsg $
    DB.query
      db
      [sql|
        SELECT
          r.internal_id, m.internal_ts, r.broker_id, r.broker_ts, r.external_snd_id, r.integrity,
          m.msg_body, r.user_ack
        FROM rcv_messages r
        JOIN messages m ON r.internal_id = m.internal_id
        JOIN connections c ON r.conn_id = c.conn_id AND c.last_internal_msg_id = r.internal_id
        WHERE r.conn_id = ? AND r.broker_id = ?
      |]
      (connId, msgId)
  where
    rcvMsg (agentMsgId, internalTs, brokerId, brokerTs, sndMsgId, integrity, msgBody, userAck) =
      let msgMeta = MsgMeta {recipient = (agentMsgId, internalTs), broker = (brokerId, brokerTs), sndMsgId, integrity}
       in RcvMsg {internalId = InternalId agentMsgId, msgMeta, msgBody, userAck}

deleteMsg :: DB.Connection -> ConnId -> InternalId -> IO ()
deleteMsg db connId msgId =
  DB.execute db "DELETE FROM messages WHERE conn_id = ? AND internal_id = ?;" (connId, msgId)

deleteSndMsgDelivery :: DB.Connection -> ConnId -> SndQueue -> InternalId -> IO ()
deleteSndMsgDelivery db connId SndQueue {dbQueueId} msgId = do
  DB.execute
    db
    "DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ? AND internal_id = ?"
    (connId, dbQueueId, msgId)
  (Only (cnt :: Int) : _) <- DB.query db "SELECT count(*) FROM snd_message_deliveries WHERE conn_id = ? AND internal_id = ?" (connId, msgId)
  when (cnt == 0) $ deleteMsg db connId msgId

createRatchetX3dhKeys :: DB.Connection -> ConnId -> C.PrivateKeyX448 -> C.PrivateKeyX448 -> IO ()
createRatchetX3dhKeys db connId x3dhPrivKey1 x3dhPrivKey2 =
  DB.execute db "INSERT INTO ratchets (conn_id, x3dh_priv_key_1, x3dh_priv_key_2) VALUES (?, ?, ?)" (connId, x3dhPrivKey1, x3dhPrivKey2)

getRatchetX3dhKeys :: DB.Connection -> ConnId -> IO (Either StoreError (C.PrivateKeyX448, C.PrivateKeyX448))
getRatchetX3dhKeys db connId =
  fmap hasKeys $
    firstRow id SEX3dhKeysNotFound $
      DB.query db "SELECT x3dh_priv_key_1, x3dh_priv_key_2 FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    hasKeys = \case
      Right (Just k1, Just k2) -> Right (k1, k2)
      _ -> Left SEX3dhKeysNotFound

createRatchet :: DB.Connection -> ConnId -> RatchetX448 -> IO ()
createRatchet db connId rc =
  DB.executeNamed
    db
    [sql|
      INSERT INTO ratchets (conn_id, ratchet_state)
      VALUES (:conn_id, :ratchet_state)
      ON CONFLICT (conn_id) DO UPDATE SET
        ratchet_state = :ratchet_state,
        x3dh_priv_key_1 = NULL,
        x3dh_priv_key_2 = NULL
    |]
    [":conn_id" := connId, ":ratchet_state" := rc]

getRatchet :: DB.Connection -> ConnId -> IO (Either StoreError RatchetX448)
getRatchet db connId =
  firstRow' ratchet SERatchetNotFound $ DB.query db "SELECT ratchet_state FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    ratchet = maybe (Left SERatchetNotFound) Right . fromOnly

getSkippedMsgKeys :: DB.Connection -> ConnId -> IO SkippedMsgKeys
getSkippedMsgKeys db connId =
  skipped <$> DB.query db "SELECT header_key, msg_n, msg_key FROM skipped_messages WHERE conn_id = ?" (Only connId)
  where
    skipped ms = foldl' addSkippedKey M.empty ms
    addSkippedKey smks (hk, msgN, mk) = M.alter (Just . addMsgKey) hk smks
      where
        addMsgKey = maybe (M.singleton msgN mk) (M.insert msgN mk)

updateRatchet :: DB.Connection -> ConnId -> RatchetX448 -> SkippedMsgDiff -> IO ()
updateRatchet db connId rc skipped = do
  DB.execute db "UPDATE ratchets SET ratchet_state = ? WHERE conn_id = ?" (rc, connId)
  case skipped of
    SMDNoChange -> pure ()
    SMDRemove hk msgN ->
      DB.execute db "DELETE FROM skipped_messages WHERE conn_id = ? AND header_key = ? AND msg_n = ?" (connId, hk, msgN)
    SMDAdd smks ->
      forM_ (M.assocs smks) $ \(hk, mks) ->
        forM_ (M.assocs mks) $ \(msgN, mk) ->
          DB.execute db "INSERT INTO skipped_messages (conn_id, header_key, msg_n, msg_key) VALUES (?, ?, ?, ?)" (connId, hk, msgN, mk)

createCommand :: DB.Connection -> ACorrId -> ConnId -> Maybe SMPServer -> AgentCommand -> IO AsyncCmdId
createCommand db corrId connId srv cmd = do
  DB.execute
    db
    "INSERT INTO commands (host, port, corr_id, conn_id, command_tag, command) VALUES (?,?,?,?,?,?)"
    (host_, port_, corrId, connId, agentCommandTag cmd, cmd)
  insertedRowId db
  where
    (host_, port_) =
      case srv of
        Just (SMPServer host port _) -> (Just host, Just port)
        _ -> (Nothing, Nothing)

insertedRowId :: DB.Connection -> IO Int64
insertedRowId db = fromOnly . head <$> DB.query_ db "SELECT last_insert_rowid()"

getPendingCommands :: DB.Connection -> ConnId -> IO [(Maybe SMPServer, [AsyncCmdId])]
getPendingCommands db connId = do
  map (\ids -> (fst $ head ids, map snd ids)) . groupBy ((==) `on` fst) . map srvCmdId
    <$> DB.query
      db
      [sql|
        SELECT c.host, c.port, s.key_hash, c.command_id
        FROM commands c
        LEFT JOIN servers s ON s.host = c.host AND s.port = c.port
        WHERE conn_id = ?
        ORDER BY c.host, c.port, c.command_id ASC
      |]
      (Only connId)
  where
    srvCmdId (host, port, keyHash, cmdId) = (SMPServer <$> host <*> port <*> keyHash, cmdId)

getPendingCommand :: DB.Connection -> AsyncCmdId -> IO (Either StoreError PendingCommand)
getPendingCommand db msgId = do
  firstRow pendingCommand SECmdNotFound $
    DB.query
      db
      [sql|
        SELECT c.corr_id, cs.user_id, c.conn_id, c.command
        FROM commands c
        JOIN connections cs USING (conn_id)
        WHERE c.command_id = ?
      |]
      (Only msgId)
  where
    pendingCommand (corrId, userId, connId, command) = PendingCommand {corrId, userId, connId, command}

deleteCommand :: DB.Connection -> AsyncCmdId -> IO ()
deleteCommand db cmdId =
  DB.execute db "DELETE FROM commands WHERE command_id = ?" (Only cmdId)

createNtfToken :: DB.Connection -> NtfToken -> IO ()
createNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = srv@ProtocolServer {host, port}, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey), ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode} = do
  upsertNtfServer_ db srv
  DB.execute
    db
    [sql|
      INSERT INTO ntf_tokens
        (provider, device_token, ntf_host, ntf_port, tkn_id, tkn_pub_key, tkn_priv_key, tkn_pub_dh_key, tkn_priv_dh_key, tkn_dh_secret, tkn_status, tkn_action, ntf_mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    |]
    ((provider, token, host, port, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode))

getSavedNtfToken :: DB.Connection -> IO (Maybe NtfToken)
getSavedNtfToken db = do
  maybeFirstRow ntfToken $
    DB.query_
      db
      [sql|
        SELECT s.ntf_host, s.ntf_port, s.ntf_key_hash,
          t.provider, t.device_token, t.tkn_id, t.tkn_pub_key, t.tkn_priv_key, t.tkn_pub_dh_key, t.tkn_priv_dh_key, t.tkn_dh_secret,
          t.tkn_status, t.tkn_action, t.ntf_mode
        FROM ntf_tokens t
        JOIN ntf_servers s USING (ntf_host, ntf_port)
      |]
  where
    ntfToken ((host, port, keyHash) :. (provider, dt, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode_)) =
      let ntfServer = NtfServer host port keyHash
          ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey)
          ntfMode = fromMaybe NMPeriodic ntfMode_
       in NtfToken {deviceToken = DeviceToken provider dt, ntfServer, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys, ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode}

updateNtfTokenRegistration :: DB.Connection -> NtfToken -> NtfTokenId -> C.DhSecretX25519 -> IO ()
updateNtfTokenRegistration db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} tknId ntfDhSecret = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET tkn_id = ?, tkn_dh_secret = ?, tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (tknId, ntfDhSecret, NTRegistered, Nothing :: Maybe NtfTknAction, updatedAt, provider, token, host, port)

updateDeviceToken :: DB.Connection -> NtfToken -> DeviceToken -> IO ()
updateDeviceToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} (DeviceToken toProvider toToken) = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET provider = ?, device_token = ?, tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (toProvider, toToken, NTRegistered, Nothing :: Maybe NtfTknAction, updatedAt, provider, token, host, port)

updateNtfMode :: DB.Connection -> NtfToken -> NotificationsMode -> IO ()
updateNtfMode db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} ntfMode = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET ntf_mode = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (ntfMode, updatedAt, provider, token, host, port)

updateNtfToken :: DB.Connection -> NtfToken -> NtfTknStatus -> Maybe NtfTknAction -> IO ()
updateNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} tknStatus tknAction = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_tokens
      SET tkn_status = ?, tkn_action = ?, updated_at = ?
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (tknStatus, tknAction, updatedAt, provider, token, host, port)

removeNtfToken :: DB.Connection -> NtfToken -> IO ()
removeNtfToken db NtfToken {deviceToken = DeviceToken provider token, ntfServer = ProtocolServer {host, port}} =
  DB.execute
    db
    [sql|
      DELETE FROM ntf_tokens
      WHERE provider = ? AND device_token = ? AND ntf_host = ? AND ntf_port = ?
    |]
    (provider, token, host, port)

getNtfSubscription :: DB.Connection -> ConnId -> IO (Maybe (NtfSubscription, Maybe (NtfSubAction, NtfActionTs)))
getNtfSubscription db connId =
  maybeFirstRow ntfSubscription $
    DB.query
      db
      [sql|
        SELECT s.host, s.port, s.key_hash, ns.ntf_host, ns.ntf_port, ns.ntf_key_hash,
          nsb.smp_ntf_id, nsb.ntf_sub_id, nsb.ntf_sub_status, nsb.ntf_sub_action, nsb.ntf_sub_smp_action, nsb.ntf_sub_action_ts
        FROM ntf_subscriptions nsb
        JOIN servers s ON s.host = nsb.smp_host AND s.port = nsb.smp_port
        JOIN ntf_servers ns USING (ntf_host, ntf_port)
        WHERE nsb.conn_id = ?
      |]
      (Only connId)
  where
    ntfSubscription (smpHost, smpPort, smpKeyHash, ntfHost, ntfPort, ntfKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, ntfAction_, smpAction_, actionTs_) =
      let smpServer = SMPServer smpHost smpPort smpKeyHash
          ntfServer = NtfServer ntfHost ntfPort ntfKeyHash
          action = case (ntfAction_, smpAction_, actionTs_) of
            (Just ntfAction, Nothing, Just actionTs) -> Just (NtfSubNTFAction ntfAction, actionTs)
            (Nothing, Just smpAction, Just actionTs) -> Just (NtfSubSMPAction smpAction, actionTs)
            _ -> Nothing
       in (NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}, action)

createNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> IO ()
createNtfSubscription db ntfSubscription action = do
  let NtfSubscription {connId, smpServer = (SMPServer host port _), ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} = ntfSubscription
  actionTs <- liftIO getCurrentTime
  DB.execute
    db
    [sql|
      INSERT INTO ntf_subscriptions
        (conn_id, smp_host, smp_port, smp_ntf_id, ntf_host, ntf_port, ntf_sub_id,
          ntf_sub_status, ntf_sub_action, ntf_sub_smp_action, ntf_sub_action_ts)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
    |]
    ( (connId, host, port, ntfQueueId, ntfHost, ntfPort, ntfSubId)
        :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs)
    )
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

supervisorUpdateNtfSub :: DB.Connection -> NtfSubscription -> NtfSubAction -> IO ()
supervisorUpdateNtfSub db NtfSubscription {connId, ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} action = do
  ts <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_subscriptions
      SET smp_ntf_id = ?, ntf_host = ?, ntf_port = ?, ntf_sub_id = ?, ntf_sub_status = ?, ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
      WHERE conn_id = ?
    |]
    ((ntfQueueId, ntfHost, ntfPort, ntfSubId) :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, ts, True, ts, connId))
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

supervisorUpdateNtfAction :: DB.Connection -> ConnId -> NtfSubAction -> IO ()
supervisorUpdateNtfAction db connId action = do
  ts <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE ntf_subscriptions
      SET ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
      WHERE conn_id = ?
    |]
    (ntfSubAction, ntfSubSMPAction, ts, True, ts, connId)
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

updateNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> NtfActionTs -> IO ()
updateNtfSubscription db NtfSubscription {connId, ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} action actionTs = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor -> do
    updatedAt <- getCurrentTime
    if updatedBySupervisor
      then
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_sub_id = ?, ntf_sub_status = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          (ntfQueueId, ntfSubId, ntfSubStatus, False, updatedAt, connId)
      else
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_host = ?, ntf_port = ?, ntf_sub_id = ?, ntf_sub_status = ?, ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          ((ntfQueueId, ntfHost, ntfPort, ntfSubId) :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs, False, updatedAt, connId))
  where
    (ntfSubAction, ntfSubSMPAction) = ntfSubAndSMPAction action

setNullNtfSubscriptionAction :: DB.Connection -> ConnId -> IO ()
setNullNtfSubscriptionAction db connId = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor ->
    unless updatedBySupervisor $ do
      updatedAt <- getCurrentTime
      DB.execute
        db
        [sql|
          UPDATE ntf_subscriptions
          SET ntf_sub_action = ?, ntf_sub_smp_action = ?, ntf_sub_action_ts = ?, updated_by_supervisor = ?, updated_at = ?
          WHERE conn_id = ?
        |]
        (Nothing :: Maybe NtfSubNTFAction, Nothing :: Maybe NtfSubSMPAction, Nothing :: Maybe UTCTime, False, updatedAt, connId)

deleteNtfSubscription :: DB.Connection -> ConnId -> IO ()
deleteNtfSubscription db connId = do
  r <- maybeFirstRow fromOnly $ DB.query db "SELECT updated_by_supervisor FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)
  forM_ r $ \updatedBySupervisor -> do
    updatedAt <- getCurrentTime
    if updatedBySupervisor
      then
        DB.execute
          db
          [sql|
            UPDATE ntf_subscriptions
            SET smp_ntf_id = ?, ntf_sub_id = ?, ntf_sub_status = ?, updated_by_supervisor = ?, updated_at = ?
            WHERE conn_id = ?
          |]
          (Nothing :: Maybe SMP.NotifierId, Nothing :: Maybe NtfSubscriptionId, NASDeleted, False, updatedAt, connId)
      else DB.execute db "DELETE FROM ntf_subscriptions WHERE conn_id = ?" (Only connId)

getNextNtfSubNTFAction :: DB.Connection -> NtfServer -> IO (Maybe (NtfSubscription, NtfSubNTFAction, NtfActionTs))
getNextNtfSubNTFAction db ntfServer@(NtfServer ntfHost ntfPort _) = do
  maybeFirstRow ntfSubAction getNtfSubAction_ $>>= \a@(NtfSubscription {connId}, _, _) -> do
    DB.execute db "UPDATE ntf_subscriptions SET updated_by_supervisor = ? WHERE conn_id = ?" (False, connId)
    pure $ Just a
  where
    getNtfSubAction_ =
      DB.query
        db
        [sql|
          SELECT ns.conn_id, s.host, s.port, s.key_hash,
            ns.smp_ntf_id, ns.ntf_sub_id, ns.ntf_sub_status, ns.ntf_sub_action_ts, ns.ntf_sub_action
          FROM ntf_subscriptions ns
          JOIN servers s ON s.host = ns.smp_host AND s.port = ns.smp_port
          WHERE ns.ntf_host = ? AND ns.ntf_port = ? AND ns.ntf_sub_action IS NOT NULL
          ORDER BY ns.ntf_sub_action_ts ASC
          LIMIT 1
        |]
        (ntfHost, ntfPort)
    ntfSubAction (connId, smpHost, smpPort, smpKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, actionTs, action) =
      let smpServer = SMPServer smpHost smpPort smpKeyHash
          ntfSubscription = NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}
       in (ntfSubscription, action, actionTs)

getNextNtfSubSMPAction :: DB.Connection -> SMPServer -> IO (Maybe (NtfSubscription, NtfSubSMPAction, NtfActionTs))
getNextNtfSubSMPAction db smpServer@(SMPServer smpHost smpPort _) = do
  maybeFirstRow ntfSubAction getNtfSubAction_ $>>= \a@(NtfSubscription {connId}, _, _) -> do
    DB.execute db "UPDATE ntf_subscriptions SET updated_by_supervisor = ? WHERE conn_id = ?" (False, connId)
    pure $ Just a
  where
    getNtfSubAction_ =
      DB.query
        db
        [sql|
          SELECT ns.conn_id, s.ntf_host, s.ntf_port, s.ntf_key_hash,
            ns.smp_ntf_id, ns.ntf_sub_id, ns.ntf_sub_status, ns.ntf_sub_action_ts, ns.ntf_sub_smp_action
          FROM ntf_subscriptions ns
          JOIN ntf_servers s USING (ntf_host, ntf_port)
          WHERE ns.smp_host = ? AND ns.smp_port = ? AND ns.ntf_sub_smp_action IS NOT NULL AND ns.ntf_sub_action_ts IS NOT NULL
          ORDER BY ns.ntf_sub_action_ts ASC
          LIMIT 1
        |]
        (smpHost, smpPort)
    ntfSubAction (connId, ntfHost, ntfPort, ntfKeyHash, ntfQueueId, ntfSubId, ntfSubStatus, actionTs, action) =
      let ntfServer = NtfServer ntfHost ntfPort ntfKeyHash
          ntfSubscription = NtfSubscription {connId, smpServer, ntfQueueId, ntfServer, ntfSubId, ntfSubStatus}
       in (ntfSubscription, action, actionTs)

getActiveNtfToken :: DB.Connection -> IO (Maybe NtfToken)
getActiveNtfToken db =
  maybeFirstRow ntfToken $
    DB.query
      db
      [sql|
        SELECT s.ntf_host, s.ntf_port, s.ntf_key_hash,
          t.provider, t.device_token, t.tkn_id, t.tkn_pub_key, t.tkn_priv_key, t.tkn_pub_dh_key, t.tkn_priv_dh_key, t.tkn_dh_secret,
          t.tkn_status, t.tkn_action, t.ntf_mode
        FROM ntf_tokens t
        JOIN ntf_servers s USING (ntf_host, ntf_port)
        WHERE t.tkn_status = ?
      |]
      (Only NTActive)
  where
    ntfToken ((host, port, keyHash) :. (provider, dt, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhPubKey, ntfDhPrivKey, ntfDhSecret) :. (ntfTknStatus, ntfTknAction, ntfMode_)) =
      let ntfServer = NtfServer host port keyHash
          ntfDhKeys = (ntfDhPubKey, ntfDhPrivKey)
          ntfMode = fromMaybe NMPeriodic ntfMode_
       in NtfToken {deviceToken = DeviceToken provider dt, ntfServer, ntfTokenId, ntfPubKey, ntfPrivKey, ntfDhKeys, ntfDhSecret, ntfTknStatus, ntfTknAction, ntfMode}

getNtfRcvQueue :: DB.Connection -> SMPQueueNtf -> IO (Either StoreError (ConnId, RcvNtfDhSecret))
getNtfRcvQueue db SMPQueueNtf {smpServer = (SMPServer host port _), notifierId} =
  firstRow' res SEConnNotFound $
    DB.query
      db
      [sql|
        SELECT conn_id, rcv_ntf_dh_secret
        FROM rcv_queues
        WHERE host = ? AND port = ? AND ntf_id = ?
      |]
      (host, port, notifierId)
  where
    res (connId, Just rcvNtfDhSecret) = Right (connId, rcvNtfDhSecret)
    res _ = Left SEConnNotFound

setConnectionNtfs :: DB.Connection -> ConnId -> Bool -> IO ()
setConnectionNtfs db connId enableNtfs =
  DB.execute db "UPDATE connections SET enable_ntfs = ? WHERE conn_id = ?" (enableNtfs, connId)

-- * Auxiliary helpers

instance ToField QueueStatus where toField = toField . serializeQueueStatus

instance FromField QueueStatus where fromField = fromTextField_ queueStatusT

instance ToField InternalRcvId where toField (InternalRcvId x) = toField x

instance FromField InternalRcvId where fromField x = InternalRcvId <$> fromField x

instance ToField InternalSndId where toField (InternalSndId x) = toField x

instance FromField InternalSndId where fromField x = InternalSndId <$> fromField x

instance ToField InternalId where toField (InternalId x) = toField x

instance FromField InternalId where fromField x = InternalId <$> fromField x

instance ToField AgentMessageType where toField = toField . smpEncode

instance FromField AgentMessageType where fromField = blobFieldParser smpP

instance ToField MsgIntegrity where toField = toField . strEncode

instance FromField MsgIntegrity where fromField = blobFieldParser strP

instance ToField SMPQueueUri where toField = toField . strEncode

instance FromField SMPQueueUri where fromField = blobFieldParser strP

instance ToField AConnectionRequestUri where toField = toField . strEncode

instance FromField AConnectionRequestUri where fromField = blobFieldParser strP

instance ConnectionModeI c => ToField (ConnectionRequestUri c) where toField = toField . strEncode

instance (E.Typeable c, ConnectionModeI c) => FromField (ConnectionRequestUri c) where fromField = blobFieldParser strP

instance ToField ConnectionMode where toField = toField . decodeLatin1 . strEncode

instance FromField ConnectionMode where fromField = fromTextField_ connModeT

instance ToField (SConnectionMode c) where toField = toField . connMode

instance FromField AConnectionMode where fromField = fromTextField_ $ fmap connMode' . connModeT

instance ToField MsgFlags where toField = toField . decodeLatin1 . smpEncode

instance FromField MsgFlags where fromField = fromTextField_ $ eitherToMaybe . smpDecode . encodeUtf8

instance ToField [SMPQueueInfo] where toField = toField . smpEncodeList

instance FromField [SMPQueueInfo] where fromField = blobFieldParser smpListP

instance ToField (NonEmpty TransportHost) where toField = toField . decodeLatin1 . strEncode

instance FromField (NonEmpty TransportHost) where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField AgentCommand where toField = toField . strEncode

instance FromField AgentCommand where fromField = blobFieldParser strP

instance ToField AgentCommandTag where toField = toField . strEncode

instance FromField AgentCommandTag where fromField = blobFieldParser strP

listToEither :: e -> [a] -> Either e a
listToEither _ (x : _) = Right x
listToEither e _ = Left e

firstRow :: (a -> b) -> e -> IO [a] -> IO (Either e b)
firstRow f e a = second f . listToEither e <$> a

maybeFirstRow :: Functor f => (a -> b) -> f [a] -> f (Maybe b)
maybeFirstRow f q = fmap f . listToMaybe <$> q

firstRow' :: (a -> Either e b) -> e -> IO [a] -> IO (Either e b)
firstRow' f e a = (f <=< listToEither e) <$> a

{- ORMOLU_DISABLE -}
-- SQLite.Simple only has these up to 10 fields, which is insufficient for some of our queries
instance (FromField a, FromField b, FromField c, FromField d, FromField e,
          FromField f, FromField g, FromField h, FromField i, FromField j,
          FromField k) =>
  FromRow (a,b,c,d,e,f,g,h,i,j,k) where
  fromRow = (,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
                         <*> field <*> field <*> field <*> field <*> field
                         <*> field

instance (FromField a, FromField b, FromField c, FromField d, FromField e,
          FromField f, FromField g, FromField h, FromField i, FromField j,
          FromField k, FromField l) =>
  FromRow (a,b,c,d,e,f,g,h,i,j,k,l) where
  fromRow = (,,,,,,,,,,,) <$> field <*> field <*> field <*> field <*> field
                          <*> field <*> field <*> field <*> field <*> field
                          <*> field <*> field

instance (ToField a, ToField b, ToField c, ToField d, ToField e, ToField f,
          ToField g, ToField h, ToField i, ToField j, ToField k, ToField l) =>
  ToRow (a,b,c,d,e,f,g,h,i,j,k,l) where
  toRow (a,b,c,d,e,f,g,h,i,j,k,l) =
    [ toField a, toField b, toField c, toField d, toField e, toField f,
      toField g, toField h, toField i, toField j, toField k, toField l
    ]

{- ORMOLU_ENABLE -}

-- * Server upsert helper

upsertServer_ :: DB.Connection -> SMPServer -> IO ()
upsertServer_ dbConn ProtocolServer {host, port, keyHash} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO servers (host, port, key_hash) VALUES (:host,:port,:key_hash)
      ON CONFLICT (host, port) DO UPDATE SET
        host=excluded.host,
        port=excluded.port,
        key_hash=excluded.key_hash;
    |]
    [":host" := host, ":port" := port, ":key_hash" := keyHash]

upsertNtfServer_ :: DB.Connection -> NtfServer -> IO ()
upsertNtfServer_ db ProtocolServer {host, port, keyHash} = do
  DB.executeNamed
    db
    [sql|
      INSERT INTO ntf_servers (ntf_host, ntf_port, ntf_key_hash) VALUES (:host,:port,:key_hash)
      ON CONFLICT (ntf_host, ntf_port) DO UPDATE SET
        ntf_host=excluded.ntf_host,
        ntf_port=excluded.ntf_port,
        ntf_key_hash=excluded.ntf_key_hash;
    |]
    [":host" := host, ":port" := port, ":key_hash" := keyHash]

-- * createRcvConn helpers

insertRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> IO Int64
insertRcvQueue_ db connId' RcvQueue {..} = do
  qId <- newQueueId_ <$> DB.query db "SELECT rcv_queue_id FROM rcv_queues WHERE conn_id = ? ORDER BY rcv_queue_id DESC LIMIT 1" (Only connId')
  DB.execute
    db
    [sql|
      INSERT INTO rcv_queues
        (host, port, rcv_id, conn_id, rcv_private_key, rcv_dh_secret, e2e_priv_key, e2e_dh_secret, snd_id, status, rcv_queue_id, rcv_primary, replace_rcv_queue_id, smp_client_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((host server, port server, rcvId, connId', rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret) :. (sndId, status, qId, primary, dbReplaceQueueId, smpClientVersion))
  pure qId

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO Int64
insertSndQueue_ db connId' SndQueue {..} = do
  qId <- newQueueId_ <$> DB.query db "SELECT snd_queue_id FROM snd_queues WHERE conn_id = ? ORDER BY snd_queue_id DESC LIMIT 1" (Only connId')
  DB.execute
    db
    [sql|
      INSERT INTO snd_queues
        (host, port, snd_id, conn_id, snd_public_key, snd_private_key, e2e_pub_key, e2e_dh_secret, status, snd_queue_id, snd_primary, replace_snd_queue_id, smp_client_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((host server, port server, sndId, connId', sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret) :. (status, qId, primary, dbReplaceQueueId, smpClientVersion))
  pure qId

newQueueId_ :: [Only Int64] -> Int64
newQueueId_ [] = 1
newQueueId_ (Only maxId : _) = maxId + 1

-- * getConn helpers

getConn :: DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getConn = getAnyConn False

getDeletedConn :: DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getDeletedConn = getAnyConn True

getAnyConn :: Bool -> DB.Connection -> ConnId -> IO (Either StoreError SomeConn)
getAnyConn deleted' dbConn connId =
  getConnData dbConn connId >>= \case
    Nothing -> pure $ Left SEConnNotFound
    Just (cData@ConnData {deleted}, cMode)
      | deleted /= deleted' -> pure $ Left SEConnNotFound
      | otherwise -> do
        rQ <- getRcvQueuesByConnId_ dbConn connId
        sQ <- getSndQueuesByConnId_ dbConn connId
        pure $ case (rQ, sQ, cMode) of
          (Just rqs, Just sqs, CMInvitation) -> Right $ SomeConn SCDuplex (DuplexConnection cData rqs sqs)
          (Just (rq :| _), Nothing, CMInvitation) -> Right $ SomeConn SCRcv (RcvConnection cData rq)
          (Nothing, Just (sq :| _), CMInvitation) -> Right $ SomeConn SCSnd (SndConnection cData sq)
          (Just (rq :| _), Nothing, CMContact) -> Right $ SomeConn SCContact (ContactConnection cData rq)
          (Nothing, Nothing, _) -> Right $ SomeConn SCNew (NewConnection cData)
          _ -> Left SEConnNotFound

getConns :: DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]
getConns = getAnyConns_ False

getDeletedConns :: DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]
getDeletedConns = getAnyConns_ True

getAnyConns_ :: Bool -> DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]
getAnyConns_ deleted' db connIds = forM connIds $ E.handle handleDBError . getAnyConn deleted' db
  where
    handleDBError :: E.SomeException -> IO (Either StoreError SomeConn)
    handleDBError = pure . Left . SEInternal . bshow

getConnData :: DB.Connection -> ConnId -> IO (Maybe (ConnData, ConnectionMode))
getConnData dbConn connId' =
  maybeFirstRow cData $ DB.query dbConn "SELECT user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake, deleted FROM connections WHERE conn_id = ?;" (Only connId')
  where
    cData (userId, connId, cMode, connAgentVersion, enableNtfs_, duplexHandshake, deleted) = (ConnData {userId, connId, connAgentVersion, enableNtfs = fromMaybe True enableNtfs_, duplexHandshake, deleted}, cMode)

setConnDeleted :: DB.Connection -> ConnId -> IO ()
setConnDeleted db connId = DB.execute db "UPDATE connections SET deleted = ? WHERE conn_id = ?" (True, connId)

getDeletedConnIds :: DB.Connection -> IO [ConnId]
getDeletedConnIds db = map fromOnly <$> DB.query db "SELECT conn_id FROM connections WHERE deleted = ?" (Only True)

-- | returns all connection queues, the first queue is the primary one
getRcvQueuesByConnId_ :: DB.Connection -> ConnId -> IO (Maybe (NonEmpty RcvQueue))
getRcvQueuesByConnId_ db connId =
  L.nonEmpty . sortBy primaryFirst . map toRcvQueue
    <$> DB.query db (rcvQueueQuery <> "WHERE q.conn_id = ?") (Only connId)
  where
    primaryFirst RcvQueue {primary = p, dbReplaceQueueId = i} RcvQueue {primary = p', dbReplaceQueueId = i'} =
      -- the current primary queue is ordered first, the next primary - second
      compare (Down p) (Down p') <> compare i i'

rcvQueueQuery :: Query
rcvQueueQuery =
  [sql|
    SELECT c.user_id, s.key_hash, q.conn_id, q.host, q.port, q.rcv_id, q.rcv_private_key, q.rcv_dh_secret,
      q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.status,
      q.rcv_queue_id, q.rcv_primary, q.replace_rcv_queue_id, q.smp_client_version, q.delete_errors,
      q.ntf_public_key, q.ntf_private_key, q.ntf_id, q.rcv_ntf_dh_secret
    FROM rcv_queues q
    JOIN servers s ON q.host = s.host AND q.port = s.port
    JOIN connections c ON q.conn_id = c.conn_id
  |]

toRcvQueue ::
  (UserId, C.KeyHash, ConnId, NonEmpty TransportHost, ServiceName, SMP.RecipientId, SMP.RcvPrivateSignKey, SMP.RcvDhSecret, C.PrivateKeyX25519, Maybe C.DhSecretX25519, SMP.SenderId, QueueStatus)
    :. (Int64, Bool, Maybe Int64, Maybe Version, Int)
    :. (Maybe SMP.NtfPublicVerifyKey, Maybe SMP.NtfPrivateSignKey, Maybe SMP.NotifierId, Maybe RcvNtfDhSecret) ->
  RcvQueue
toRcvQueue ((userId, keyHash, connId, host, port, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status) :. (dbQueueId, primary, dbReplaceQueueId, smpClientVersion_, deleteErrors) :. (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_)) =
  let server = SMPServer host port keyHash
      smpClientVersion = fromMaybe 1 smpClientVersion_
      clientNtfCreds = case (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_) of
        (Just ntfPublicKey, Just ntfPrivateKey, Just notifierId, Just rcvNtfDhSecret) -> Just $ ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
        _ -> Nothing
   in RcvQueue {userId, connId, server, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status, dbQueueId, primary, dbReplaceQueueId, smpClientVersion, clientNtfCreds, deleteErrors}

getRcvQueueById_ :: DB.Connection -> ConnId -> Int64 -> IO (Either StoreError RcvQueue)
getRcvQueueById_ db connId dbRcvId =
  firstRow toRcvQueue SEConnNotFound $
    DB.query db (rcvQueueQuery <> " WHERE q.conn_id = ? AND q.rcv_queue_id = ?") (connId, dbRcvId)

-- | returns all connection queues, the first queue is the primary one
getSndQueuesByConnId_ :: DB.Connection -> ConnId -> IO (Maybe (NonEmpty SndQueue))
getSndQueuesByConnId_ dbConn connId =
  L.nonEmpty . sortBy primaryFirst . map sndQueue
    <$> DB.query
      dbConn
      [sql|
        SELECT c.user_id, s.key_hash, q.host, q.port, q.snd_id, q.snd_public_key, q.snd_private_key, q.e2e_pub_key, q.e2e_dh_secret, q.status, q.snd_queue_id, q.snd_primary, q.replace_snd_queue_id, q.smp_client_version
        FROM snd_queues q
        JOIN servers s ON q.host = s.host AND q.port = s.port
        JOIN connections c ON q.conn_id = c.conn_id
        WHERE q.conn_id = ?;
      |]
      (Only connId)
  where
    sndQueue ((userId, keyHash, host, port, sndId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status) :. (dbQueueId, primary, dbReplaceQueueId, smpClientVersion)) =
      let server = SMPServer host port keyHash
       in SndQueue {userId, connId, server, sndId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status, dbQueueId, primary, dbReplaceQueueId, smpClientVersion}
    primaryFirst SndQueue {primary = p, dbReplaceQueueId = i} SndQueue {primary = p', dbReplaceQueueId = i'} =
      -- the current primary queue is ordered first, the next primary - second
      compare (Down p) (Down p') <> compare i i'

-- * updateRcvIds helpers

retrieveLastIdsAndHashRcv_ :: DB.Connection -> ConnId -> IO (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
retrieveLastIdsAndHashRcv_ dbConn connId = do
  [(lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)] <-
    DB.queryNamed
      dbConn
      [sql|
        SELECT last_internal_msg_id, last_internal_rcv_msg_id, last_external_snd_msg_id, last_rcv_msg_hash
        FROM connections
        WHERE conn_id = :conn_id;
      |]
      [":conn_id" := connId]
  return (lastInternalId, lastInternalRcvId, lastExternalSndId, lastRcvHash)

updateLastIdsRcv_ :: DB.Connection -> ConnId -> InternalId -> InternalRcvId -> IO ()
updateLastIdsRcv_ dbConn connId newInternalId newInternalRcvId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_rcv_msg_id = :last_internal_rcv_msg_id
      WHERE conn_id = :conn_id;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_rcv_msg_id" := newInternalRcvId,
      ":conn_id" := connId
    ]

-- * createRcvMsg helpers

insertRcvMsgBase_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
insertRcvMsgBase_ dbConn connId RcvMsgData {msgMeta, msgType, msgFlags, msgBody, internalRcvId} = do
  let MsgMeta {recipient = (internalId, internalTs)} = msgMeta
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body)
      VALUES
        (:conn_id,:internal_id,:internal_ts,:internal_rcv_id,            NULL,:msg_type,:msg_flags,:msg_body);
    |]
    [ ":conn_id" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_rcv_id" := internalRcvId,
      ":msg_type" := msgType,
      ":msg_flags" := msgFlags,
      ":msg_body" := msgBody
    ]

insertRcvMsgDetails_ :: DB.Connection -> ConnId -> RcvQueue -> RcvMsgData -> IO ()
insertRcvMsgDetails_ dbConn connId RcvQueue {dbQueueId} RcvMsgData {msgMeta, internalRcvId, internalHash, externalPrevSndHash} = do
  let MsgMeta {integrity, recipient, broker, sndMsgId} = msgMeta
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO rcv_messages
        ( conn_id, rcv_queue_id, internal_rcv_id, internal_id, external_snd_id,
          broker_id, broker_ts,
          internal_hash, external_prev_snd_hash, integrity)
      VALUES
        (:conn_id,:rcv_queue_id,:internal_rcv_id,:internal_id,:external_snd_id,
         :broker_id,:broker_ts,
         :internal_hash,:external_prev_snd_hash,:integrity);
    |]
    [ ":conn_id" := connId,
      ":rcv_queue_id" := dbQueueId,
      ":internal_rcv_id" := internalRcvId,
      ":internal_id" := fst recipient,
      ":external_snd_id" := sndMsgId,
      ":broker_id" := fst broker,
      ":broker_ts" := snd broker,
      ":internal_hash" := internalHash,
      ":external_prev_snd_hash" := externalPrevSndHash,
      ":integrity" := integrity
    ]

updateHashRcv_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connId RcvMsgData {msgMeta, internalHash, internalRcvId} =
  DB.executeNamed
    dbConn
    -- last_internal_rcv_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_external_snd_msg_id = :last_external_snd_msg_id,
          last_rcv_msg_hash = :last_rcv_msg_hash
      WHERE conn_id = :conn_id
        AND last_internal_rcv_msg_id = :last_internal_rcv_msg_id;
    |]
    [ ":last_external_snd_msg_id" := sndMsgId (msgMeta :: MsgMeta),
      ":last_rcv_msg_hash" := internalHash,
      ":conn_id" := connId,
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
        WHERE conn_id = :conn_id;
      |]
      [":conn_id" := connId]
  return (lastInternalId, lastInternalSndId, lastSndHash)

updateLastIdsSnd_ :: DB.Connection -> ConnId -> InternalId -> InternalSndId -> IO ()
updateLastIdsSnd_ dbConn connId newInternalId newInternalSndId =
  DB.executeNamed
    dbConn
    [sql|
      UPDATE connections
      SET last_internal_msg_id = :last_internal_msg_id,
          last_internal_snd_msg_id = :last_internal_snd_msg_id
      WHERE conn_id = :conn_id;
    |]
    [ ":last_internal_msg_id" := newInternalId,
      ":last_internal_snd_msg_id" := newInternalSndId,
      ":conn_id" := connId
    ]

-- * createSndMsg helpers

insertSndMsgBase_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgBase_ dbConn connId SndMsgData {..} = do
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO messages
        ( conn_id, internal_id, internal_ts, internal_rcv_id, internal_snd_id, msg_type, msg_flags, msg_body)
      VALUES
        (:conn_id,:internal_id,:internal_ts,            NULL,:internal_snd_id,:msg_type,:msg_flags,:msg_body);
    |]
    [ ":conn_id" := connId,
      ":internal_id" := internalId,
      ":internal_ts" := internalTs,
      ":internal_snd_id" := internalSndId,
      ":msg_type" := msgType,
      ":msg_flags" := msgFlags,
      ":msg_body" := msgBody
    ]

insertSndMsgDetails_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
insertSndMsgDetails_ dbConn connId SndMsgData {..} =
  DB.executeNamed
    dbConn
    [sql|
      INSERT INTO snd_messages
        ( conn_id, internal_snd_id, internal_id, internal_hash, previous_msg_hash)
      VALUES
        (:conn_id,:internal_snd_id,:internal_id,:internal_hash,:previous_msg_hash);
    |]
    [ ":conn_id" := connId,
      ":internal_snd_id" := internalSndId,
      ":internal_id" := internalId,
      ":internal_hash" := internalHash,
      ":previous_msg_hash" := prevMsgHash
    ]

updateHashSnd_ :: DB.Connection -> ConnId -> SndMsgData -> IO ()
updateHashSnd_ dbConn connId SndMsgData {..} =
  DB.executeNamed
    dbConn
    -- last_internal_snd_msg_id equality check prevents race condition in case next id was reserved
    [sql|
      UPDATE connections
      SET last_snd_msg_hash = :last_snd_msg_hash
      WHERE conn_id = :conn_id
        AND last_internal_snd_msg_id = :last_internal_snd_msg_id;
    |]
    [ ":last_snd_msg_hash" := internalHash,
      ":conn_id" := connId,
      ":last_internal_snd_msg_id" := internalSndId
    ]

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
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> pure . Left . SEInternal $ bshow e

randomId :: TVar ChaChaDRG -> Int -> IO ByteString
randomId gVar n = U.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)

ntfSubAndSMPAction :: NtfSubAction -> (Maybe NtfSubNTFAction, Maybe NtfSubSMPAction)
ntfSubAndSMPAction (NtfSubNTFAction action) = (Just action, Nothing)
ntfSubAndSMPAction (NtfSubSMPAction action) = (Nothing, Just action)

createRcvFile :: FileDescription -> IO ()
createRcvFile fd = do
  -- insert into rcv_file_chunk_replicas
  -- insert into rcv_file_chunks
  -- insert into rcv_files
  undefined

getRcvFile :: Int64 -> IO (Either StoreError RcvFileDescription)
getRcvFile fileId = do
  -- select from rcv_file_chunk_replicas
  -- select from rcv_file_chunks
  -- select from rcv_files
  -- / join?
  undefined

updateRcvFileChunkReplicaReceived :: Int64 -> IO ()
updateRcvFileChunkReplicaReceived replicaId = do
  -- update rcv_file_chunk_replicas
  undefined

updateRcvFileChunkReplicaRetries :: Int64 -> IO ()
updateRcvFileChunkReplicaRetries replicaId = do
  -- update rcv_file_chunk_replicas
  undefined

updateRcvFile :: Int64 -> IO ()
updateRcvFile replicaId = do
  -- update rcv_files - completed, temp_path, save_path
  undefined

getUnreceivedRcvFiles :: IO [RcvFileDescription]
getUnreceivedRcvFiles = do
  -- get unique file ids from rcv_files where complete = false
  -- getRcvFile for each file id
  undefined
