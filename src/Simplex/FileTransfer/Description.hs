{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileChunkDescription (..),
    FileChunkReplicaDescription (..),
    YAMLFileDescription (..),
    FileDigest (..),
    YAMLFilePartDescription (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Word (Word32)
import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String

data FileDescription = FileDescription
  { name :: String,
    size :: Int64,
    chunkSize :: Word32,
    digest :: FileDigest,
    encKey :: C.Key,
    iv :: C.IV,
    chunks :: [FileChunkDescription]
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

data FileChunkDescription = FileChunkDescription
  { number :: Int,
    digest :: ByteString,
    size :: Word32,
    replicas :: [FileChunkReplicaDescription]
  }
  deriving (Show)

data FileChunkReplicaDescription = FileChunkReplicaDescription
  { server :: String,
    rcvId :: ByteString,
    rcvKey :: C.APrivateSignKey
  }
  deriving (Show)

data YAMLFileDescription = YAMLFileDescription
  { name :: String,
    size :: Int64,
    chunkSize :: Integer,
    digest :: FileDigest,
    encKey :: C.Key,
    iv :: C.IV,
    parts :: [YAMLFilePartDescription]
  }
  deriving (Eq, Show, Generic)

instance FromJSON YAMLFileDescription

data YAMLFilePartDescription = YAMLFilePartDescription
  { server :: String,
    chunks :: [String]
  }
  deriving (Eq, Show, Generic)

instance FromJSON YAMLFilePartDescription

data FilePartChunkDescription = FilePartChunkDescription
  { number :: Int,
    rcvId :: ByteString,
    rcvKey :: C.APrivateSignKey,
    digest :: Maybe ByteString,
    size :: Maybe Integer
  }
  deriving (Show)
