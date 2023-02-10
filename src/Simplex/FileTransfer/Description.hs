{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileDigest (..),
    FileChunk (..),
    FileChunkReplica (..),
    YAMLFileDescription (..),
    YAMLFilePart (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Word (Word32)
-- import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String

data FileDescription = FileDescription
  { name :: String,
    size :: Int64,
    digest :: FileDigest,
    encKey :: C.Key,
    iv :: C.IV,
    chunks :: [FileChunk]
  }
  deriving (Show)

newtype FileDigest = FileDigest {unFileDigest :: ByteString}
  deriving (Eq, Show)

instance StrEncoding FileDigest where
  strEncode (FileDigest fd) = strEncode fd
  strDecode s = FileDigest <$> strDecode s
  strP = FileDigest <$> strP

instance FromJSON FileDigest where
  parseJSON = strParseJSON "FileDigest"

instance ToJSON FileDigest where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data FileChunk = FileChunk
  { chunkNo :: Int,
    digest :: ByteString,
    chunkSize :: Word32,
    replicas :: [FileChunkReplica]
  }
  deriving (Show)

data FileChunkReplica = FileChunkReplica
  { server :: String,
    rcvId :: ByteString,
    rcvKey :: C.APrivateSignKey
  }
  deriving (Show)

data YAMLFileDescription = YAMLFileDescription
  { name :: String,
    size :: Int64,
    chunkSize :: String,
    digest :: FileDigest,
    encKey :: C.Key,
    iv :: C.IV,
    parts :: [YAMLFilePart]
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON YAMLFileDescription where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data YAMLFilePart = YAMLFilePart
  { server :: String,
    chunks :: [String]
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON YAMLFilePart where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data FilePartChunk = FilePartChunk
  { chunkNo :: Int,
    rcvId :: ByteString,
    rcvKey :: C.APrivateSignKey,
    digest :: Maybe ByteString,
    chunkSize :: Maybe Word32
  }
  deriving (Show)
