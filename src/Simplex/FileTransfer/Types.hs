{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Types where

import Data.Int (Int64)
import Data.Word (Word32)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.FileTransfer.Client (XFTPChunkSpec (..))
import Simplex.FileTransfer.Description
import Simplex.Messaging.Agent.Protocol (RcvFileId)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (fromTextField_)
import Simplex.Messaging.Protocol

authTagSize :: Int64
authTagSize = fromIntegral C.authTagSize

-- fileExtra is added to allow header extension in future versions
data FileHeader = FileHeader
  { fileName :: String,
    fileExtra :: Maybe String
  }
  deriving (Eq, Show)

instance Encoding FileHeader where
  smpEncode FileHeader {fileName, fileExtra} = smpEncode (fileName, fileExtra)
  smpP = do
    (fileName, fileExtra) <- smpP
    pure FileHeader {fileName, fileExtra}

type DBRcvFileId = Int64

data RcvFile = RcvFile
  { rcvFileId :: DBRcvFileId,
    rcvFileEntityId :: RcvFileId,
    userId :: Int64,
    size :: FileSize Int64,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: FileSize Word32,
    chunks :: [RcvFileChunk],
    tmpPath :: Maybe FilePath,
    savePath :: FilePath,
    status :: RcvFileStatus,
    toDelete :: Bool
  }
  deriving (Eq, Show)

data RcvFileStatus
  = RFSReceiving
  | RFSReceived
  | RFSDecrypting
  | RFSComplete
  | RFSError
  deriving (Eq, Show)

instance FromField RcvFileStatus where fromField = fromTextField_ textDecode

instance ToField RcvFileStatus where toField = toField . textEncode

instance TextEncoding RcvFileStatus where
  textDecode = \case
    "receiving" -> Just RFSReceiving
    "received" -> Just RFSReceived
    "decrypting" -> Just RFSDecrypting
    "complete" -> Just RFSComplete
    "error" -> Just RFSError
    _ -> Nothing
  textEncode = \case
    RFSReceiving -> "receiving"
    RFSReceived -> "received"
    RFSDecrypting -> "decrypting"
    RFSComplete -> "complete"
    RFSError -> "error"

data RcvFileChunk = RcvFileChunk
  { rcvFileId :: DBRcvFileId,
    rcvFileEntityId :: RcvFileId,
    userId :: Int64,
    rcvChunkId :: Int64,
    chunkNo :: Int,
    chunkSize :: FileSize Word32,
    digest :: FileDigest,
    replicas :: [RcvFileChunkReplica],
    fileTmpPath :: FilePath,
    chunkTmpPath :: Maybe FilePath
  }
  deriving (Eq, Show)

data RcvFileChunkReplica = RcvFileChunkReplica
  { rcvChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    received :: Bool,
    delay :: Maybe Int,
    retries :: Int
  }
  deriving (Eq, Show)

-- Sending files

type DBSndFileId = Int64

data SndFile = SndFile
  { userId :: Int64,
    sndFileId :: DBSndFileId,
    size :: FileSize Int64,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: FileSize Word32,
    chunks :: [RcvFileChunk],
    path :: FilePath,
    encPath :: Maybe FilePath,
    status :: SndFileStatus
  }
  deriving (Eq, Show)

data SndFileStatus
  = SFSNew
  | SFSEncrypting
  | SFSEncrypted
  | SFSUploading
  | SFSComplete
  deriving (Eq, Show)

instance FromField SndFileStatus where fromField = fromTextField_ textDecode

instance ToField SndFileStatus where toField = toField . textEncode

instance TextEncoding SndFileStatus where
  textDecode = \case
    "new" -> Just SFSNew
    "encrypting" -> Just SFSEncrypting
    "encrypted" -> Just SFSEncrypted
    "uploading" -> Just SFSUploading
    "complete" -> Just SFSComplete
    _ -> Nothing
  textEncode = \case
    SFSNew -> "new"
    SFSEncrypting -> "encrypting"
    SFSEncrypted -> "encrypted"
    SFSUploading -> "uploading"
    SFSComplete -> "complete"

data SndFileChunk = SndFileChunk
  { userId :: Int64,
    sndFileId :: DBSndFileId,
    sndChunkId :: Int64,
    chunkNo :: Int,
    chunkSpec :: XFTPChunkSpec,
    digest :: FileDigest,
    replicas :: [SndFileChunkReplica],
    delay :: Maybe Int
  }
  deriving (Eq, Show)

data SndFileChunkReplica = SndFileChunkReplica
  { sndChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    rcvIdsKeys :: [(ChunkReplicaId, C.APrivateSignKey)],
    -- created :: Bool,
    uploaded :: Bool,
    retries :: Int
  }
  deriving (Eq, Show)

-- to be used in reply to client
data SndFileDescription = SndFileDescription
  { description :: String,
    sender :: Bool
  }
  deriving (Eq, Show)
