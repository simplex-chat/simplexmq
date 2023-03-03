{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Types where

import Data.Int (Int64)
import Data.Word (Word32)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.FileTransfer.Description
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

data RcvFile = RcvFile
  { userId :: Int64,
    rcvFileId :: Int64,
    size :: FileSize Int64,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: FileSize Word32,
    chunks :: [RcvFileChunk],
    tmpPath :: FilePath,
    saveDir :: FilePath,
    savePath :: Maybe FilePath,
    status :: RcvFileStatus,
    status :: RcvFileStatus
  }
  deriving (Eq, Show)

-- TODO add error status?
data RcvFileStatus
  = RFSReceiving
  | RFSReceived
  | RFSDecrypting
  | RFSComplete
  deriving (Eq, Show)

instance FromField RcvFileStatus where fromField = fromTextField_ textDecode

instance ToField RcvFileStatus where toField = toField . textEncode

instance TextEncoding RcvFileStatus where
  textDecode = \case
    "receiving" -> Just RFSReceiving
    "received" -> Just RFSReceived
    "decrypting" -> Just RFSDecrypting
    "complete" -> Just RFSComplete
    _ -> Nothing
  textEncode = \case
    RFSReceiving -> "receiving"
    RFSReceived -> "received"
    RFSDecrypting -> "decrypting"
    RFSComplete -> "complete"

data RcvFileChunk = RcvFileChunk
  { userId :: Int64,
    rcvFileId :: Int64,
    rcvChunkId :: Int64,
    chunkNo :: Int,
    chunkSize :: FileSize Word32,
    digest :: FileDigest,
    replicas :: [RcvFileChunkReplica],
    fileTmpPath :: FilePath,
    chunkTmpPath :: Maybe FilePath,
    nextDelay :: Maybe Int
  }
  deriving (Eq, Show)

data RcvFileChunkReplica = RcvFileChunkReplica
  { rcvChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    received :: Bool,
    retries :: Int
  }
  deriving (Eq, Show)
