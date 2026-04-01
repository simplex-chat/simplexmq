{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.FileTransfer.Server.Store
  ( FileStoreClass (..),
    FileRec (..),
    FileRecipient (..),
    RoundedFileTime,
    fileTimePrecision,
  )
where

import Control.Concurrent.STM
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Int (Int64)
import Data.Set (Set)
import Data.Word (Word32)
import Simplex.FileTransfer.Protocol (FileInfo (..), SFileParty, XFTPFileId)
import Simplex.FileTransfer.Transport (XFTPErrorType)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BlockingInfo, RecipientId, SenderId)
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus)
import Simplex.Messaging.SystemTime

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
fileTimePrecision = 3600 -- truncate creation time to 1 hour

data FileRecipient = FileRecipient RecipientId C.APublicAuthKey
  deriving (Show)

instance StrEncoding FileRecipient where
  strEncode (FileRecipient rId rKey) = strEncode rId <> ":" <> strEncode rKey
  strP = FileRecipient <$> strP <* A.char ':' <*> strP

class FileStoreClass s where
  type FileStoreConfig s

  -- Lifecycle
  newFileStore :: FileStoreConfig s -> IO s
  closeFileStore :: s -> IO ()

  -- File operations
  addFile :: s -> SenderId -> FileInfo -> RoundedFileTime -> ServerEntityStatus -> IO (Either XFTPErrorType ())
  setFilePath :: s -> SenderId -> FilePath -> IO (Either XFTPErrorType ())
  addRecipient :: s -> SenderId -> FileRecipient -> IO (Either XFTPErrorType ())
  getFile :: s -> SFileParty p -> XFTPFileId -> IO (Either XFTPErrorType (FileRec, C.APublicAuthKey))
  deleteFile :: s -> SenderId -> IO (Either XFTPErrorType ())
  blockFile :: s -> SenderId -> BlockingInfo -> Bool -> IO (Either XFTPErrorType ())
  deleteRecipient :: s -> RecipientId -> FileRec -> IO ()
  ackFile :: s -> RecipientId -> IO (Either XFTPErrorType ())

  -- Expiration (with LIMIT for Postgres; called in a loop until empty)
  expiredFiles :: s -> Int64 -> Int -> IO [(SenderId, Maybe FilePath, Word32)]

  -- Storage and stats (for init-time computation)
  getUsedStorage :: s -> IO Int64
  getFileCount :: s -> IO Int
