{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Types where

import Data.Int (Int64)
import Data.Word (Word32)
import Simplex.FileTransfer.Description
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol

data RcvFileDescription = RcvFileDescription
  { name :: String,
    size :: Int64,
    digest :: FileDigest,
    key :: C.Key,
    iv :: C.IV,
    chunkSize :: Word32,
    chunks :: [RcvFileChunk],
    status :: RcvFileStatus
  }
  deriving (Eq, Show)

data RcvFileStatus
  = RFSAccepted
  | RFSReceived {tempPath :: FilePath}
  | RFSDecrypting {tempPath :: FilePath, savePath :: FilePath}
  | RFSComplete {savePath :: FilePath}
  deriving (Eq, Show)

data RcvFileChunk = RcvFileChunk
  { chunkNo :: Int,
    chunkSize :: Word32,
    digest :: FileDigest,
    replicas :: [RcvFileChunkReplica],
    received :: Bool, -- computed based on replicas?
    acknowledged :: Bool,
    tempPath :: Maybe FilePath,
    nextDelay :: Int
  }
  deriving (Eq, Show)

data RcvFileChunkReplica = RcvFileChunkReplica
  { server :: XFTPServer,
    rcvId :: ChunkReplicaId,
    rcvKey :: C.APrivateSignKey,
    received :: Bool,
    retries :: Int
  }
  deriving (Eq, Show)

data XFTPAction
  = XADownloadChunk
  deriving (Show)

data XFTPLocalAction 
  = XALDecrypt
  deriving (Show)
