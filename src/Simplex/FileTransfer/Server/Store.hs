{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.FileTransfer.Server.Store
  ( FileStoreClass (..),
    FileRec (..),
    FileRecipient (..),
    STMFileStore (..),
    RoundedFileTime,
    fileTimePrecision,
  )
where

import Control.Concurrent.STM
import Control.Monad (forM, void)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word32)
import Simplex.FileTransfer.Protocol (FileInfo (..), SFileParty (..), XFTPFileId)
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BlockingInfo, RcvPublicAuthKey, RecipientId, SenderId)
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.Server.StoreLog (StoreLog, closeStoreLog)
import System.IO (IOMode (..))
import Simplex.Messaging.SystemTime
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM)

data FileRec = FileRec
  { senderId :: SenderId,
    fileInfo :: FileInfo,
    filePath :: TVar (Maybe FilePath),
    recipientIds :: TVar (Set RecipientId),
    createdAt :: RoundedFileTime,
    fileStatus :: TVar ServerEntityStatus
  }

type RoundedFileTime = RoundedSystemTime 3600

fileTimePrecision :: Int64
fileTimePrecision = 3600

data FileRecipient = FileRecipient RecipientId C.APublicAuthKey
  deriving (Show)

instance StrEncoding FileRecipient where
  strEncode (FileRecipient rId rKey) = strEncode rId <> ":" <> strEncode rKey
  strP = FileRecipient <$> strP <* A.char ':' <*> strP

class FileStoreClass s where
  type FileStoreConfig s
  newFileStore :: FileStoreConfig s -> IO s
  closeFileStore :: s -> IO ()
  addFile :: s -> SenderId -> FileInfo -> RoundedFileTime -> ServerEntityStatus -> IO (Either XFTPErrorType ())
  setFilePath :: s -> SenderId -> FilePath -> IO (Either XFTPErrorType ())
  addRecipient :: s -> SenderId -> FileRecipient -> IO (Either XFTPErrorType ())
  deleteFile :: s -> SenderId -> IO (Either XFTPErrorType ())
  deleteFiles :: s -> [SenderId] -> IO ()
  deleteFiles s = mapM_ (void . deleteFile s)
  blockFile :: s -> SenderId -> BlockingInfo -> Bool -> IO (Either XFTPErrorType ())
  deleteRecipient :: s -> RecipientId -> FileRec -> IO ()
  getFile :: s -> SFileParty p -> XFTPFileId -> IO (Either XFTPErrorType (FileRec, C.APublicAuthKey))
  ackFile :: s -> RecipientId -> IO (Either XFTPErrorType ())
  expiredFiles :: s -> Int64 -> Int -> IO [(SenderId, Maybe FilePath, Word32)]
  getUsedStorage :: s -> IO Int64
  getFileCount :: s -> IO Int

-- STM in-memory store

data STMFileStore = STMFileStore
  { files :: TMap SenderId FileRec,
    recipients :: TMap RecipientId (SenderId, RcvPublicAuthKey),
    stmStoreLog :: TVar (Maybe (StoreLog 'WriteMode))
  }

instance FileStoreClass STMFileStore where
  type FileStoreConfig STMFileStore = ()

  newFileStore () = do
    files <- TM.emptyIO
    recipients <- TM.emptyIO
    stmStoreLog <- newTVarIO Nothing
    pure STMFileStore {files, recipients, stmStoreLog}

  closeFileStore STMFileStore {stmStoreLog} = readTVarIO stmStoreLog >>= mapM_ closeStoreLog

  addFile STMFileStore {files} sId fileInfo createdAt status = atomically $
    ifM (TM.member sId files) (pure $ Left DUPLICATE_) $ do
      f <- newFileRec sId fileInfo createdAt status
      TM.insert sId f files
      pure $ Right ()

  setFilePath st sId fPath = atomically $
    withFile st sId $ \FileRec {filePath, fileStatus} -> do
      readTVar filePath >>= \case
        Just _ -> pure $ Left AUTH
        Nothing ->
          readTVar fileStatus >>= \case
            EntityActive -> do
              writeTVar filePath (Just fPath)
              pure $ Right ()
            _ -> pure $ Left AUTH

  addRecipient st@STMFileStore {recipients} senderId (FileRecipient rId rKey) = atomically $
    withFile st senderId $ \FileRec {recipientIds} -> do
      rIds <- readTVar recipientIds
      mem <- TM.member rId recipients
      if rId `S.member` rIds || mem
        then pure $ Left DUPLICATE_
        else do
          writeTVar recipientIds $! S.insert rId rIds
          TM.insert rId (senderId, rKey) recipients
          pure $ Right ()

  deleteFile STMFileStore {files, recipients} senderId = atomically $ do
    TM.lookupDelete senderId files >>= \case
      Just FileRec {recipientIds} -> do
        readTVar recipientIds >>= mapM_ (`TM.delete` recipients)
        pure $ Right ()
      _ -> pure $ Left AUTH

  blockFile st senderId info _deleted = atomically $
    withFile st senderId $ \FileRec {fileStatus} -> do
      writeTVar fileStatus $! EntityBlocked info
      pure $ Right ()

  deleteRecipient STMFileStore {recipients} rId FileRec {recipientIds} = atomically $ do
    TM.delete rId recipients
    modifyTVar' recipientIds $ S.delete rId

  getFile st party fId = atomically $ case party of
    SFSender -> withFile st fId $ pure . Right . (\f -> (f, sndKey $ fileInfo f))
    SFRecipient ->
      TM.lookup fId (recipients st) >>= \case
        Just (sId, rKey) -> withFile st sId $ pure . Right . (,rKey)
        _ -> pure $ Left AUTH

  ackFile st@STMFileStore {recipients} recipientId = atomically $ do
    TM.lookupDelete recipientId recipients >>= \case
      Just (sId, _) ->
        withFile st sId $ \FileRec {recipientIds} -> do
          modifyTVar' recipientIds $ S.delete recipientId
          pure $ Right ()
      _ -> pure $ Left AUTH

  expiredFiles STMFileStore {files} old _limit = do
    fs <- readTVarIO files
    fmap catMaybes . forM (M.toList fs) $ \(sId, FileRec {fileInfo = FileInfo {size}, filePath, createdAt = RoundedSystemTime createdAt}) ->
      if createdAt + fileTimePrecision < old
        then do
          path <- readTVarIO filePath
          pure $ Just (sId, path, size)
        else pure Nothing

  getUsedStorage STMFileStore {files} =
    M.foldl' (\acc FileRec {fileInfo = FileInfo {size}} -> acc + fromIntegral size) 0 <$> readTVarIO files

  getFileCount STMFileStore {files} = M.size <$> readTVarIO files

-- Internal STM helpers

newFileRec :: SenderId -> FileInfo -> RoundedFileTime -> ServerEntityStatus -> STM FileRec
newFileRec senderId fileInfo createdAt status = do
  recipientIds <- newTVar S.empty
  filePath <- newTVar Nothing
  fileStatus <- newTVar status
  pure FileRec {senderId, fileInfo, filePath, recipientIds, createdAt, fileStatus}

withFile :: STMFileStore -> SenderId -> (FileRec -> STM (Either XFTPErrorType a)) -> STM (Either XFTPErrorType a)
withFile STMFileStore {files} sId a =
  TM.lookup sId files >>= \case
    Just f -> a f
    _ -> pure $ Left AUTH
