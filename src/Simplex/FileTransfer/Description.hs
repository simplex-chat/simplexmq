{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileChunkDescription (..),
    FileChunkReplicaDescription (..),
    FileChunkReplicaAddress (..),
    YAMLFileDescription (..),
    FileDigest (..),
    FileEncKey (..),
    FileIV (..),
    YAMLFilePartDescription (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString.Char8 (ByteString)
import Data.Word (Word32)
import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String

data FileDescription = FileDescription
  { name :: String,
    size :: Word32,
    chunkSize :: Integer,
    digest :: ByteString,
    encKey :: C.Key,
    iv :: C.IV,
    chunks :: [FileChunkDescription]
  }
  deriving (Show)

data FileChunkDescription = FileChunkDescription
  { number :: Int,
    digest :: ByteString,
    size :: Integer,
    replicas :: [FileChunkReplicaDescription]
  }
  deriving (Show)

data FileChunkReplicaDescription = FileChunkReplicaDescription
  { address :: FileChunkReplicaAddress,
    signKey :: C.APrivateSignKey
  }
  deriving (Show)

data FileChunkReplicaAddress = FileChunkReplicaAddress
  { server :: String,
    id :: ByteString
  }
  deriving (Show)

data YAMLFileDescription = YAMLFileDescription
  { name :: String,
    size :: Word32,
    chunkSize :: Integer,
    digest :: FileDigest,
    encKey :: FileEncKey,
    iv :: FileIV,
    parts :: [YAMLFilePartDescription]
  }
  deriving (Eq, Show, Generic)

instance FromJSON YAMLFileDescription

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

newtype FileEncKey = FileEncKey {unFileEncKey :: ByteString}
  deriving (Eq, Show)

instance StrEncoding FileEncKey where
  strEncode (FileEncKey fek) = strEncode fek
  strDecode s = FileEncKey <$> strDecode s
  strP = FileEncKey <$> strP

instance FromJSON FileEncKey where
  parseJSON = strParseJSON "FileEncKey"

instance ToJSON FileEncKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

newtype FileIV = FileIV {unFileIV :: ByteString}
  deriving (Eq, Show)

instance StrEncoding FileIV where
  strEncode (FileIV fiv) = strEncode fiv
  strDecode s = FileIV <$> strDecode s
  strP = FileIV <$> strP

instance FromJSON FileIV where
  parseJSON = strParseJSON "FileIV"

instance ToJSON FileIV where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data YAMLFilePartDescription = YAMLFilePartDescription
  { server :: String,
    chunks :: [YAMLFileChunkString]
  }
  deriving (Eq, Show, Generic)

instance FromJSON YAMLFilePartDescription

type YAMLFileChunkString = String

data FilePartChunkDescription = FilePartChunkDescription
  { number :: Int,
    id :: ByteString,
    signKey :: C.APrivateSignKey,
    digest :: Maybe ByteString,
    size :: Maybe Integer
  }
  deriving (Show)
