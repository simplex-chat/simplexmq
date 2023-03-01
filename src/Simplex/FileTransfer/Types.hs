{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Types where

import Data.Int (Int64)
import Data.Word (Word32)
import Simplex.FileTransfer.Description
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol

data RcvFileDescription = RcvFileDescription
  { rcvFileId :: Int64,
    size :: FileSize Int64,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: FileSize Word32,
    chunks :: [RcvFileChunk],
    status :: RcvFileStatus
  }
  deriving (Eq, Show)

data RcvFileStatus
  = RFSReceiving {tmpPath :: FilePath}
  | RFSReceived {tmpPath :: FilePath}
  | RFSDecrypting {tmpPath :: FilePath, savePath :: FilePath}
  | RFSComplete {savePath :: FilePath}
  deriving (Eq, Show)

data RcvFileChunk = RcvFileChunk
  { rcvFileChunkId :: Int64,
    chunkNo :: Int,
    chunkSize :: FileSize Word32,
    digest :: FileDigest,
    replicas :: [RcvFileChunkReplica],
    -- received :: Bool, -- computed based on replicas?
    -- acknowledged :: Bool,
    fileTmpPath :: FilePath,
    chunkTmpPath :: Maybe FilePath,
    nextDelay :: Maybe Int
  }
  deriving (Eq, Show)

data RcvFileChunkReplica = RcvFileChunkReplica
  { rcvFileChunkReplicaId :: Int64,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    received :: Bool,
    acknowledged :: Bool,
    retries :: Int
  }
  deriving (Eq, Show)
