{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
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
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite
  ( SQLiteStore (..),
    MigrationConfirmation (..),
    MigrationError (..),
    UpMigration (..),
    createSQLiteStore,
    connectSQLiteStore,
    closeSQLiteStore,
    openSQLiteStore,
    sqlString,
    execSQL,
    upMigration, -- used in tests

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
    setConnAgentVersion,
    getDeletedConnIds,
    setConnRatchetSync,
    addProcessedRatchetKeyHash,
    checkRatchetKeyHashExists,
    deleteRatchetKeyHashesExpired,
    getRcvConn,
    getRcvQueueById,
    getSndQueueById,
    deleteConn,
    upgradeRcvConnToDuplex,
    upgradeSndConnToDuplex,
    addConnRcvQueue,
    addConnSndQueue,
    setRcvQueueStatus,
    setRcvSwitchStatus,
    setRcvQueueDeleted,
    setRcvQueueConfirmedE2E,
    setSndQueueStatus,
    setSndSwitchStatus,
    setRcvQueuePrimary,
    setSndQueuePrimary,
    deleteConnRcvQueue,
    incRcvDeleteErrors,
    deleteConnSndQueue,
    getPrimaryRcvQueue,
    getRcvQueue,
    getDeletedRcvQueue,
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
    getSndMsgViaRcpt,
    updateSndMsgRcpt,
    getPendingMsgData,
    updatePendingMsgRIState,
    getPendingMsgs,
    deletePendingMsgs,
    setMsgUserAck,
    getRcvMsg,
    getLastMsg,
    checkRcvMsgHashExists,
    deleteMsg,
    deleteDeliveredSndMsg,
    deleteSndMsgDelivery,
    deleteRcvMsgHashesExpired,
    deleteSndMsgsExpired,
    -- Double ratchet persistence
    createRatchetX3dhKeys,
    getRatchetX3dhKeys,
    createRatchetX3dhKeys',
    getRatchetX3dhKeys',
    setRatchetX3dhKeys,
    createRatchet,
    deleteRatchet,
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

    -- * File transfer

    -- Rcv files
    createRcvFile,
    getRcvFile,
    getRcvFileByEntityId,
    updateRcvChunkReplicaDelay,
    updateRcvFileChunkReceived,
    updateRcvFileStatus,
    updateRcvFileError,
    updateRcvFileComplete,
    updateRcvFileNoTmpPath,
    updateRcvFileDeleted,
    deleteRcvFile',
    getNextRcvChunkToDownload,
    getNextRcvFileToDecrypt,
    getPendingRcvFilesServers,
    getCleanupRcvFilesTmpPaths,
    getCleanupRcvFilesDeleted,
    getRcvFilesExpired,
    -- Snd files
    createSndFile,
    getSndFile,
    getSndFileByEntityId,
    getNextSndFileToPrepare,
    updateSndFileError,
    updateSndFileStatus,
    updateSndFileEncrypted,
    updateSndFileComplete,
    updateSndFileNoPrefixPath,
    updateSndFileDeleted,
    deleteSndFile',
    getSndFileDeleted,
    createSndFileReplica,
    getNextSndChunkToUpload,
    updateSndChunkReplicaDelay,
    addSndChunkReplicaRecipients,
    updateSndChunkReplicaStatus,
    getPendingSndFilesServers,
    getCleanupSndFilesPrefixPaths,
    getCleanupSndFilesDeleted,
    getSndFilesExpired,
    createDeletedSndChunkReplica,
    getNextDeletedSndChunkReplica,
    updateDeletedSndChunkReplicaDelay,
    deleteDeletedSndChunkReplica,
    getPendingDelFilesServers,
    deleteDeletedSndChunkReplicasExpired,

    -- * utilities
    withConnection,
    withTransaction,
    withTransactionCtx,
    firstRow,
    firstRow',
    maybeFirstRow,
  )
where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson.TH as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import Data.Char (toLower)
import Data.Functor (($>))
import Data.IORef
import Data.Int (Int64)
import Data.List (foldl', intercalate, sortBy)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Word (Word32)
import Database.SQLite.Simple (FromRow (..), NamedParam (..), Only (..), Query (..), SQLError, ToRow (..), field, (:.) (..))
import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import qualified Database.SQLite3 as SQLite3
import Network.Socket (ServiceName)
import Simplex.FileTransfer.Client (XFTPChunkSpec (..))
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.FileTransfer.Types
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval (RI2State (..))
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Common
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store.SQLite.Migrations (DownMigration (..), MTRError, Migration (..), MigrationsToRun (..), mtrErrorDescription)
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs (..))
import Simplex.Messaging.Crypto.Ratchet (RatchetX448, SkippedMsgDiff (..), SkippedMsgKeys)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfSubscriptionId, NtfTknStatus (..), NtfTokenId, SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (blobFieldParser, defaultJSON, dropPrefix, fromTextField_, sumTypeJSON)
import Simplex.Messaging.Protocol
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (bshow, eitherToMaybe, groupOn, ifM, ($>>=), (<$$>))
import Simplex.Messaging.Version
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hFlush, stdout)
import UnliftIO.Exception (bracketOnError, onException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- * SQLite Store implementation

data MigrationError
  = MEUpgrade {upMigrations :: [UpMigration]}
  | MEDowngrade {downMigrations :: [String]}
  | MigrationError {mtrError :: MTRError}
  deriving (Eq, Show)

migrationErrorDescription :: MigrationError -> String
migrationErrorDescription = \case
  MEUpgrade ums ->
    "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map upName ums)
  MEDowngrade dms ->
    "Database version is newer than the app.\nConfirm to back up and downgrade using these migrations: " <> intercalate ", " dms
  MigrationError err -> mtrErrorDescription err

data UpMigration = UpMigration {upName :: String, withDown :: Bool}
  deriving (Eq, Show)

upMigration :: Migration -> UpMigration
upMigration Migration {name, down} = UpMigration name $ isJust down

data MigrationConfirmation = MCYesUp | MCYesUpDown | MCConsole | MCError
  deriving (Eq, Show)

instance StrEncoding MigrationConfirmation where
  strEncode = \case
    MCYesUp -> "yesUp"
    MCYesUpDown -> "yesUpDown"
    MCConsole -> "console"
    MCError -> "error"
  strP =
    A.takeByteString >>= \case
      "yesUp" -> pure MCYesUp
      "yesUpDown" -> pure MCYesUpDown
      "console" -> pure MCConsole
      "error" -> pure MCError
      _ -> fail "invalid MigrationConfirmation"

createSQLiteStore :: FilePath -> String -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError SQLiteStore)
createSQLiteStore dbFilePath dbKey migrations confirmMigrations = do
  let dbDir = takeDirectory dbFilePath
  createDirectoryIfMissing True dbDir
  st <- connectSQLiteStore dbFilePath dbKey
  r <- migrateSchema st migrations confirmMigrations `onException` closeSQLiteStore st
  case r of
    Right () -> pure $ Right st
    Left e -> closeSQLiteStore st $> Left e

migrateSchema :: SQLiteStore -> [Migration] -> MigrationConfirmation -> IO (Either MigrationError ())
migrateSchema st migrations confirmMigrations = do
  Migrations.initialize st
  Migrations.get st migrations >>= \case
    Left e -> do
      when (confirmMigrations == MCConsole) $ confirmOrExit ("Database state error: " <> mtrErrorDescription e)
      pure . Left $ MigrationError e
    Right MTRNone -> pure $ Right ()
    Right ms@(MTRUp ums)
      | dbNew st -> Migrations.run st ms $> Right ()
      | otherwise -> case confirmMigrations of
          MCYesUp -> run ms
          MCYesUpDown -> run ms
          MCConsole -> confirm err >> run ms
          MCError -> pure $ Left err
      where
        err = MEUpgrade $ map upMigration ums -- "The app has a newer version than the database.\nConfirm to back up and upgrade using these migrations: " <> intercalate ", " (map name ums)
    Right ms@(MTRDown dms) -> case confirmMigrations of
      MCYesUpDown -> run ms
      MCConsole -> confirm err >> run ms
      MCYesUp -> pure $ Left err
      MCError -> pure $ Left err
      where
        err = MEDowngrade $ map downName dms
  where
    confirm err = confirmOrExit $ migrationErrorDescription err
    run ms = do
      let f = dbFilePath st
      copyFile f (f <> ".bak")
      Migrations.run st ms
      pure $ Right ()

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
  dbConn <- dbBusyLoop (connectDB dbFilePath dbKey)
  atomically $ do
    dbConnection <- newTMVar dbConn
    dbEncrypted <- newTVar . not $ null dbKey
    dbClosed <- newTVar False
    pure SQLiteStore {dbFilePath, dbEncrypted, dbConnection, dbNew, dbClosed}

connectDB :: FilePath -> String -> IO DB.Connection
connectDB path key = do
  db <- DB.open path
  prepare db `onException` DB.close db
  -- _printPragmas db path
  pure db
  where
    prepare db = do
      let exec = SQLite3.exec $ SQL.connectionHandle $ DB.conn db
      unless (null key) . exec $ "PRAGMA key = " <> sqlString key <> ";"
      exec . fromQuery $
        [sql|
          PRAGMA busy_timeout = 100;
          PRAGMA foreign_keys = ON;
          -- PRAGMA trusted_schema = OFF;
          PRAGMA secure_delete = ON;
          PRAGMA auto_vacuum = FULL;
        |]

closeSQLiteStore :: SQLiteStore -> IO ()
closeSQLiteStore st@SQLiteStore {dbClosed} =
  ifM (readTVarIO dbClosed) (putStrLn "closeSQLiteStore: already closed") $
    withConnection st $ \conn -> do
      DB.close conn
      atomically $ writeTVar dbClosed True

openSQLiteStore :: SQLiteStore -> String -> IO ()
openSQLiteStore SQLiteStore {dbConnection, dbFilePath, dbClosed} key =
  ifM (readTVarIO dbClosed) open (putStrLn "closeSQLiteStore: already opened")
  where
    open =
      bracketOnError
        (atomically $ takeTMVar dbConnection)
        (atomically . tryPutTMVar dbConnection)
        $ \DB.Connection {slow} -> do
          DB.Connection {conn} <- connectDB dbFilePath key
          atomically $ do
            putTMVar dbConnection DB.Connection {conn, slow}
            writeTVar dbClosed False

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
  SQLite3.execWithCallback (SQL.connectionHandle $ DB.conn db) query (addSQLResultRow rs)
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
  | SQL.sqlError e == SQL.ErrorConstraint = err
  | otherwise = SEInternal $ bshow e

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
    serverKeyHash_ <- createServer_ db server
    DB.execute db "INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?,?,?,?,?,?)" (userId, connId, cMode, connAgentVersion, enableNtfs, duplexHandshake)
    void $ insertRcvQueue_ db connId q serverKeyHash_

createSndConn :: DB.Connection -> TVar ChaChaDRG -> ConnData -> SndQueue -> IO (Either StoreError ConnId)
createSndConn db gVar cData@ConnData {userId, connAgentVersion, enableNtfs, duplexHandshake} q@SndQueue {server} =
  -- check confirmed snd queue doesn't already exist, to prevent it being deleted by REPLACE in insertSndQueue_
  ifM (liftIO $ checkConfirmedSndQueueExists_ db q) (pure $ Left SESndQueueExists) $
    createConn_ gVar cData $ \connId -> do
      serverKeyHash_ <- createServer_ db server
      DB.execute db "INSERT INTO connections (user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake) VALUES (?,?,?,?,?,?)" (userId, connId, SCMInvitation, connAgentVersion, enableNtfs, duplexHandshake)
      void $ insertSndQueue_ db connId q serverKeyHash_

checkConfirmedSndQueueExists_ :: DB.Connection -> SndQueue -> IO Bool
checkConfirmedSndQueueExists_ db SndQueue {server, sndId} = do
  fromMaybe False
    <$> maybeFirstRow
      fromOnly
      ( DB.query
          db
          "SELECT 1 FROM snd_queues WHERE host = ? AND port = ? AND snd_id = ? AND status != ? LIMIT 1"
          (host server, port server, sndId, New)
      )

getRcvConn :: DB.Connection -> SMPServer -> SMP.RecipientId -> IO (Either StoreError (RcvQueue, SomeConn))
getRcvConn db ProtocolServer {host, port} rcvId = runExceptT $ do
  rq@RcvQueue {connId} <-
    ExceptT . firstRow toRcvQueue SEConnNotFound $
      DB.query db (rcvQueueQuery <> " WHERE q.host = ? AND q.port = ? AND q.rcv_id = ? AND q.deleted = 0") (host, port, rcvId)
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
  serverKeyHash_ <- createServer_ db server
  insertRcvQueue_ db connId rq serverKeyHash_

addConnSndQueue :: DB.Connection -> ConnId -> SndQueue -> IO (Either StoreError Int64)
addConnSndQueue db connId sq =
  getConn db connId >>= \case
    Right (SomeConn _ DuplexConnection {}) -> Right <$> addConnSndQueue_ db connId sq
    Right (SomeConn c _) -> pure . Left . SEBadConnType $ connType c
    _ -> pure $ Left SEConnNotFound

addConnSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> IO Int64
addConnSndQueue_ db connId sq@SndQueue {server} = do
  serverKeyHash_ <- createServer_ db server
  insertSndQueue_ db connId sq serverKeyHash_

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

setRcvSwitchStatus :: DB.Connection -> RcvQueue -> Maybe RcvSwitchStatus -> IO RcvQueue
setRcvSwitchStatus db rq@RcvQueue {rcvId, server = ProtocolServer {host, port}} rcvSwchStatus = do
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET switch_status = ?
      WHERE host = ? AND port = ? AND rcv_id = ?
    |]
    (rcvSwchStatus, host, port, rcvId)
  pure rq {rcvSwchStatus}

setRcvQueueDeleted :: DB.Connection -> RcvQueue -> IO ()
setRcvQueueDeleted db RcvQueue {rcvId, server = ProtocolServer {host, port}} = do
  DB.execute
    db
    [sql|
      UPDATE rcv_queues
      SET deleted = 1
      WHERE host = ? AND port = ? AND rcv_id = ?
    |]
    (host, port, rcvId)

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

setSndSwitchStatus :: DB.Connection -> SndQueue -> Maybe SndSwitchStatus -> IO SndQueue
setSndSwitchStatus db sq@SndQueue {sndId, server = ProtocolServer {host, port}} sndSwchStatus = do
  DB.execute
    db
    [sql|
      UPDATE snd_queues
      SET switch_status = ?
      WHERE host = ? AND port = ? AND snd_id = ?
    |]
    (sndSwchStatus, host, port, sndId)
  pure sq {sndSwchStatus}

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
    DB.query db (rcvQueueQuery <> "WHERE q.conn_id = ? AND q.host = ? AND q.port = ? AND q.rcv_id = ? AND q.deleted = 0") (connId, host, port, rcvId)

getDeletedRcvQueue :: DB.Connection -> ConnId -> SMPServer -> SMP.RecipientId -> IO (Either StoreError RcvQueue)
getDeletedRcvQueue db connId (SMPServer host port _) rcvId =
  firstRow toRcvQueue SEConnNotFound $
    DB.query db (rcvQueueQuery <> "WHERE q.conn_id = ? AND q.host = ? AND q.port = ? AND q.rcv_id = ? AND q.deleted = 1") (connId, host, port, rcvId)

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

getSndMsgViaRcpt :: DB.Connection -> ConnId -> InternalSndId -> IO (Either StoreError SndMsg)
getSndMsgViaRcpt db connId sndMsgId =
  firstRow toSndMsg SEMsgNotFound $
    DB.query
      db
      [sql|
        SELECT s.internal_id, m.msg_type, s.internal_hash, s.rcpt_internal_id, s.rcpt_status
        FROM snd_messages s
        JOIN messages m ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
        WHERE s.conn_id = ? AND s.internal_snd_id = ?
      |]
      (connId, sndMsgId)
  where
    toSndMsg :: (InternalId, AgentMessageType, MsgHash, Maybe AgentMsgId, Maybe MsgReceiptStatus) -> SndMsg
    toSndMsg (internalId, msgType, internalHash, rcptInternalId_, rcptStatus_) =
      let msgReceipt = MsgReceipt <$> rcptInternalId_ <*> rcptStatus_
       in SndMsg {internalId, internalSndId = sndMsgId, msgType, internalHash, msgReceipt}

updateSndMsgRcpt :: DB.Connection -> ConnId -> InternalSndId -> MsgReceipt -> IO ()
updateSndMsgRcpt db connId sndMsgId MsgReceipt {agentMsgId, msgRcptStatus} =
  DB.execute
    db
    "UPDATE snd_messages SET rcpt_internal_id = ?, rcpt_status = ? WHERE conn_id = ? AND internal_snd_id = ?"
    (agentMsgId, msgRcptStatus, connId, sndMsgId)

getPendingMsgData :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError (Maybe RcvQueue, PendingMsgData))
getPendingMsgData db connId msgId = do
  rq_ <- L.head <$$> getRcvQueuesByConnId_ db connId
  (rq_,) <$$> firstRow pendingMsgData SEMsgNotFound getMsgData_
  where
    getMsgData_ =
      DB.query
        db
        [sql|
          SELECT m.msg_type, m.msg_flags, m.msg_body, m.internal_ts, s.retry_int_slow, s.retry_int_fast
          FROM messages m
          JOIN snd_messages s ON s.conn_id = m.conn_id AND s.internal_id = m.internal_id
          WHERE m.conn_id = ? AND m.internal_id = ?
        |]
        (connId, msgId)
    pendingMsgData :: (AgentMessageType, Maybe MsgFlags, MsgBody, InternalTs, Maybe Int64, Maybe Int64) -> PendingMsgData
    pendingMsgData (msgType, msgFlags_, msgBody, internalTs, riSlow_, riFast_) =
      let msgFlags = fromMaybe SMP.noMsgFlags msgFlags_
          msgRetryState = RI2State <$> riSlow_ <*> riFast_
       in PendingMsgData {msgId, msgType, msgFlags, msgBody, msgRetryState, internalTs}

updatePendingMsgRIState :: DB.Connection -> ConnId -> InternalId -> RI2State -> IO ()
updatePendingMsgRIState db connId msgId RI2State {slowInterval, fastInterval} =
  DB.execute db "UPDATE snd_messages SET retry_int_slow = ?, retry_int_fast = ? WHERE conn_id = ? AND internal_id = ?" (slowInterval, fastInterval, connId, msgId)

getPendingMsgs :: DB.Connection -> ConnId -> SndQueue -> IO [InternalId]
getPendingMsgs db connId SndQueue {dbQueueId} =
  map fromOnly
    <$> DB.query db "SELECT internal_id FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ? ORDER BY internal_id ASC" (connId, dbQueueId)

deletePendingMsgs :: DB.Connection -> ConnId -> SndQueue -> IO ()
deletePendingMsgs db connId SndQueue {dbQueueId} =
  DB.execute db "DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ?" (connId, dbQueueId)

setMsgUserAck :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError (RcvQueue, SMP.MsgId))
setMsgUserAck db connId agentMsgId = runExceptT $ do
  (dbRcvId, srvMsgId) <-
    ExceptT . firstRow id SEMsgNotFound $
      DB.query db "SELECT rcv_queue_id, broker_id FROM rcv_messages WHERE conn_id = ? AND internal_id = ?" (connId, agentMsgId)
  rq <- ExceptT $ getRcvQueueById db connId dbRcvId
  liftIO $ DB.execute db "UPDATE rcv_messages SET user_ack = ? WHERE conn_id = ? AND internal_id = ?" (True, connId, agentMsgId)
  pure (rq, srvMsgId)

getRcvMsg :: DB.Connection -> ConnId -> InternalId -> IO (Either StoreError RcvMsg)
getRcvMsg db connId agentMsgId =
  firstRow toRcvMsg SEMsgNotFound $
    DB.query
      db
      [sql|
        SELECT
          r.internal_id, m.internal_ts, r.broker_id, r.broker_ts, r.external_snd_id, r.integrity, r.internal_hash,
          m.msg_type, m.msg_body, s.internal_id, s.rcpt_status, r.user_ack
        FROM rcv_messages r
        JOIN messages m ON r.conn_id = m.conn_id AND r.internal_id = m.internal_id
        LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
        WHERE r.conn_id = ? AND r.internal_id = ?
      |]
      (connId, agentMsgId)

getLastMsg :: DB.Connection -> ConnId -> SMP.MsgId -> IO (Maybe RcvMsg)
getLastMsg db connId msgId =
  maybeFirstRow toRcvMsg $
    DB.query
      db
      [sql|
        SELECT
          r.internal_id, m.internal_ts, r.broker_id, r.broker_ts, r.external_snd_id, r.integrity, r.internal_hash,
          m.msg_type, m.msg_body, s.internal_id, s.rcpt_status, r.user_ack
        FROM rcv_messages r
        JOIN messages m ON r.conn_id = m.conn_id AND r.internal_id = m.internal_id
        JOIN connections c ON r.conn_id = c.conn_id AND c.last_internal_msg_id = r.internal_id
        LEFT JOIN snd_messages s ON s.conn_id = r.conn_id AND s.rcpt_internal_id = r.internal_id
        WHERE r.conn_id = ? AND r.broker_id = ?
      |]
      (connId, msgId)

toRcvMsg :: (Int64, InternalTs, BrokerId, BrokerTs, AgentMsgId, MsgIntegrity, MsgHash, AgentMessageType, MsgBody, Maybe AgentMsgId, Maybe MsgReceiptStatus, Bool) -> RcvMsg
toRcvMsg (agentMsgId, internalTs, brokerId, brokerTs, sndMsgId, integrity, internalHash, msgType, msgBody, rcptInternalId_, rcptStatus_, userAck) =
  let msgMeta = MsgMeta {recipient = (agentMsgId, internalTs), broker = (brokerId, brokerTs), sndMsgId, integrity}
      msgReceipt = MsgReceipt <$> rcptInternalId_ <*> rcptStatus_
   in RcvMsg {internalId = InternalId agentMsgId, msgMeta, msgType, msgBody, internalHash, msgReceipt, userAck}

checkRcvMsgHashExists :: DB.Connection -> ConnId -> ByteString -> IO Bool
checkRcvMsgHashExists db connId hash = do
  fromMaybe False
    <$> maybeFirstRow
      fromOnly
      ( DB.query
          db
          "SELECT 1 FROM encrypted_rcv_message_hashes WHERE conn_id = ? AND hash = ? LIMIT 1"
          (connId, hash)
      )

deleteMsg :: DB.Connection -> ConnId -> InternalId -> IO ()
deleteMsg db connId msgId =
  DB.execute db "DELETE FROM messages WHERE conn_id = ? AND internal_id = ?;" (connId, msgId)

deleteMsgContent :: DB.Connection -> ConnId -> InternalId -> IO ()
deleteMsgContent db connId msgId =
  DB.execute db "UPDATE messages SET msg_body = x'' WHERE conn_id = ? AND internal_id = ?;" (connId, msgId)

deleteDeliveredSndMsg :: DB.Connection -> ConnId -> InternalId -> IO ()
deleteDeliveredSndMsg db connId msgId = do
  cnt <- countPendingSndDeliveries_ db connId msgId
  when (cnt == 0) $ deleteMsg db connId msgId

deleteSndMsgDelivery :: DB.Connection -> ConnId -> SndQueue -> InternalId -> Bool -> IO ()
deleteSndMsgDelivery db connId SndQueue {dbQueueId} msgId keepForReceipt = do
  DB.execute
    db
    "DELETE FROM snd_message_deliveries WHERE conn_id = ? AND snd_queue_id = ? AND internal_id = ?"
    (connId, dbQueueId, msgId)
  cnt <- countPendingSndDeliveries_ db connId msgId
  when (cnt == 0) $ do
    del <-
      maybeFirstRow id (DB.query db "SELECT rcpt_internal_id, rcpt_status FROM snd_messages WHERE conn_id = ? AND internal_id = ?" (connId, msgId)) >>= \case
        Just (Just (_ :: Int64), Just MROk) -> pure deleteMsg
        _ -> pure $ if keepForReceipt then deleteMsgContent else deleteMsg
    del db connId msgId

countPendingSndDeliveries_ :: DB.Connection -> ConnId -> InternalId -> IO Int
countPendingSndDeliveries_ db connId msgId = do
  (Only cnt : _) <- DB.query db "SELECT count(*) FROM snd_message_deliveries WHERE conn_id = ? AND internal_id = ?" (connId, msgId)
  pure cnt

deleteRcvMsgHashesExpired :: DB.Connection -> NominalDiffTime -> IO ()
deleteRcvMsgHashesExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.execute db "DELETE FROM encrypted_rcv_message_hashes WHERE created_at < ?" (Only cutoffTs)

deleteSndMsgsExpired :: DB.Connection -> NominalDiffTime -> IO ()
deleteSndMsgsExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.execute
    db
    "DELETE FROM messages WHERE internal_ts < ? AND internal_snd_id IS NOT NULL"
    (Only cutoffTs)

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

createRatchetX3dhKeys' :: DB.Connection -> ConnId -> C.PrivateKeyX448 -> C.PrivateKeyX448 -> C.PublicKeyX448 -> C.PublicKeyX448 -> IO ()
createRatchetX3dhKeys' db connId x3dhPrivKey1 x3dhPrivKey2 x3dhPubKey1 x3dhPubKey2 =
  DB.execute
    db
    "INSERT INTO ratchets (conn_id, x3dh_priv_key_1, x3dh_priv_key_2, x3dh_pub_key_1, x3dh_pub_key_2) VALUES (?,?,?,?,?)"
    (connId, x3dhPrivKey1, x3dhPrivKey2, x3dhPubKey1, x3dhPubKey2)

getRatchetX3dhKeys' :: DB.Connection -> ConnId -> IO (Either StoreError (C.PrivateKeyX448, C.PrivateKeyX448, C.PublicKeyX448, C.PublicKeyX448))
getRatchetX3dhKeys' db connId =
  fmap hasKeys $
    firstRow id SEX3dhKeysNotFound $
      DB.query db "SELECT x3dh_priv_key_1, x3dh_priv_key_2, x3dh_pub_key_1, x3dh_pub_key_2 FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    hasKeys = \case
      Right (Just pk1, Just pk2, Just k1, Just k2) -> Right (pk1, pk2, k1, k2)
      _ -> Left SEX3dhKeysNotFound

-- used to remember new keys when starting ratchet re-synchronization
setRatchetX3dhKeys :: DB.Connection -> ConnId -> C.PrivateKeyX448 -> C.PrivateKeyX448 -> C.PublicKeyX448 -> C.PublicKeyX448 -> IO ()
setRatchetX3dhKeys db connId x3dhPrivKey1 x3dhPrivKey2 x3dhPubKey1 x3dhPubKey2 =
  DB.execute
    db
    [sql|
      UPDATE ratchets
      SET x3dh_priv_key_1 = ?, x3dh_priv_key_2 = ?, x3dh_pub_key_1 = ?, x3dh_pub_key_2 = ?
      WHERE conn_id = ?
    |]
    (x3dhPrivKey1, x3dhPrivKey2, x3dhPubKey1, x3dhPubKey2, connId)

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
        x3dh_priv_key_2 = NULL,
        x3dh_pub_key_1 = NULL,
        x3dh_pub_key_2 = NULL
    |]
    [":conn_id" := connId, ":ratchet_state" := rc]

deleteRatchet :: DB.Connection -> ConnId -> IO ()
deleteRatchet db connId =
  DB.execute db "DELETE FROM ratchets WHERE conn_id = ?" (Only connId)

getRatchet :: DB.Connection -> ConnId -> IO (Either StoreError RatchetX448)
getRatchet db connId =
  firstRow' ratchet SERatchetNotFound $ DB.query db "SELECT ratchet_state FROM ratchets WHERE conn_id = ?" (Only connId)
  where
    ratchet = maybe (Left SERatchetNotFound) Right . fromOnly

getSkippedMsgKeys :: DB.Connection -> ConnId -> IO SkippedMsgKeys
getSkippedMsgKeys db connId =
  skipped <$> DB.query db "SELECT header_key, msg_n, msg_key FROM skipped_messages WHERE conn_id = ?" (Only connId)
  where
    skipped = foldl' addSkippedKey M.empty
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

createCommand :: DB.Connection -> ACorrId -> ConnId -> Maybe SMPServer -> AgentCommand -> IO (Either StoreError AsyncCmdId)
createCommand db corrId connId srv_ cmd = runExceptT $ do
  (host_, port_, serverKeyHash_) <- serverFields
  liftIO $ do
    DB.execute
      db
      "INSERT INTO commands (host, port, corr_id, conn_id, command_tag, command, server_key_hash) VALUES (?,?,?,?,?,?,?)"
      (host_, port_, corrId, connId, agentCommandTag cmd, cmd, serverKeyHash_)
    insertedRowId db
  where
    serverFields :: ExceptT StoreError IO (Maybe (NonEmpty TransportHost), Maybe ServiceName, Maybe C.KeyHash)
    serverFields = case srv_ of
      Just srv@(SMPServer host port _) ->
        (Just host,Just port,) <$> ExceptT (getServerKeyHash_ db srv)
      Nothing -> pure (Nothing, Nothing, Nothing)

insertedRowId :: DB.Connection -> IO Int64
insertedRowId db = fromOnly . head <$> DB.query_ db "SELECT last_insert_rowid()"

getPendingCommands :: DB.Connection -> ConnId -> IO [(Maybe SMPServer, [AsyncCmdId])]
getPendingCommands db connId = do
  -- `groupOn` is used instead of `groupAllOn` to avoid extra sorting by `server + cmdId`, as the query already sorts by them.
  -- TODO review whether this can break if, e.g., the server has another key hash.
  map (\ids -> (fst $ head ids, map snd ids)) . groupOn fst . map srvCmdId
    <$> DB.query
      db
      [sql|
        SELECT c.host, c.port, COALESCE(c.server_key_hash, s.key_hash), c.command_id
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
        SELECT s.host, s.port, COALESCE(nsb.smp_server_key_hash, s.key_hash), ns.ntf_host, ns.ntf_port, ns.ntf_key_hash,
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

createNtfSubscription :: DB.Connection -> NtfSubscription -> NtfSubAction -> IO (Either StoreError ())
createNtfSubscription db ntfSubscription action = runExceptT $ do
  let NtfSubscription {connId, smpServer = smpServer@(SMPServer host port _), ntfQueueId, ntfServer = (NtfServer ntfHost ntfPort _), ntfSubId, ntfSubStatus} = ntfSubscription
  smpServerKeyHash_ <- ExceptT $ getServerKeyHash_ db smpServer
  actionTs <- liftIO getCurrentTime
  liftIO $
    DB.execute
      db
      [sql|
        INSERT INTO ntf_subscriptions
          (conn_id, smp_host, smp_port, smp_ntf_id, ntf_host, ntf_port, ntf_sub_id,
            ntf_sub_status, ntf_sub_action, ntf_sub_smp_action, ntf_sub_action_ts, smp_server_key_hash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      |]
      ( (connId, host, port, ntfQueueId, ntfHost, ntfPort, ntfSubId)
          :. (ntfSubStatus, ntfSubAction, ntfSubSMPAction, actionTs, smpServerKeyHash_)
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
          SELECT ns.conn_id, s.host, s.port, COALESCE(ns.smp_server_key_hash, s.key_hash),
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
        WHERE host = ? AND port = ? AND ntf_id = ? AND deleted = 0
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

instance ToField MsgReceiptStatus where toField = toField . decodeLatin1 . strEncode

instance FromField MsgReceiptStatus where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

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

-- * Server helper

-- | Creates a new server, if it doesn't exist, and returns the passed key hash if it is different from stored.
createServer_ :: DB.Connection -> SMPServer -> IO (Maybe C.KeyHash)
createServer_ db newSrv@ProtocolServer {host, port, keyHash} =
  getServerKeyHash_ db newSrv >>= \case
    Right keyHash_ -> pure keyHash_
    Left _ -> insertNewServer_ $> Nothing
  where
    insertNewServer_ =
      DB.execute db "INSERT INTO servers (host, port, key_hash) VALUES (?,?,?)" (host, port, keyHash)

-- | Returns the passed server key hash if it is different from the stored one, or the error if the server does not exist.
getServerKeyHash_ :: DB.Connection -> SMPServer -> IO (Either StoreError (Maybe C.KeyHash))
getServerKeyHash_ db ProtocolServer {host, port, keyHash} = do
  firstRow useKeyHash SEServerNotFound $
    DB.query db "SELECT key_hash FROM servers WHERE host = ? AND port = ?" (host, port)
  where
    useKeyHash (Only keyHash') = if keyHash /= keyHash' then Just keyHash else Nothing

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

insertRcvQueue_ :: DB.Connection -> ConnId -> RcvQueue -> Maybe C.KeyHash -> IO Int64
insertRcvQueue_ db connId' RcvQueue {..} serverKeyHash_ = do
  qId <- newQueueId_ <$> DB.query db "SELECT rcv_queue_id FROM rcv_queues WHERE conn_id = ? ORDER BY rcv_queue_id DESC LIMIT 1" (Only connId')
  DB.execute
    db
    [sql|
      INSERT INTO rcv_queues
        (host, port, rcv_id, conn_id, rcv_private_key, rcv_dh_secret, e2e_priv_key, e2e_dh_secret, snd_id, status, rcv_queue_id, rcv_primary, replace_rcv_queue_id, smp_client_version, server_key_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((host server, port server, rcvId, connId', rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret) :. (sndId, status, qId, primary, dbReplaceQueueId, smpClientVersion, serverKeyHash_))
  pure qId

-- * createSndConn helpers

insertSndQueue_ :: DB.Connection -> ConnId -> SndQueue -> Maybe C.KeyHash -> IO Int64
insertSndQueue_ db connId' SndQueue {..} serverKeyHash_ = do
  qId <- newQueueId_ <$> DB.query db "SELECT snd_queue_id FROM snd_queues WHERE conn_id = ? ORDER BY snd_queue_id DESC LIMIT 1" (Only connId')
  DB.execute
    db
    [sql|
      INSERT OR REPLACE INTO snd_queues
        (host, port, snd_id, conn_id, snd_public_key, snd_private_key, e2e_pub_key, e2e_dh_secret, status, snd_queue_id, snd_primary, replace_snd_queue_id, smp_client_version, server_key_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
    |]
    ((host server, port server, sndId, connId', sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret) :. (status, qId, primary, dbReplaceQueueId, smpClientVersion, serverKeyHash_))
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
getConnData db connId' =
  maybeFirstRow cData $
    DB.query
      db
      [sql|
        SELECT
          user_id, conn_id, conn_mode, smp_agent_version, enable_ntfs, duplex_handshake,
          last_external_snd_msg_id, deleted, ratchet_sync_state
        FROM connections
        WHERE conn_id = ?
      |]
      (Only connId')
  where
    cData (userId, connId, cMode, connAgentVersion, enableNtfs_, duplexHandshake, lastExternalSndId, deleted, ratchetSyncState) =
      (ConnData {userId, connId, connAgentVersion, enableNtfs = fromMaybe True enableNtfs_, duplexHandshake, lastExternalSndId, deleted, ratchetSyncState}, cMode)

setConnDeleted :: DB.Connection -> ConnId -> IO ()
setConnDeleted db connId = DB.execute db "UPDATE connections SET deleted = ? WHERE conn_id = ?" (True, connId)

setConnAgentVersion :: DB.Connection -> ConnId -> Version -> IO ()
setConnAgentVersion db connId aVersion =
  DB.execute db "UPDATE connections SET smp_agent_version = ? WHERE conn_id = ?" (aVersion, connId)

getDeletedConnIds :: DB.Connection -> IO [ConnId]
getDeletedConnIds db = map fromOnly <$> DB.query db "SELECT conn_id FROM connections WHERE deleted = ?" (Only True)

setConnRatchetSync :: DB.Connection -> ConnId -> RatchetSyncState -> IO ()
setConnRatchetSync db connId ratchetSyncState =
  DB.execute db "UPDATE connections SET ratchet_sync_state = ? WHERE conn_id = ?" (ratchetSyncState, connId)

addProcessedRatchetKeyHash :: DB.Connection -> ConnId -> ByteString -> IO ()
addProcessedRatchetKeyHash db connId hash =
  DB.execute db "INSERT INTO processed_ratchet_key_hashes (conn_id, hash) VALUES (?,?)" (connId, hash)

checkRatchetKeyHashExists :: DB.Connection -> ConnId -> ByteString -> IO Bool
checkRatchetKeyHashExists db connId hash = do
  fromMaybe False
    <$> maybeFirstRow
      fromOnly
      ( DB.query
          db
          "SELECT 1 FROM processed_ratchet_key_hashes WHERE conn_id = ? AND hash = ? LIMIT 1"
          (connId, hash)
      )

deleteRatchetKeyHashesExpired :: DB.Connection -> NominalDiffTime -> IO ()
deleteRatchetKeyHashesExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.execute db "DELETE FROM processed_ratchet_key_hashes WHERE created_at < ?" (Only cutoffTs)

-- | returns all connection queues, the first queue is the primary one
getRcvQueuesByConnId_ :: DB.Connection -> ConnId -> IO (Maybe (NonEmpty RcvQueue))
getRcvQueuesByConnId_ db connId =
  L.nonEmpty . sortBy primaryFirst . map toRcvQueue
    <$> DB.query db (rcvQueueQuery <> "WHERE q.conn_id = ? AND q.deleted = 0") (Only connId)
  where
    primaryFirst RcvQueue {primary = p, dbReplaceQueueId = i} RcvQueue {primary = p', dbReplaceQueueId = i'} =
      -- the current primary queue is ordered first, the next primary - second
      compare (Down p) (Down p') <> compare i i'

rcvQueueQuery :: Query
rcvQueueQuery =
  [sql|
    SELECT c.user_id, COALESCE(q.server_key_hash, s.key_hash), q.conn_id, q.host, q.port, q.rcv_id, q.rcv_private_key, q.rcv_dh_secret,
      q.e2e_priv_key, q.e2e_dh_secret, q.snd_id, q.status,
      q.rcv_queue_id, q.rcv_primary, q.replace_rcv_queue_id, q.switch_status, q.smp_client_version, q.delete_errors,
      q.ntf_public_key, q.ntf_private_key, q.ntf_id, q.rcv_ntf_dh_secret
    FROM rcv_queues q
    JOIN servers s ON q.host = s.host AND q.port = s.port
    JOIN connections c ON q.conn_id = c.conn_id
  |]

toRcvQueue ::
  (UserId, C.KeyHash, ConnId, NonEmpty TransportHost, ServiceName, SMP.RecipientId, SMP.RcvPrivateSignKey, SMP.RcvDhSecret, C.PrivateKeyX25519, Maybe C.DhSecretX25519, SMP.SenderId, QueueStatus)
    :. (Int64, Bool, Maybe Int64, Maybe RcvSwitchStatus, Maybe Version, Int)
    :. (Maybe SMP.NtfPublicVerifyKey, Maybe SMP.NtfPrivateSignKey, Maybe SMP.NotifierId, Maybe RcvNtfDhSecret) ->
  RcvQueue
toRcvQueue ((userId, keyHash, connId, host, port, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status) :. (dbQueueId, primary, dbReplaceQueueId, rcvSwchStatus, smpClientVersion_, deleteErrors) :. (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_)) =
  let server = SMPServer host port keyHash
      smpClientVersion = fromMaybe 1 smpClientVersion_
      clientNtfCreds = case (ntfPublicKey_, ntfPrivateKey_, notifierId_, rcvNtfDhSecret_) of
        (Just ntfPublicKey, Just ntfPrivateKey, Just notifierId, Just rcvNtfDhSecret) -> Just $ ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
        _ -> Nothing
   in RcvQueue {userId, connId, server, rcvId, rcvPrivateKey, rcvDhSecret, e2ePrivKey, e2eDhSecret, sndId, status, dbQueueId, primary, dbReplaceQueueId, rcvSwchStatus, smpClientVersion, clientNtfCreds, deleteErrors}

getRcvQueueById :: DB.Connection -> ConnId -> Int64 -> IO (Either StoreError RcvQueue)
getRcvQueueById db connId dbRcvId =
  firstRow toRcvQueue SEConnNotFound $
    DB.query db (rcvQueueQuery <> " WHERE q.conn_id = ? AND q.rcv_queue_id = ? AND q.deleted = 0") (connId, dbRcvId)

-- | returns all connection queues, the first queue is the primary one
getSndQueuesByConnId_ :: DB.Connection -> ConnId -> IO (Maybe (NonEmpty SndQueue))
getSndQueuesByConnId_ dbConn connId =
  L.nonEmpty . sortBy primaryFirst . map toSndQueue
    <$> DB.query dbConn (sndQueueQuery <> "WHERE q.conn_id = ?") (Only connId)
  where
    primaryFirst SndQueue {primary = p, dbReplaceQueueId = i} SndQueue {primary = p', dbReplaceQueueId = i'} =
      -- the current primary queue is ordered first, the next primary - second
      compare (Down p) (Down p') <> compare i i'

sndQueueQuery :: Query
sndQueueQuery =
  [sql|
    SELECT
      c.user_id, COALESCE(q.server_key_hash, s.key_hash), q.conn_id, q.host, q.port, q.snd_id,
      q.snd_public_key, q.snd_private_key, q.e2e_pub_key, q.e2e_dh_secret, q.status,
      q.snd_queue_id, q.snd_primary, q.replace_snd_queue_id, q.switch_status, q.smp_client_version
    FROM snd_queues q
    JOIN servers s ON q.host = s.host AND q.port = s.port
    JOIN connections c ON q.conn_id = c.conn_id
  |]

toSndQueue ::
  (UserId, C.KeyHash, ConnId, NonEmpty TransportHost, ServiceName, SenderId)
    :. (Maybe C.APublicVerifyKey, SndPrivateSignKey, Maybe C.PublicKeyX25519, C.DhSecretX25519, QueueStatus)
    :. (Int64, Bool, Maybe Int64, Maybe SndSwitchStatus, Version) ->
  SndQueue
toSndQueue
  ( (userId, keyHash, connId, host, port, sndId)
      :. (sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status)
      :. (dbQueueId, primary, dbReplaceQueueId, sndSwchStatus, smpClientVersion)
    ) =
    let server = SMPServer host port keyHash
     in SndQueue {userId, connId, server, sndId, sndPublicKey, sndPrivateKey, e2ePubKey, e2eDhSecret, status, dbQueueId, primary, dbReplaceQueueId, sndSwchStatus, smpClientVersion}

getSndQueueById :: DB.Connection -> ConnId -> Int64 -> IO (Either StoreError SndQueue)
getSndQueueById db connId dbSndId =
  firstRow toSndQueue SEConnNotFound $
    DB.query db (sndQueueQuery <> " WHERE q.conn_id = ? AND q.snd_queue_id = ?") (connId, dbSndId)

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
insertRcvMsgDetails_ db connId RcvQueue {dbQueueId} RcvMsgData {msgMeta, internalRcvId, internalHash, externalPrevSndHash, encryptedMsgHash} = do
  let MsgMeta {integrity, recipient, broker, sndMsgId} = msgMeta
  DB.executeNamed
    db
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
  DB.execute db "INSERT INTO encrypted_rcv_message_hashes (conn_id, hash) VALUES (?,?)" (connId, encryptedMsgHash)

updateHashRcv_ :: DB.Connection -> ConnId -> RcvMsgData -> IO ()
updateHashRcv_ dbConn connId RcvMsgData {msgMeta = MsgMeta {sndMsgId}, internalHash, internalRcvId} =
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
    [ ":last_external_snd_msg_id" := sndMsgId,
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
          | SQL.sqlError e == SQL.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> pure . Left . SEInternal $ bshow e

randomId :: TVar ChaChaDRG -> Int -> IO ByteString
randomId gVar n = atomically $ U.encode <$> C.pseudoRandomBytes n gVar

ntfSubAndSMPAction :: NtfSubAction -> (Maybe NtfSubNTFAction, Maybe NtfSubSMPAction)
ntfSubAndSMPAction (NtfSubNTFAction action) = (Just action, Nothing)
ntfSubAndSMPAction (NtfSubSMPAction action) = (Nothing, Just action)

createXFTPServer_ :: DB.Connection -> XFTPServer -> IO Int64
createXFTPServer_ db newSrv@ProtocolServer {host, port, keyHash} =
  getXFTPServerId_ db newSrv >>= \case
    Right srvId -> pure srvId
    Left _ -> insertNewServer_
  where
    insertNewServer_ = do
      DB.execute db "INSERT INTO xftp_servers (xftp_host, xftp_port, xftp_key_hash) VALUES (?,?,?)" (host, port, keyHash)
      insertedRowId db

getXFTPServerId_ :: DB.Connection -> XFTPServer -> IO (Either StoreError Int64)
getXFTPServerId_ db ProtocolServer {host, port, keyHash} = do
  firstRow fromOnly SEXFTPServerNotFound $
    DB.query db "SELECT xftp_server_id FROM xftp_servers WHERE xftp_host = ? AND xftp_port = ? AND xftp_key_hash = ?" (host, port, keyHash)

createRcvFile :: DB.Connection -> TVar ChaChaDRG -> UserId -> FileDescription 'FRecipient -> FilePath -> FilePath -> CryptoFile -> IO (Either StoreError RcvFileId)
createRcvFile db gVar userId fd@FileDescription {chunks} prefixPath tmpPath (CryptoFile savePath cfArgs) = runExceptT $ do
  (rcvFileEntityId, rcvFileId) <- ExceptT $ insertRcvFile fd
  liftIO $
    forM_ chunks $ \fc@FileChunk {replicas} -> do
      chunkId <- insertChunk fc rcvFileId
      forM_ (zip [1 ..] replicas) $ \(rno, replica) -> insertReplica rno replica chunkId
  pure rcvFileEntityId
  where
    insertRcvFile :: FileDescription 'FRecipient -> IO (Either StoreError (RcvFileId, DBRcvFileId))
    insertRcvFile FileDescription {size, digest, key, nonce, chunkSize} = runExceptT $ do
      rcvFileEntityId <- ExceptT $
        createWithRandomId gVar $ \rcvFileEntityId ->
          DB.execute
            db
            "INSERT INTO rcv_files (rcv_file_entity_id, user_id, size, digest, key, nonce, chunk_size, prefix_path, tmp_path, save_path, save_file_key, save_file_nonce, status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
            ((rcvFileEntityId, userId, size, digest, key, nonce, chunkSize) :. (prefixPath, tmpPath, savePath, fileKey <$> cfArgs, fileNonce <$> cfArgs, RFSReceiving))
      rcvFileId <- liftIO $ insertedRowId db
      pure (rcvFileEntityId, rcvFileId)
    insertChunk :: FileChunk -> DBRcvFileId -> IO Int64
    insertChunk FileChunk {chunkNo, chunkSize, digest} rcvFileId = do
      DB.execute
        db
        "INSERT INTO rcv_file_chunks (rcv_file_id, chunk_no, chunk_size, digest) VALUES (?,?,?,?)"
        (rcvFileId, chunkNo, chunkSize, digest)
      insertedRowId db
    insertReplica :: Int -> FileChunkReplica -> Int64 -> IO ()
    insertReplica replicaNo FileChunkReplica {server, replicaId, replicaKey} chunkId = do
      srvId <- createXFTPServer_ db server
      DB.execute
        db
        "INSERT INTO rcv_file_chunk_replicas (replica_number, rcv_file_chunk_id, xftp_server_id, replica_id, replica_key) VALUES (?,?,?,?,?)"
        (replicaNo, chunkId, srvId, replicaId, replicaKey)

getRcvFileByEntityId :: DB.Connection -> RcvFileId -> IO (Either StoreError RcvFile)
getRcvFileByEntityId db rcvFileEntityId = runExceptT $ do
  rcvFileId <- ExceptT $ getRcvFileIdByEntityId_ db rcvFileEntityId
  ExceptT $ getRcvFile db rcvFileId

getRcvFileIdByEntityId_ :: DB.Connection -> RcvFileId -> IO (Either StoreError DBRcvFileId)
getRcvFileIdByEntityId_ db rcvFileEntityId =
  firstRow fromOnly SEFileNotFound $
    DB.query db "SELECT rcv_file_id FROM rcv_files WHERE rcv_file_entity_id = ?" (Only rcvFileEntityId)

getRcvFile :: DB.Connection -> DBRcvFileId -> IO (Either StoreError RcvFile)
getRcvFile db rcvFileId = runExceptT $ do
  f@RcvFile {rcvFileEntityId, userId, tmpPath} <- ExceptT getFile
  chunks <- maybe (pure []) (liftIO . getChunks rcvFileEntityId userId) tmpPath
  pure (f {chunks} :: RcvFile)
  where
    getFile :: IO (Either StoreError RcvFile)
    getFile = do
      firstRow toFile SEFileNotFound $
        DB.query
          db
          [sql|
            SELECT rcv_file_entity_id, user_id, size, digest, key, nonce, chunk_size, prefix_path, tmp_path, save_path, save_file_key, save_file_nonce, status, deleted
            FROM rcv_files
            WHERE rcv_file_id = ?
          |]
          (Only rcvFileId)
      where
        toFile :: (RcvFileId, UserId, FileSize Int64, FileDigest, C.SbKey, C.CbNonce, FileSize Word32, FilePath, Maybe FilePath) :. (FilePath, Maybe C.SbKey, Maybe C.CbNonce, RcvFileStatus, Bool) -> RcvFile
        toFile ((rcvFileEntityId, userId, size, digest, key, nonce, chunkSize, prefixPath, tmpPath) :. (savePath, saveKey_, saveNonce_, status, deleted)) =
          let cfArgs = CFArgs <$> saveKey_ <*> saveNonce_
              saveFile = CryptoFile savePath cfArgs
           in RcvFile {rcvFileId, rcvFileEntityId, userId, size, digest, key, nonce, chunkSize, prefixPath, tmpPath, saveFile, status, deleted, chunks = []}
    getChunks :: RcvFileId -> UserId -> FilePath -> IO [RcvFileChunk]
    getChunks rcvFileEntityId userId fileTmpPath = do
      chunks <-
        map toChunk
          <$> DB.query
            db
            [sql|
              SELECT rcv_file_chunk_id, chunk_no, chunk_size, digest, tmp_path
              FROM rcv_file_chunks
              WHERE rcv_file_id = ?
            |]
            (Only rcvFileId)
      forM chunks $ \chunk@RcvFileChunk {rcvChunkId} -> do
        replicas' <- getChunkReplicas rcvChunkId
        pure (chunk {replicas = replicas'} :: RcvFileChunk)
      where
        toChunk :: (Int64, Int, FileSize Word32, FileDigest, Maybe FilePath) -> RcvFileChunk
        toChunk (rcvChunkId, chunkNo, chunkSize, digest, chunkTmpPath) =
          RcvFileChunk {rcvFileId, rcvFileEntityId, userId, rcvChunkId, chunkNo, chunkSize, digest, fileTmpPath, chunkTmpPath, replicas = []}
    getChunkReplicas :: Int64 -> IO [RcvFileChunkReplica]
    getChunkReplicas chunkId = do
      map toReplica
        <$> DB.query
          db
          [sql|
            SELECT
              r.rcv_file_chunk_replica_id, r.replica_id, r.replica_key, r.received, r.delay, r.retries,
              s.xftp_host, s.xftp_port, s.xftp_key_hash
            FROM rcv_file_chunk_replicas r
            JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
            WHERE r.rcv_file_chunk_id = ?
          |]
          (Only chunkId)
      where
        toReplica :: (Int64, ChunkReplicaId, C.APrivateSignKey, Bool, Maybe Int64, Int, NonEmpty TransportHost, ServiceName, C.KeyHash) -> RcvFileChunkReplica
        toReplica (rcvChunkReplicaId, replicaId, replicaKey, received, delay, retries, host, port, keyHash) =
          let server = XFTPServer host port keyHash
           in RcvFileChunkReplica {rcvChunkReplicaId, server, replicaId, replicaKey, received, delay, retries}

updateRcvChunkReplicaDelay :: DB.Connection -> Int64 -> Int64 -> IO ()
updateRcvChunkReplicaDelay db replicaId delay = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_file_chunk_replicas SET delay = ?, retries = retries + 1, updated_at = ? WHERE rcv_file_chunk_replica_id = ?" (delay, updatedAt, replicaId)

updateRcvFileChunkReceived :: DB.Connection -> Int64 -> Int64 -> FilePath -> IO ()
updateRcvFileChunkReceived db replicaId chunkId chunkTmpPath = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_file_chunk_replicas SET received = 1, updated_at = ? WHERE rcv_file_chunk_replica_id = ?" (updatedAt, replicaId)
  DB.execute db "UPDATE rcv_file_chunks SET tmp_path = ?, updated_at = ? WHERE rcv_file_chunk_id = ?" (chunkTmpPath, updatedAt, chunkId)

updateRcvFileStatus :: DB.Connection -> DBRcvFileId -> RcvFileStatus -> IO ()
updateRcvFileStatus db rcvFileId status = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_files SET status = ?, updated_at = ? WHERE rcv_file_id = ?" (status, updatedAt, rcvFileId)

updateRcvFileError :: DB.Connection -> DBRcvFileId -> String -> IO ()
updateRcvFileError db rcvFileId errStr = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_files SET tmp_path = NULL, error = ?, status = ?, updated_at = ? WHERE rcv_file_id = ?" (errStr, RFSError, updatedAt, rcvFileId)

updateRcvFileComplete :: DB.Connection -> DBRcvFileId -> IO ()
updateRcvFileComplete db rcvFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_files SET tmp_path = NULL, status = ?, updated_at = ? WHERE rcv_file_id = ?" (RFSComplete, updatedAt, rcvFileId)

updateRcvFileNoTmpPath :: DB.Connection -> DBRcvFileId -> IO ()
updateRcvFileNoTmpPath db rcvFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_files SET tmp_path = NULL, updated_at = ? WHERE rcv_file_id = ?" (updatedAt, rcvFileId)

updateRcvFileDeleted :: DB.Connection -> DBRcvFileId -> IO ()
updateRcvFileDeleted db rcvFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE rcv_files SET deleted = 1, updated_at = ? WHERE rcv_file_id = ?" (updatedAt, rcvFileId)

deleteRcvFile' :: DB.Connection -> DBRcvFileId -> IO ()
deleteRcvFile' db rcvFileId =
  DB.execute db "DELETE FROM rcv_files WHERE rcv_file_id = ?" (Only rcvFileId)

getNextRcvChunkToDownload :: DB.Connection -> XFTPServer -> NominalDiffTime -> IO (Maybe RcvFileChunk)
getNextRcvChunkToDownload db server@ProtocolServer {host, port, keyHash} ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  maybeFirstRow toChunk $
    DB.query
      db
      [sql|
        SELECT
          f.rcv_file_id, f.rcv_file_entity_id, f.user_id, c.rcv_file_chunk_id, c.chunk_no, c.chunk_size, c.digest, f.tmp_path, c.tmp_path,
          r.rcv_file_chunk_replica_id, r.replica_id, r.replica_key, r.received, r.delay, r.retries
        FROM rcv_file_chunk_replicas r
        JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
        JOIN rcv_file_chunks c ON c.rcv_file_chunk_id = r.rcv_file_chunk_id
        JOIN rcv_files f ON f.rcv_file_id = c.rcv_file_id
        WHERE s.xftp_host = ? AND s.xftp_port = ? AND s.xftp_key_hash = ?
          AND r.received = 0 AND r.replica_number = 1
          AND f.status = ? AND f.deleted = 0 AND f.created_at >= ?
        ORDER BY r.created_at ASC
        LIMIT 1
      |]
      (host, port, keyHash, RFSReceiving, cutoffTs)
  where
    toChunk :: ((DBRcvFileId, RcvFileId, UserId, Int64, Int, FileSize Word32, FileDigest, FilePath, Maybe FilePath) :. (Int64, ChunkReplicaId, C.APrivateSignKey, Bool, Maybe Int64, Int)) -> RcvFileChunk
    toChunk ((rcvFileId, rcvFileEntityId, userId, rcvChunkId, chunkNo, chunkSize, digest, fileTmpPath, chunkTmpPath) :. (rcvChunkReplicaId, replicaId, replicaKey, received, delay, retries)) =
      RcvFileChunk
        { rcvFileId,
          rcvFileEntityId,
          userId,
          rcvChunkId,
          chunkNo,
          chunkSize,
          digest,
          fileTmpPath,
          chunkTmpPath,
          replicas = [RcvFileChunkReplica {rcvChunkReplicaId, server, replicaId, replicaKey, received, delay, retries}]
        }

getNextRcvFileToDecrypt :: DB.Connection -> NominalDiffTime -> IO (Maybe RcvFile)
getNextRcvFileToDecrypt db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  fileId_ :: Maybe DBRcvFileId <-
    maybeFirstRow fromOnly $
      DB.query
        db
        [sql|
          SELECT rcv_file_id
          FROM rcv_files
          WHERE status IN (?,?) AND deleted = 0 AND created_at >= ?
          ORDER BY created_at ASC LIMIT 1
        |]
        (RFSReceived, RFSDecrypting, cutoffTs)
  case fileId_ of
    Nothing -> pure Nothing
    Just fileId -> eitherToMaybe <$> getRcvFile db fileId

getPendingRcvFilesServers :: DB.Connection -> NominalDiffTime -> IO [XFTPServer]
getPendingRcvFilesServers db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  map toXFTPServer
    <$> DB.query
      db
      [sql|
        SELECT DISTINCT
          s.xftp_host, s.xftp_port, s.xftp_key_hash
        FROM rcv_file_chunk_replicas r
        JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
        JOIN rcv_file_chunks c ON c.rcv_file_chunk_id = r.rcv_file_chunk_id
        JOIN rcv_files f ON f.rcv_file_id = c.rcv_file_id
        WHERE r.received = 0 AND r.replica_number = 1
          AND f.status = ? AND f.deleted = 0 AND f.created_at >= ?
      |]
      (RFSReceiving, cutoffTs)

toXFTPServer :: (NonEmpty TransportHost, ServiceName, C.KeyHash) -> XFTPServer
toXFTPServer (host, port, keyHash) = XFTPServer host port keyHash

getCleanupRcvFilesTmpPaths :: DB.Connection -> IO [(DBRcvFileId, RcvFileId, FilePath)]
getCleanupRcvFilesTmpPaths db =
  DB.query
    db
    [sql|
      SELECT rcv_file_id, rcv_file_entity_id, tmp_path
      FROM rcv_files
      WHERE status IN (?,?) AND tmp_path IS NOT NULL
    |]
    (RFSComplete, RFSError)

getCleanupRcvFilesDeleted :: DB.Connection -> IO [(DBRcvFileId, RcvFileId, FilePath)]
getCleanupRcvFilesDeleted db =
  DB.query_
    db
    [sql|
      SELECT rcv_file_id, rcv_file_entity_id, prefix_path
      FROM rcv_files
      WHERE deleted = 1
    |]

getRcvFilesExpired :: DB.Connection -> NominalDiffTime -> IO [(DBRcvFileId, RcvFileId, FilePath)]
getRcvFilesExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.query
    db
    [sql|
      SELECT rcv_file_id, rcv_file_entity_id, prefix_path
      FROM rcv_files
      WHERE created_at < ?
    |]
    (Only cutoffTs)

createSndFile :: DB.Connection -> TVar ChaChaDRG -> UserId -> CryptoFile -> Int -> FilePath -> C.SbKey -> C.CbNonce -> IO (Either StoreError SndFileId)
createSndFile db gVar userId (CryptoFile path cfArgs) numRecipients prefixPath key nonce =
  createWithRandomId gVar $ \sndFileEntityId ->
    DB.execute
      db
      "INSERT INTO snd_files (snd_file_entity_id, user_id, path, src_file_key, src_file_nonce, num_recipients, prefix_path, key, nonce, status) VALUES (?,?,?,?,?,?,?,?,?,?)"
      (sndFileEntityId, userId, path, fileKey <$> cfArgs, fileNonce <$> cfArgs, numRecipients, prefixPath, key, nonce, SFSNew)

getSndFileByEntityId :: DB.Connection -> SndFileId -> IO (Either StoreError SndFile)
getSndFileByEntityId db sndFileEntityId = runExceptT $ do
  sndFileId <- ExceptT $ getSndFileIdByEntityId_ db sndFileEntityId
  ExceptT $ getSndFile db sndFileId

getSndFileIdByEntityId_ :: DB.Connection -> SndFileId -> IO (Either StoreError DBSndFileId)
getSndFileIdByEntityId_ db sndFileEntityId =
  firstRow fromOnly SEFileNotFound $
    DB.query db "SELECT snd_file_id FROM snd_files WHERE snd_file_entity_id = ?" (Only sndFileEntityId)

getSndFile :: DB.Connection -> DBSndFileId -> IO (Either StoreError SndFile)
getSndFile db sndFileId = runExceptT $ do
  f@SndFile {sndFileEntityId, userId, numRecipients, prefixPath} <- ExceptT getFile
  chunks <- maybe (pure []) (liftIO . getChunks sndFileEntityId userId numRecipients) prefixPath
  pure (f {chunks} :: SndFile)
  where
    getFile :: IO (Either StoreError SndFile)
    getFile = do
      firstRow toFile SEFileNotFound $
        DB.query
          db
          [sql|
            SELECT snd_file_entity_id, user_id, path, src_file_key, src_file_nonce, num_recipients, digest, prefix_path, key, nonce, status, deleted
            FROM snd_files
            WHERE snd_file_id = ?
          |]
          (Only sndFileId)
      where
        toFile :: (SndFileId, UserId, FilePath, Maybe C.SbKey, Maybe C.CbNonce, Int, Maybe FileDigest, Maybe FilePath, C.SbKey, C.CbNonce, SndFileStatus, Bool) -> SndFile
        toFile (sndFileEntityId, userId, srcPath, srcKey_, srcNonce_, numRecipients, digest, prefixPath, key, nonce, status, deleted) =
          let cfArgs = CFArgs <$> srcKey_ <*> srcNonce_
              srcFile = CryptoFile srcPath cfArgs
           in SndFile {sndFileId, sndFileEntityId, userId, srcFile, numRecipients, digest, prefixPath, key, nonce, status, deleted, chunks = []}
    getChunks :: SndFileId -> UserId -> Int -> FilePath -> IO [SndFileChunk]
    getChunks sndFileEntityId userId numRecipients filePrefixPath = do
      chunks <-
        map toChunk
          <$> DB.query
            db
            [sql|
              SELECT snd_file_chunk_id, chunk_no, chunk_offset, chunk_size, digest
              FROM snd_file_chunks
              WHERE snd_file_id = ?
            |]
            (Only sndFileId)
      forM chunks $ \chunk@SndFileChunk {sndChunkId} -> do
        replicas' <- getChunkReplicas sndChunkId
        pure (chunk {replicas = replicas'} :: SndFileChunk)
      where
        toChunk :: (Int64, Int, Int64, Word32, FileDigest) -> SndFileChunk
        toChunk (sndChunkId, chunkNo, chunkOffset, chunkSize, digest) =
          let chunkSpec = XFTPChunkSpec {filePath = sndFileEncPath filePrefixPath, chunkOffset, chunkSize}
           in SndFileChunk {sndFileId, sndFileEntityId, userId, numRecipients, sndChunkId, chunkNo, chunkSpec, filePrefixPath, digest, replicas = []}
    getChunkReplicas :: Int64 -> IO [SndFileChunkReplica]
    getChunkReplicas chunkId = do
      replicas <-
        map toReplica
          <$> DB.query
            db
            [sql|
              SELECT
                r.snd_file_chunk_replica_id, r.replica_id, r.replica_key, r.replica_status, r.delay, r.retries,
                s.xftp_host, s.xftp_port, s.xftp_key_hash
              FROM snd_file_chunk_replicas r
              JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
              WHERE r.snd_file_chunk_id = ?
            |]
            (Only chunkId)
      forM replicas $ \replica@SndFileChunkReplica {sndChunkReplicaId} -> do
        rcvIdsKeys <- getChunkReplicaRecipients_ db sndChunkReplicaId
        pure (replica :: SndFileChunkReplica) {rcvIdsKeys}
      where
        toReplica :: (Int64, ChunkReplicaId, C.APrivateSignKey, SndFileReplicaStatus, Maybe Int64, Int, NonEmpty TransportHost, ServiceName, C.KeyHash) -> SndFileChunkReplica
        toReplica (sndChunkReplicaId, replicaId, replicaKey, replicaStatus, delay, retries, host, port, keyHash) =
          let server = XFTPServer host port keyHash
           in SndFileChunkReplica {sndChunkReplicaId, server, replicaId, replicaKey, replicaStatus, delay, retries, rcvIdsKeys = []}

getChunkReplicaRecipients_ :: DB.Connection -> Int64 -> IO [(ChunkReplicaId, C.APrivateSignKey)]
getChunkReplicaRecipients_ db replicaId =
  DB.query
    db
    [sql|
      SELECT rcv_replica_id, rcv_replica_key
      FROM snd_file_chunk_replica_recipients
      WHERE snd_file_chunk_replica_id = ?
    |]
    (Only replicaId)

getNextSndFileToPrepare :: DB.Connection -> NominalDiffTime -> IO (Maybe SndFile)
getNextSndFileToPrepare db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  fileId_ :: Maybe DBSndFileId <-
    maybeFirstRow fromOnly $
      DB.query
        db
        [sql|
          SELECT snd_file_id
          FROM snd_files
          WHERE status IN (?,?,?) AND deleted = 0 AND created_at >= ?
          ORDER BY created_at ASC LIMIT 1
        |]
        (SFSNew, SFSEncrypting, SFSEncrypted, cutoffTs)
  case fileId_ of
    Nothing -> pure Nothing
    Just fileId -> eitherToMaybe <$> getSndFile db fileId

updateSndFileError :: DB.Connection -> DBSndFileId -> String -> IO ()
updateSndFileError db sndFileId errStr = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET prefix_path = NULL, error = ?, status = ?, updated_at = ? WHERE snd_file_id = ?" (errStr, SFSError, updatedAt, sndFileId)

updateSndFileStatus :: DB.Connection -> DBSndFileId -> SndFileStatus -> IO ()
updateSndFileStatus db sndFileId status = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET status = ?, updated_at = ? WHERE snd_file_id = ?" (status, updatedAt, sndFileId)

updateSndFileEncrypted :: DB.Connection -> DBSndFileId -> FileDigest -> [(XFTPChunkSpec, FileDigest)] -> IO ()
updateSndFileEncrypted db sndFileId digest chunkSpecsDigests = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET status = ?, digest = ?, updated_at = ? WHERE snd_file_id = ?" (SFSEncrypted, digest, updatedAt, sndFileId)
  forM_ (zip [1 ..] chunkSpecsDigests) $ \(chunkNo :: Int, (XFTPChunkSpec {chunkOffset, chunkSize}, chunkDigest)) ->
    DB.execute db "INSERT INTO snd_file_chunks (snd_file_id, chunk_no, chunk_offset, chunk_size, digest) VALUES (?,?,?,?,?)" (sndFileId, chunkNo, chunkOffset, chunkSize, chunkDigest)

updateSndFileComplete :: DB.Connection -> DBSndFileId -> IO ()
updateSndFileComplete db sndFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET prefix_path = NULL, status = ?, updated_at = ? WHERE snd_file_id = ?" (SFSComplete, updatedAt, sndFileId)

updateSndFileNoPrefixPath :: DB.Connection -> DBSndFileId -> IO ()
updateSndFileNoPrefixPath db sndFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET prefix_path = NULL, updated_at = ? WHERE snd_file_id = ?" (updatedAt, sndFileId)

updateSndFileDeleted :: DB.Connection -> DBSndFileId -> IO ()
updateSndFileDeleted db sndFileId = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_files SET deleted = 1, updated_at = ? WHERE snd_file_id = ?" (updatedAt, sndFileId)

deleteSndFile' :: DB.Connection -> DBSndFileId -> IO ()
deleteSndFile' db sndFileId =
  DB.execute db "DELETE FROM snd_files WHERE snd_file_id = ?" (Only sndFileId)

getSndFileDeleted :: DB.Connection -> DBSndFileId -> IO Bool
getSndFileDeleted db sndFileId =
  fromMaybe True
    <$> maybeFirstRow fromOnly (DB.query db "SELECT deleted FROM snd_files WHERE snd_file_id = ?" (Only sndFileId))

createSndFileReplica :: DB.Connection -> SndFileChunk -> NewSndChunkReplica -> IO ()
createSndFileReplica db SndFileChunk {sndChunkId} NewSndChunkReplica {server, replicaId, replicaKey, rcvIdsKeys} = do
  srvId <- createXFTPServer_ db server
  DB.execute
    db
    [sql|
      INSERT INTO snd_file_chunk_replicas
        (snd_file_chunk_id, replica_number, xftp_server_id, replica_id, replica_key, replica_status)
      VALUES (?,?,?,?,?,?)
    |]
    (sndChunkId, 1 :: Int, srvId, replicaId, replicaKey, SFRSCreated)
  rId <- insertedRowId db
  forM_ rcvIdsKeys $ \(rcvId, rcvKey) -> do
    DB.execute
      db
      [sql|
        INSERT INTO snd_file_chunk_replica_recipients
          (snd_file_chunk_replica_id, rcv_replica_id, rcv_replica_key)
        VALUES (?,?,?)
      |]
      (rId, rcvId, rcvKey)

getNextSndChunkToUpload :: DB.Connection -> XFTPServer -> NominalDiffTime -> IO (Maybe SndFileChunk)
getNextSndChunkToUpload db server@ProtocolServer {host, port, keyHash} ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  chunk_ <-
    maybeFirstRow toChunk $
      DB.query
        db
        [sql|
          SELECT
            f.snd_file_id, f.snd_file_entity_id, f.user_id, f.num_recipients, f.prefix_path,
            c.snd_file_chunk_id, c.chunk_no, c.chunk_offset, c.chunk_size, c.digest,
            r.snd_file_chunk_replica_id, r.replica_id, r.replica_key, r.replica_status, r.delay, r.retries
          FROM snd_file_chunk_replicas r
          JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
          JOIN snd_file_chunks c ON c.snd_file_chunk_id = r.snd_file_chunk_id
          JOIN snd_files f ON f.snd_file_id = c.snd_file_id
          WHERE s.xftp_host = ? AND s.xftp_port = ? AND s.xftp_key_hash = ?
            AND r.replica_status = ? AND r.replica_number = 1
            AND (f.status = ? OR f.status = ?) AND f.deleted = 0 AND f.created_at >= ?
          ORDER BY r.created_at ASC
          LIMIT 1
        |]
        (host, port, keyHash, SFRSCreated, SFSEncrypted, SFSUploading, cutoffTs)
  forM chunk_ $ \chunk@SndFileChunk {replicas} -> do
    replicas' <- forM replicas $ \replica@SndFileChunkReplica {sndChunkReplicaId} -> do
      rcvIdsKeys <- getChunkReplicaRecipients_ db sndChunkReplicaId
      pure (replica :: SndFileChunkReplica) {rcvIdsKeys}
    pure (chunk {replicas = replicas'} :: SndFileChunk)
  where
    toChunk :: ((DBSndFileId, SndFileId, UserId, Int, FilePath) :. (Int64, Int, Int64, Word32, FileDigest) :. (Int64, ChunkReplicaId, C.APrivateSignKey, SndFileReplicaStatus, Maybe Int64, Int)) -> SndFileChunk
    toChunk ((sndFileId, sndFileEntityId, userId, numRecipients, filePrefixPath) :. (sndChunkId, chunkNo, chunkOffset, chunkSize, digest) :. (sndChunkReplicaId, replicaId, replicaKey, replicaStatus, delay, retries)) =
      let chunkSpec = XFTPChunkSpec {filePath = sndFileEncPath filePrefixPath, chunkOffset, chunkSize}
       in SndFileChunk
            { sndFileId,
              sndFileEntityId,
              userId,
              numRecipients,
              sndChunkId,
              chunkNo,
              chunkSpec,
              digest,
              filePrefixPath,
              replicas = [SndFileChunkReplica {sndChunkReplicaId, server, replicaId, replicaKey, replicaStatus, delay, retries, rcvIdsKeys = []}]
            }

updateSndChunkReplicaDelay :: DB.Connection -> Int64 -> Int64 -> IO ()
updateSndChunkReplicaDelay db replicaId delay = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_file_chunk_replicas SET delay = ?, retries = retries + 1, updated_at = ? WHERE snd_file_chunk_replica_id = ?" (delay, updatedAt, replicaId)

addSndChunkReplicaRecipients :: DB.Connection -> SndFileChunkReplica -> [(ChunkReplicaId, C.APrivateSignKey)] -> IO SndFileChunkReplica
addSndChunkReplicaRecipients db r@SndFileChunkReplica {sndChunkReplicaId} rcvIdsKeys = do
  forM_ rcvIdsKeys $ \(rcvId, rcvKey) -> do
    DB.execute
      db
      [sql|
        INSERT INTO snd_file_chunk_replica_recipients
          (snd_file_chunk_replica_id, rcv_replica_id, rcv_replica_key)
        VALUES (?,?,?)
      |]
      (sndChunkReplicaId, rcvId, rcvKey)
  rcvIdsKeys' <- getChunkReplicaRecipients_ db sndChunkReplicaId
  pure (r :: SndFileChunkReplica) {rcvIdsKeys = rcvIdsKeys'}

updateSndChunkReplicaStatus :: DB.Connection -> Int64 -> SndFileReplicaStatus -> IO ()
updateSndChunkReplicaStatus db replicaId status = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE snd_file_chunk_replicas SET replica_status = ?, updated_at = ? WHERE snd_file_chunk_replica_id = ?" (status, updatedAt, replicaId)

getPendingSndFilesServers :: DB.Connection -> NominalDiffTime -> IO [XFTPServer]
getPendingSndFilesServers db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  map toXFTPServer
    <$> DB.query
      db
      [sql|
        SELECT DISTINCT
          s.xftp_host, s.xftp_port, s.xftp_key_hash
        FROM snd_file_chunk_replicas r
        JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
        JOIN snd_file_chunks c ON c.snd_file_chunk_id = r.snd_file_chunk_id
        JOIN snd_files f ON f.snd_file_id = c.snd_file_id
        WHERE r.replica_status = ? AND r.replica_number = 1
          AND (f.status = ? OR f.status = ?) AND f.deleted = 0 AND f.created_at >= ?
      |]
      (SFRSCreated, SFSEncrypted, SFSUploading, cutoffTs)

getCleanupSndFilesPrefixPaths :: DB.Connection -> IO [(DBSndFileId, SndFileId, FilePath)]
getCleanupSndFilesPrefixPaths db =
  DB.query
    db
    [sql|
      SELECT snd_file_id, snd_file_entity_id, prefix_path
      FROM snd_files
      WHERE status IN (?,?) AND prefix_path IS NOT NULL
    |]
    (SFSComplete, SFSError)

getCleanupSndFilesDeleted :: DB.Connection -> IO [(DBSndFileId, SndFileId, Maybe FilePath)]
getCleanupSndFilesDeleted db =
  DB.query_
    db
    [sql|
      SELECT snd_file_id, snd_file_entity_id, prefix_path
      FROM snd_files
      WHERE deleted = 1
    |]

getSndFilesExpired :: DB.Connection -> NominalDiffTime -> IO [(DBSndFileId, SndFileId, Maybe FilePath)]
getSndFilesExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.query
    db
    [sql|
      SELECT snd_file_id, snd_file_entity_id, prefix_path
      FROM snd_files
      WHERE created_at < ?
    |]
    (Only cutoffTs)

createDeletedSndChunkReplica :: DB.Connection -> UserId -> FileChunkReplica -> FileDigest -> IO ()
createDeletedSndChunkReplica db userId FileChunkReplica {server, replicaId, replicaKey} chunkDigest = do
  srvId <- createXFTPServer_ db server
  DB.execute
    db
    "INSERT INTO deleted_snd_chunk_replicas (user_id, xftp_server_id, replica_id, replica_key, chunk_digest) VALUES (?,?,?,?,?)"
    (userId, srvId, replicaId, replicaKey, chunkDigest)

getDeletedSndChunkReplica :: DB.Connection -> DBSndFileId -> IO (Either StoreError DeletedSndChunkReplica)
getDeletedSndChunkReplica db deletedSndChunkReplicaId =
  firstRow toReplica SEDeletedSndChunkReplicaNotFound $
    DB.query
      db
      [sql|
        SELECT
          r.user_id, r.replica_id, r.replica_key, r.chunk_digest, r.delay, r.retries,
          s.xftp_host, s.xftp_port, s.xftp_key_hash
        FROM deleted_snd_chunk_replicas r
        JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
        WHERE r.deleted_snd_chunk_replica_id = ?
      |]
      (Only deletedSndChunkReplicaId)
  where
    toReplica :: (UserId, ChunkReplicaId, C.APrivateSignKey, FileDigest, Maybe Int64, Int, NonEmpty TransportHost, ServiceName, C.KeyHash) -> DeletedSndChunkReplica
    toReplica (userId, replicaId, replicaKey, chunkDigest, delay, retries, host, port, keyHash) =
      let server = XFTPServer host port keyHash
       in DeletedSndChunkReplica {deletedSndChunkReplicaId, userId, server, replicaId, replicaKey, chunkDigest, delay, retries}

getNextDeletedSndChunkReplica :: DB.Connection -> XFTPServer -> NominalDiffTime -> IO (Maybe DeletedSndChunkReplica)
getNextDeletedSndChunkReplica db ProtocolServer {host, port, keyHash} ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  replicaId_ :: Maybe Int64 <-
    maybeFirstRow fromOnly $
      DB.query
        db
        [sql|
          SELECT r.deleted_snd_chunk_replica_id
          FROM deleted_snd_chunk_replicas r
          JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
          WHERE s.xftp_host = ? AND s.xftp_port = ? AND s.xftp_key_hash = ?
            AND r.created_at >= ?
          ORDER BY r.created_at ASC LIMIT 1
        |]
        (host, port, keyHash, cutoffTs)
  case replicaId_ of
    Nothing -> pure Nothing
    Just replicaId -> eitherToMaybe <$> getDeletedSndChunkReplica db replicaId

updateDeletedSndChunkReplicaDelay :: DB.Connection -> Int64 -> Int64 -> IO ()
updateDeletedSndChunkReplicaDelay db deletedSndChunkReplicaId delay = do
  updatedAt <- getCurrentTime
  DB.execute db "UPDATE deleted_snd_chunk_replicas SET delay = ?, retries = retries + 1, updated_at = ? WHERE deleted_snd_chunk_replica_id = ?" (delay, updatedAt, deletedSndChunkReplicaId)

deleteDeletedSndChunkReplica :: DB.Connection -> Int64 -> IO ()
deleteDeletedSndChunkReplica db deletedSndChunkReplicaId =
  DB.execute db "DELETE FROM deleted_snd_chunk_replicas WHERE deleted_snd_chunk_replica_id = ?" (Only deletedSndChunkReplicaId)

getPendingDelFilesServers :: DB.Connection -> NominalDiffTime -> IO [XFTPServer]
getPendingDelFilesServers db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  map toXFTPServer
    <$> DB.query
      db
      [sql|
        SELECT DISTINCT
          s.xftp_host, s.xftp_port, s.xftp_key_hash
        FROM deleted_snd_chunk_replicas r
        JOIN xftp_servers s ON s.xftp_server_id = r.xftp_server_id
        WHERE r.created_at >= ?
      |]
      (Only cutoffTs)

deleteDeletedSndChunkReplicasExpired :: DB.Connection -> NominalDiffTime -> IO ()
deleteDeletedSndChunkReplicasExpired db ttl = do
  cutoffTs <- addUTCTime (-ttl) <$> getCurrentTime
  DB.execute db "DELETE FROM deleted_snd_chunk_replicas WHERE created_at < ?" (Only cutoffTs)

$(J.deriveJSON defaultJSON ''UpMigration)

$(J.deriveToJSON (sumTypeJSON $ dropPrefix "ME") ''MigrationError)
