{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.StoreLog
  ( StoreLog,
    FileStoreLogRecord (..),
    closeStoreLog,
    readWriteFileStore,
    logAddFile,
    logPutFile,
    logAddRecipients,
    logDeleteFile,
    logAckFile,
  )
where

import Control.Concurrent.STM
import Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:), (.:.))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Time.Clock.System (SystemTime)
import Simplex.FileTransfer.Protocol (FileInfo (..))
import Simplex.FileTransfer.Server.Store
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RcvPublicVerifyKey, RecipientId, SenderId)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (bshow, whenM)
import System.Directory (doesFileExist, renameFile)
import System.IO

data FileStoreLogRecord
  = AddFile SenderId FileInfo SystemTime
  | PutFile SenderId FilePath
  | AddRecipients SenderId (NonEmpty FileRecipient)
  | DeleteFile SenderId
  | AckFile RecipientId

instance StrEncoding FileStoreLogRecord where
  strEncode = \case
    AddFile sId file createdAt -> strEncode (Str "FNEW", sId, file, createdAt)
    PutFile sId path -> strEncode (Str "FPUT", sId, path)
    AddRecipients sId rcps -> strEncode (Str "FADD", sId, rcps)
    DeleteFile sId -> strEncode (Str "FDEL", sId)
    AckFile rId -> strEncode (Str "FACK", rId)
  strP =
    A.choice
      [ "FNEW " *> (AddFile <$> strP_ <*> strP_ <*> strP),
        "FPUT " *> (PutFile <$> strP_ <*> strP),
        "FADD " *> (AddRecipients <$> strP_ <*> strP),
        "FDEL " *> (DeleteFile <$> strP),
        "FACK " *> (AckFile <$> strP)
      ]

logFileStoreRecord :: StoreLog 'WriteMode -> FileStoreLogRecord -> IO ()
logFileStoreRecord = writeStoreLogRecord

logAddFile :: StoreLog 'WriteMode -> SenderId -> FileInfo -> SystemTime -> IO ()
logAddFile s = logFileStoreRecord s .:. AddFile

logPutFile :: StoreLog 'WriteMode -> SenderId -> FilePath -> IO ()
logPutFile s = logFileStoreRecord s .: PutFile

logAddRecipients :: StoreLog 'WriteMode -> SenderId -> NonEmpty FileRecipient -> IO ()
logAddRecipients s = logFileStoreRecord s .: AddRecipients

logDeleteFile :: StoreLog 'WriteMode -> SenderId -> IO ()
logDeleteFile s = logFileStoreRecord s . DeleteFile

logAckFile :: StoreLog 'WriteMode -> RecipientId -> IO ()
logAckFile s = logFileStoreRecord s . AckFile

readWriteFileStore :: FilePath -> FileStore -> IO (StoreLog 'WriteMode)
readWriteFileStore f st = do
  whenM (doesFileExist f) $ do
    readFileStore f st
    renameFile f $ f <> ".bak"
  s <- openWriteStoreLog f
  writeFileStore s st
  pure s

readFileStore :: FilePath -> FileStore -> IO ()
readFileStore f st = mapM_ addFileLogRecord . B.lines =<< B.readFile f
  where
    addFileLogRecord s = case strDecode s of
      Left e -> B.putStrLn $ "Log parsing error (" <> B.pack e <> "): " <> B.take 100 s
      Right lr ->
        atomically (addToStore lr) >>= \case
          Left e -> B.putStrLn $ "Log processing error (" <> bshow e <> "): " <> B.take 100 s
          _ -> pure ()
    addToStore = \case
      AddFile sId file createdAt -> addFile st sId file createdAt
      PutFile qId path -> setFilePath st qId path
      AddRecipients sId rcps -> runExceptT $ addRecipients sId rcps
      DeleteFile sId -> deleteFile st sId
      AckFile rId -> ackFile st rId
    addRecipients sId rcps = mapM_ (ExceptT . addRecipient st sId) rcps

writeFileStore :: StoreLog 'WriteMode -> FileStore -> IO ()
writeFileStore s FileStore {files, recipients} = do
  allRcps <- readTVarIO recipients
  readTVarIO files >>= mapM_ (logFile allRcps)
  where
    logFile :: Map RecipientId (SenderId, RcvPublicVerifyKey) -> FileRec -> IO ()
    logFile allRcps FileRec {senderId, fileInfo, filePath, recipientIds, createdAt} = do
      logAddFile s senderId fileInfo createdAt
      (rcpErrs, rcps) <- M.mapEither getRcp . M.fromSet id <$> readTVarIO recipientIds
      mapM_ (logAddRecipients s senderId) $ L.nonEmpty $ M.elems rcps
      mapM_ (B.putStrLn . ("Error storing log: " <>)) rcpErrs
      readTVarIO filePath >>= mapM_ (logPutFile s senderId)
      where
        getRcp rId = case M.lookup rId allRcps of
          Just (sndId, rKey)
            | sndId == senderId -> Right $ FileRecipient rId rKey
            | otherwise -> Left $ "sender ID for recipient ID " <> bshow rId <> " does not match FileRec"
          Nothing -> Left $ "recipient ID " <> bshow rId <> " not found"
