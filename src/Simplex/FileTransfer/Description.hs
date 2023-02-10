{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileDigest (..),
    FileChunk (..),
    FileChunkReplica (..),
    FileChunkRcvId (..),
    YAMLFileDescription (..),
    YAMLFilePart (..),
    YAMLFilePartChunk (..),
    processFileDescription,
    serializeFileDescription,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import qualified Data.Yaml as Y
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
  deriving (Eq, Show)

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
    digest :: FileDigest,
    chunkSize :: Word32,
    replicas :: [FileChunkReplica]
  }
  deriving (Eq, Show)

data FileChunkReplica = FileChunkReplica
  { server :: String,
    rcvId :: FileChunkRcvId,
    -- rcvKey :: C.APrivateSignKey
    rcvKey :: C.Key
  }
  deriving (Eq, Show)

newtype FileChunkRcvId = FileChunkRcvId {unFileChunkRcvId :: ByteString}
  deriving (Eq, Show)

instance StrEncoding FileChunkRcvId where
  strEncode (FileChunkRcvId fid) = strEncode fid
  strDecode s = FileChunkRcvId <$> strDecode s
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

processFileDescription :: ByteString -> IO FileDescription
processFileDescription bs = do
  YAMLFileDescription {name, size, chunkSize, digest, encKey, iv, parts} <- Y.decodeThrow bs
  let chunks = partsToChunks chunkSize parts
  pure FileDescription {name, size, digest, encKey, iv, chunks}
  where
    partsToChunks :: String -> [YAMLFilePart] -> [FileChunk]
    partsToChunks fChunkSize parts =
      map
        (\fc@FileChunk {replicas} -> fc {replicas = reverse replicas})
        (M.elems $ processParts M.empty parts)
      where
        processParts :: Map Int FileChunk -> [YAMLFilePart] -> Map Int FileChunk
        processParts cm [] = cm
        processParts cm (YAMLFilePart {server, chunks} : ps) = processParts (processChunks cm chunks) ps
          where
            processChunks :: Map Int FileChunk -> [YAMLFilePartChunk] -> Map Int FileChunk
            processChunks cm' [] = cm'
            processChunks cm' (c : cs) = processChunks (processChunk cm' c) cs
            processChunk :: Map Int FileChunk -> YAMLFilePartChunk -> Map Int FileChunk
            processChunk cm' YAMLFilePartChunk {c = chunkNo, r = rcvId, k = rcvKey, d = digest_, s = chunkSize_} =
              case M.lookup chunkNo cm' of
                Nothing ->
                  let digest = fromMaybe (FileDigest "") digest_ -- throw?
                      chunkSize = processChunkSize (fromMaybe fChunkSize chunkSize_)
                      replicas = [FileChunkReplica {server, rcvId, rcvKey}]
                   in M.insert chunkNo FileChunk {chunkNo, digest, chunkSize, replicas} cm'
                Just fc@FileChunk {replicas} ->
                  let replicas' = FileChunkReplica {server, rcvId, rcvKey} : replicas
                   in M.insert chunkNo fc {replicas = replicas'} cm'
            processChunkSize :: String -> Word32
            processChunkSize = \case
              "8mb" -> 8 * 1024 * 1024
              "2mb" -> 2 * 1024 * 1024
              _ -> 0

serializeFileDescription :: FileDescription -> ByteString
serializeFileDescription _fd = ""
