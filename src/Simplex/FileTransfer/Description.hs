{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileDigest (..),
    FileChunk (..),
    FileChunkReplica (..),
    FileChunkRcvId (..),
    YAMLFileDescription (..),
    YAMLFilePart (..),
    YAMLFilePartChunk (..),
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
  strDecode str = FileDigest <$> strDecode str
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
    rcvId :: FileChunkRcvId,
    rcvKey :: C.APrivateSignKey
  }
  deriving (Show)

newtype FileChunkRcvId = FileChunkRcvId {unFileChunkRcvId :: ByteString}
  deriving (Eq, Show)

instance StrEncoding FileChunkRcvId where
  strEncode (FileChunkRcvId fid) = strEncode fid
  strDecode str = FileChunkRcvId <$> strDecode str
  strP = FileChunkRcvId <$> strP

instance FromJSON FileChunkRcvId where
  parseJSON = strParseJSON "FileChunkRcvId"

instance ToJSON FileChunkRcvId where
  toJSON = strToJSON
  toEncoding = strToJEncoding

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
    chunks :: [YAMLFilePartChunk]
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON YAMLFilePart where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data YAMLFilePartChunk = YAMLFilePartChunk
  { c :: Int, -- chunkNo
    r :: FileChunkRcvId, -- rcvId
    -- k :: C.PrivateKey 'C.Ed25519, -- rcvKey
    k :: C.Key, -- rcvKey
    d :: Maybe FileDigest, -- digest
    s :: Maybe String -- chunkSize
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON YAMLFilePartChunk where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

-- data FilePartChunk = FilePartChunk
--   { chunkNo :: Int,
--     rcvId :: ByteString,
--     rcvKey :: C.APrivateSignKey,
--     digest :: Maybe ByteString,
--     chunkSize :: Maybe Word32
--   }
--   deriving (Show)
