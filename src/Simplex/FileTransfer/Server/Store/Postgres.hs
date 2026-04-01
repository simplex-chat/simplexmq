{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.FileTransfer.Server.Store.Postgres
  ( PostgresFileStore (..),
    withDB,
    withDB',
    handleDuplicate,
    assertUpdated,
    withLog,
  )
where

import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Except (throwE)
import Data.Functor (($>))
import Data.Int (Int32, Int64)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Word (Word32)
import Database.PostgreSQL.Simple (Binary (..), Only (..), SqlError)
import Database.PostgreSQL.Simple.Errors (ConstraintViolation (..), constraintViolation)
import qualified Database.PostgreSQL.Simple as DB
import GHC.IO (catchAny)
import Simplex.FileTransfer.Protocol (FileInfo (..), SFileParty (..))
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.Store.Postgres.Config
import Simplex.FileTransfer.Server.Store.Postgres.Migrations (xftpServerMigrations)
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import Simplex.Messaging.Agent.Store.Postgres (closeDBStore, createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common (DBStore, withTransaction)
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (SenderId)
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.Server.QueueStore.Postgres ()
import Simplex.Messaging.Server.StoreLog (openWriteStoreLog)
import Simplex.Messaging.Util (tshow)
import System.Exit (exitFailure)
import System.IO (IOMode (..))
import UnliftIO.STM

data PostgresFileStore = PostgresFileStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode)
  }

instance FileStoreClass PostgresFileStore where
  type FileStoreConfig PostgresFileStore = PostgresFileStoreCfg

  newFileStore PostgresFileStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations} = do
    dbStore <- either err pure =<< createDBStore dbOpts xftpServerMigrations (MigrationConfig confirmMigrations Nothing)
    dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
    pure PostgresFileStore {dbStore, dbStoreLog}
    where
      err e = do
        logError $ "STORE: newFileStore, error opening PostgreSQL database, " <> tshow e
        exitFailure

  closeFileStore PostgresFileStore {dbStore, dbStoreLog} = do
    closeDBStore dbStore
    mapM_ closeStoreLog dbStoreLog

  addFile st sId fileInfo@FileInfo {sndKey, size, digest} createdAt status =
    E.uninterruptibleMask_ $ runExceptT $ do
      void $ withDB "addFile" st $ \db ->
        E.try
          ( DB.execute
              db
              "INSERT INTO files (sender_id, file_size, file_digest, sender_key, created_at, status) VALUES (?,?,?,?,?,?)"
              (sId, (fromIntegral size :: Int32), Binary digest, Binary (C.encodePubKey sndKey), createdAt, status)
          )
          >>= either handleDuplicate (pure . Right)
      withLog "addFile" st $ \s -> logAddFile s sId fileInfo createdAt status

  setFilePath st sId fPath = E.uninterruptibleMask_ $ runExceptT $ do
    assertUpdated $ withDB' "setFilePath" st $ \db ->
      DB.execute db "UPDATE files SET file_path = ? WHERE sender_id = ? AND file_path IS NULL" (fPath, sId)
    withLog "setFilePath" st $ \s -> logPutFile s sId fPath

  addRecipient st senderId (FileRecipient rId rKey) = E.uninterruptibleMask_ $ runExceptT $ do
    void $ withDB "addRecipient" st $ \db ->
      E.try
        ( DB.execute
            db
            "INSERT INTO recipients (recipient_id, sender_id, recipient_key) VALUES (?,?,?)"
            (rId, senderId, Binary (C.encodePubKey rKey))
        )
        >>= either handleDuplicate (pure . Right)
    withLog "addRecipient" st $ \s -> logAddRecipients s senderId (pure $ FileRecipient rId rKey)

  getFile st party fId = runExceptT $ case party of
    SFSender ->
      withDB "getFile" st $ \db -> do
        rs <-
          DB.query
            db
            "SELECT file_size, file_digest, sender_key, file_path, created_at, status FROM files WHERE sender_id = ?"
            (Only fId)
        case rs of
          [(size, digest, sndKeyBs, path, createdAt, status)] ->
            case C.decodePubKey sndKeyBs of
              Right sndKey -> do
                let fileInfo = FileInfo {sndKey, size = fromIntegral (size :: Int32), digest}
                fr <- mkFileRec fId fileInfo path createdAt status
                pure $ Right (fr, sndKey)
              Left _ -> pure $ Left INTERNAL
          _ -> pure $ Left AUTH
    SFRecipient ->
      withDB "getFile" st $ \db -> do
        rs <-
          DB.query
            db
            "SELECT f.file_size, f.file_digest, f.sender_key, f.file_path, f.created_at, f.status, f.sender_id, r.recipient_key FROM recipients r JOIN files f ON r.sender_id = f.sender_id WHERE r.recipient_id = ?"
            (Only fId)
        case rs of
          [(size, digest, sndKeyBs, path, createdAt, status, senderId, rcpKeyBs)] ->
            case (C.decodePubKey sndKeyBs, C.decodePubKey rcpKeyBs) of
              (Right sndKey, Right rcpKey) -> do
                let fileInfo = FileInfo {sndKey, size = fromIntegral (size :: Int32), digest}
                fr <- mkFileRec senderId fileInfo path createdAt status
                pure $ Right (fr, rcpKey)
              _ -> pure $ Left INTERNAL
          _ -> pure $ Left AUTH

  deleteFile st sId = E.uninterruptibleMask_ $ runExceptT $ do
    assertUpdated $ withDB' "deleteFile" st $ \db ->
      DB.execute db "DELETE FROM files WHERE sender_id = ?" (Only sId)
    withLog "deleteFile" st $ \s -> logDeleteFile s sId

  blockFile st sId info _deleted = E.uninterruptibleMask_ $ runExceptT $ do
    assertUpdated $ withDB' "blockFile" st $ \db ->
      DB.execute db "UPDATE files SET status = ? WHERE sender_id = ?" (EntityBlocked info, sId)
    withLog "blockFile" st $ \s -> logBlockFile s sId info

  deleteRecipient st rId _fr =
    void $ runExceptT $ withDB' "deleteRecipient" st $ \db ->
      DB.execute db "DELETE FROM recipients WHERE recipient_id = ?" (Only rId)

  ackFile st rId = E.uninterruptibleMask_ $ runExceptT $ do
    assertUpdated $ withDB' "ackFile" st $ \db ->
      DB.execute db "DELETE FROM recipients WHERE recipient_id = ?" (Only rId)
    withLog "ackFile" st $ \s -> logAckFile s rId

  expiredFiles st old limit =
    fmap toResult $ withTransaction (dbStore st) $ \db ->
      DB.query
        db
        "SELECT sender_id, file_path, file_size FROM files WHERE created_at + ? < ? ORDER BY created_at LIMIT ?"
        (fileTimePrecision, old, limit)
    where
      toResult :: [(SenderId, Maybe FilePath, Int32)] -> [(SenderId, Maybe FilePath, Word32)]
      toResult = map (\(sId, path, size) -> (sId, path, fromIntegral size))

  getUsedStorage st =
    withTransaction (dbStore st) $ \db -> do
      [Only total] <- DB.query_ db "SELECT COALESCE(SUM(file_size::INT8), 0) FROM files"
      pure total

  getFileCount st =
    withTransaction (dbStore st) $ \db -> do
      [Only count] <- DB.query_ db "SELECT COUNT(*) FROM files"
      pure (fromIntegral (count :: Int64))

-- Internal helpers

mkFileRec :: SenderId -> FileInfo -> Maybe FilePath -> RoundedFileTime -> ServerEntityStatus -> IO FileRec
mkFileRec senderId fileInfo path createdAt status = do
  filePath <- newTVarIO path
  recipientIds <- newTVarIO S.empty
  fileStatus <- newTVarIO status
  pure FileRec {senderId, fileInfo, filePath, recipientIds, createdAt, fileStatus}

-- DB helpers

withDB :: forall a. Text -> PostgresFileStore -> (DB.Connection -> IO (Either XFTPErrorType a)) -> ExceptT XFTPErrorType IO a
withDB op st action =
  ExceptT $ E.try (withTransaction (dbStore st) action) >>= either logErr pure
  where
    logErr :: E.SomeException -> IO (Either XFTPErrorType a)
    logErr e = logError ("STORE: " <> err) $> Left INTERNAL
      where
        err = op <> ", withDB, " <> tshow e

withDB' :: Text -> PostgresFileStore -> (DB.Connection -> IO a) -> ExceptT XFTPErrorType IO a
withDB' op st action = withDB op st $ fmap Right . action

assertUpdated :: ExceptT XFTPErrorType IO Int64 -> ExceptT XFTPErrorType IO ()
assertUpdated = (>>= \n -> when (n == 0) (throwE AUTH))

handleDuplicate :: SqlError -> IO (Either XFTPErrorType a)
handleDuplicate e = case constraintViolation e of
  Just (UniqueViolation _) -> pure $ Left DUPLICATE_
  _ -> E.throwIO e

withLog :: MonadIO m => Text -> PostgresFileStore -> (StoreLog 'WriteMode -> IO ()) -> m ()
withLog op PostgresFileStore {dbStoreLog} action =
  forM_ dbStoreLog $ \sl -> liftIO $ action sl `catchAny` \e ->
    logWarn $ "STORE: " <> op <> ", withLog, " <> tshow e
