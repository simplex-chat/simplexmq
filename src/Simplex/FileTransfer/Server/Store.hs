{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.FileTransfer.Server.Store
  ( FileStore (..),
    FileRec (..),
    FileRecipient (..),
    newFileStore,
    addFile,
    setFilePath,
    setFilePath',
    addRecipient,
    deleteFile,
    deleteRecipient,
    expiredFilePath,
    getFile,
    ackFile,
  )
where

import Control.Concurrent.STM
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Clock.System (SystemTime (..))
import Simplex.FileTransfer.Protocol (FileInfo (..), SFileParty (..), XFTPErrorType (..), XFTPFileId)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RcvPublicVerifyKey, RecipientId, SenderId)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=))

data FileStore = FileStore
  { files :: TMap SenderId FileRec,
    recipients :: TMap RecipientId (SenderId, RcvPublicVerifyKey),
    usedStorage :: TVar Int64
  }

data FileRec = FileRec
  { senderId :: SenderId,
    fileInfo :: FileInfo,
    filePath :: TVar (Maybe FilePath),
    recipientIds :: TVar (Set RecipientId),
    createdAt :: SystemTime
  }
  deriving (Eq)

data FileRecipient = FileRecipient RecipientId RcvPublicVerifyKey

instance StrEncoding FileRecipient where
  strEncode (FileRecipient rId rKey) = strEncode rId <> ":" <> strEncode rKey
  strP = FileRecipient <$> strP <* A.char ':' <*> strP

newFileStore :: STM FileStore
newFileStore = do
  files <- TM.empty
  recipients <- TM.empty
  usedStorage <- newTVar 0
  pure FileStore {files, recipients, usedStorage}

addFile :: FileStore -> SenderId -> FileInfo -> SystemTime -> STM (Either XFTPErrorType ())
addFile FileStore {files} sId fileInfo createdAt =
  ifM (TM.member sId files) (pure $ Left DUPLICATE_) $ do
    f <- newFileRec sId fileInfo createdAt
    TM.insert sId f files
    pure $ Right ()

newFileRec :: SenderId -> FileInfo -> SystemTime -> STM FileRec
newFileRec senderId fileInfo createdAt = do
  recipientIds <- newTVar S.empty
  filePath <- newTVar Nothing
  pure FileRec {senderId, fileInfo, filePath, recipientIds, createdAt}

setFilePath :: FileStore -> SenderId -> FilePath -> STM (Either XFTPErrorType ())
setFilePath st sId fPath =
  withFile st sId $ \fr -> setFilePath' st fr fPath $> Right ()

setFilePath' :: FileStore -> FileRec -> FilePath -> STM ()
setFilePath' st FileRec {fileInfo, filePath} fPath = do
  writeTVar filePath (Just fPath)
  modifyTVar' (usedStorage st) (+ fromIntegral (size fileInfo))

addRecipient :: FileStore -> SenderId -> FileRecipient -> STM (Either XFTPErrorType ())
addRecipient st@FileStore {recipients} senderId (FileRecipient rId rKey) =
  withFile st senderId $ \FileRec {recipientIds} -> do
    rIds <- readTVar recipientIds
    mem <- TM.member rId recipients
    if rId `S.member` rIds || mem
      then pure $ Left DUPLICATE_
      else do
        writeTVar recipientIds $! S.insert rId rIds
        TM.insert rId (senderId, rKey) recipients
        pure $ Right ()

-- this function must be called after the file is deleted from the file system
deleteFile :: FileStore -> SenderId -> STM (Either XFTPErrorType ())
deleteFile FileStore {files, recipients, usedStorage} senderId = do
  TM.lookupDelete senderId files >>= \case
    Just FileRec {fileInfo, recipientIds} -> do
      readTVar recipientIds >>= mapM_ (`TM.delete` recipients)
      modifyTVar' usedStorage $ subtract (fromIntegral $ size fileInfo)
      pure $ Right ()
    _ -> pure $ Left AUTH

deleteRecipient :: FileStore -> RecipientId -> FileRec -> STM ()
deleteRecipient FileStore {recipients} rId FileRec {recipientIds} = do
  TM.delete rId recipients
  modifyTVar' recipientIds $ S.delete rId

getFile :: FileStore -> SFileParty p -> XFTPFileId -> STM (Either XFTPErrorType (FileRec, C.APublicVerifyKey))
getFile st party fId = case party of
  SFSender -> withFile st fId $ pure . Right . (\f -> (f, sndKey $ fileInfo f))
  SFRecipient ->
    TM.lookup fId (recipients st) >>= \case
      Just (sId, rKey) -> withFile st sId $ pure . Right . (,rKey)
      _ -> pure $ Left AUTH

expiredFilePath :: FileStore -> XFTPFileId -> Int64 -> STM (Maybe FilePath)
expiredFilePath FileStore {files} sId old =
  TM.lookup sId files
    $>>= \FileRec {filePath, createdAt} ->
      if systemSeconds createdAt < old
        then readTVar filePath
        else pure Nothing

ackFile :: FileStore -> RecipientId -> STM (Either XFTPErrorType ())
ackFile st@FileStore {recipients} recipientId = do
  TM.lookupDelete recipientId recipients >>= \case
    Just (sId, _) ->
      withFile st sId $ \FileRec {recipientIds} -> do
        modifyTVar' recipientIds $ S.delete recipientId
        pure $ Right ()
    _ -> pure $ Left AUTH

withFile :: FileStore -> SenderId -> (FileRec -> STM (Either XFTPErrorType a)) -> STM (Either XFTPErrorType a)
withFile FileStore {files} sId a =
  TM.lookup sId files >>= \case
    Just f -> a f
    _ -> pure $ Left AUTH
