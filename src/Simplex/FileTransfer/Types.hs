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
import Simplex.Messaging.Agent.Protocol (RcvFileId, SndFileId)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..))
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (fromTextField_)
import Simplex.Messaging.Protocol
import System.FilePath ((</>))

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
    prefixPath :: FilePath,
    tmpPath :: Maybe FilePath,
    saveFile :: CryptoFile,
    status :: RcvFileStatus,
    deleted :: Bool
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
    delay :: Maybe Int64,
    retries :: Int
  }
  deriving (Eq, Show)

-- Sending files

type DBSndFileId = Int64

data SndFile = SndFile
  { sndFileId :: DBSndFileId,
    sndFileEntityId :: SndFileId,
    userId :: Int64,
    numRecipients :: Int,
    digest :: Maybe FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunks :: [SndFileChunk],
    srcFile :: CryptoFile,
    prefixPath :: Maybe FilePath,
    status :: SndFileStatus,
    deleted :: Bool
  }
  deriving (Eq, Show)

sndFileEncPath :: FilePath -> FilePath
sndFileEncPath prefixPath = prefixPath </> "xftp.encrypted"

data SndFileStatus
  = SFSNew -- db record created
  | SFSEncrypting -- encryption started
  | SFSEncrypted -- encryption complete
  | SFSUploading -- all chunk replicas are created on servers
  | SFSComplete -- all chunk replicas are uploaded
  | SFSError -- permanent error
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
    "error" -> Just SFSError
    _ -> Nothing
  textEncode = \case
    SFSNew -> "new"
    SFSEncrypting -> "encrypting"
    SFSEncrypted -> "encrypted"
    SFSUploading -> "uploading"
    SFSComplete -> "complete"
    SFSError -> "error"

data SndFileChunk = SndFileChunk
  { sndFileId :: DBSndFileId,
    sndFileEntityId :: SndFileId,
    userId :: Int64,
    numRecipients :: Int,
    sndChunkId :: Int64,
    chunkNo :: Int,
    chunkSpec :: XFTPChunkSpec,
    filePrefixPath :: FilePath,
    digest :: FileDigest,
    replicas :: [SndFileChunkReplica]
  }
  deriving (Eq, Show)

sndChunkSize :: SndFileChunk -> Word32
sndChunkSize SndFileChunk {chunkSpec = XFTPChunkSpec {chunkSize}} = chunkSize

data NewSndChunkReplica = NewSndChunkReplica
  { server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    rcvIdsKeys :: [(ChunkReplicaId, C.APrivateSignKey)]
  }
  deriving (Eq, Show)

data SndFileChunkReplica = SndFileChunkReplica
  { sndChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    rcvIdsKeys :: [(ChunkReplicaId, C.APrivateSignKey)],
    replicaStatus :: SndFileReplicaStatus,
    delay :: Maybe Int64,
    retries :: Int
  }
  deriving (Eq, Show)

data SndFileReplicaStatus
  = SFRSCreated
  | SFRSUploaded
  deriving (Eq, Show)

instance FromField SndFileReplicaStatus where fromField = fromTextField_ textDecode

instance ToField SndFileReplicaStatus where toField = toField . textEncode

instance TextEncoding SndFileReplicaStatus where
  textDecode = \case
    "created" -> Just SFRSCreated
    "uploaded" -> Just SFRSUploaded
    _ -> Nothing
  textEncode = \case
    SFRSCreated -> "created"
    SFRSUploaded -> "uploaded"

data DeletedSndChunkReplica = DeletedSndChunkReplica
  { deletedSndChunkReplicaId :: Int64,
    userId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    chunkDigest :: FileDigest,
    delay :: Maybe Int64,
    retries :: Int
  }
  deriving (Eq, Show)
