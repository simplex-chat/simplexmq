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
  )
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Simplex.Messaging.Encoding.String
import Simplex.FileTransfer.Server.Store
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (whenM)
import System.Directory (doesFileExist, renameFile)
import System.IO
import Simplex.Messaging.Protocol (SndPublicVerifyKey, RcvPublicVerifyKey, QueueId)
import Data.List.NonEmpty (NonEmpty)
import Data.Word (Word32)
import Simplex.Messaging.Encoding

data FileStoreLogRecord
  = NewFile SndPublicVerifyKey (NonEmpty RcvPublicVerifyKey) Word32
  | AddRecipients QueueId (NonEmpty RcvPublicVerifyKey)
  | PutFile QueueId
  | DeleteFile QueueId
  | GetFile QueueId
  | AckFile QueueId

instance StrEncoding FileStoreLogRecord where
  strEncode = \case
    NewFile sKey rKeys fSize -> strEncode (Str "FNEW", sKey, rKeys, fSize)
    AddRecipients qId rKeys -> strEncode (Str "FADD", qId, rKeys)
    PutFile qId -> strEncode (Str "FPUT", qId)
    DeleteFile qId -> strEncode (Str "FDEL", qId)
    GetFile qId -> strEncode (Str "FGET", qId)
    AckFile qId -> strEncode (Str "FACK", qId)
  strP =
    A.choice
      [ "FNEW " *> (NewFile <$> strP_ <*> strP),
        "FADD " *> (AddRecipients <$> strP_ <*> strP),
        "FPUT " *> (PutFile <$> strP),
        "FDEL " *> (DeleteFile <$> strP),
        "FGET " *> (GetFile <$> strP),
        "FACK " *> (AckFile <$> strP)
      ]

logFileStoreRecord :: StoreLog 'WriteMode -> FileStoreLogRecord -> IO ()
logFileStoreRecord = writeStoreLogRecord

logNewFile :: StoreLog 'WriteMode -> SndPublicVerifyKey -> NonEmpty RcvPublicVerifyKey -> Word32 -> IO ()
logNewFile s sKey rKeys fSize = logFileStoreRecord s $ NewFile sKey rKeys fSize

logAddRecipients :: StoreLog 'WriteMode -> QueueId -> NonEmpty RcvPublicVerifyKey -> IO ()
logAddRecipients s qId rKeys = logFileStoreRecord s $ AddRecipients qId rKeys

logPutFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logPutFile s qId = logFileStoreRecord s $ PutFile qId

logDeleteFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteFile s qId = logFileStoreRecord s $ DeleteFile qId

logGetFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logGetFile s qId = logFileStoreRecord s $ GetFile qId

logAckFile :: StoreLog 'WriteMode -> QueueId -> IO ()
logAckFile s qId = logFileStoreRecord s $ AckFile qId

readWriteFileStore :: FilePath -> FileStore -> IO (StoreLog 'WriteMode)
readWriteFileStore f st = do
  whenM (doesFileExist f) $ do
    --readFileStore f st
    renameFile f $ f <> ".bak"
  s <- openWriteStoreLog f
  --writeFileStore s st
  pure s
