{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Server.StoreLog
  ( StoreLog,
    FileStoreLogRecord (..),
    closeStoreLog,
    readWriteFileStore,
    logAddFile,
    logSetFilePath,
    logAddRecipient,
    logDeleteFile,
    logGetFile,
    logAckFile
  )
where

import Simplex.FileTransfer.Server.Store
import Control.Concurrent.STM
import Control.Monad (void)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RecipientId, QueueId, SenderId, SndPublicVerifyKey, RcvPublicVerifyKey)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (whenM)
import System.Directory (doesFileExist, renameFile)
import System.IO

data FileStoreLogRecord
  = AddFile SenderId SndPublicVerifyKey
  | SetFilePath QueueId FilePath
  | AddRecipient QueueId (RecipientId, RcvPublicVerifyKey)
  | DeleteFile QueueId
  | GetFile QueueId
  | AckFile QueueId

instance StrEncoding FileStoreLogRecord where
  strEncode = \case
    AddFile sId sKey -> strEncode (Str "FNEW", sId, sKey)
    SetFilePath qId path -> strEncode (Str "FSET", qId, path)
    AddRecipient qId recipient -> strEncode (Str "FADD", qId, recipient)
    DeleteFile qId -> strEncode (Str "FDEL", qId)
    GetFile qId -> strEncode (Str "FGET", qId)
    AckFile qId -> strEncode (Str "FACK", qId)
  strP =
    A.choice
      [ "FNEW " *> (AddFile <$> strP_ <*> strP),
        "FSET " *> (SetFilePath <$> strP_ <*> strP),
        "FADD " *> (AddRecipient <$> strP_ <*> strP),
        "FDEL " *> (DeleteFile <$> strP),
        "FGET " *> (GetFile <$> strP),
        "FACK " *> (AckFile <$> strP)
      ]

logFileStoreRecord :: StoreLog 'WriteMode -> FileStoreLogRecord -> IO ()
logFileStoreRecord = writeStoreLogRecord

logAddFile :: StoreLog 'WriteMode -> SenderId -> SndPublicVerifyKey -> IO ()
logAddFile s sId sKey = logFileStoreRecord s $ AddFile sId sKey

logSetFilePath :: StoreLog 'WriteMode -> QueueId -> FilePath -> IO ()
logSetFilePath s qId path = logFileStoreRecord s $ SetFilePath qId path

logAddRecipient :: StoreLog 'WriteMode -> QueueId -> (RecipientId, RcvPublicVerifyKey) -> IO ()
logAddRecipient s qId recipient = logFileStoreRecord s $ AddRecipient qId recipient

logDeleteFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteFile s qId = logFileStoreRecord s $ DeleteFile qId

logGetFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logGetFile s qId = logFileStoreRecord s $ GetFile qId

logAckFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logAckFile s qId = logFileStoreRecord s $ AckFile qId

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
      Right lr -> atomically $ case lr of
        AddFile sId sKey  ->
          void $ addFile st sId sKey
        SetFilePath qId path ->
          void $ setFilePath st qId path
        AddRecipient qId recipient ->
          void $ addRecipient st qId recipient
        DeleteFile qId ->
          void $ deleteFile st qId
        GetFile qId ->
          void $ getFile st qId
        AckFile qId ->
          void $ ackFile st qId

writeFileStore :: StoreLog 'WriteMode -> FileStore -> IO ()
writeFileStore s st =
  pure ()
  
