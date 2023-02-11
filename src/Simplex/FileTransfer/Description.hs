{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    FileDigest (..),
    FileChunk (..),
    FileChunkReplica (..),
    FileChunkRcvId (..),
    YAMLFileDescription (..), -- for tests
    YAMLFilePart (..), -- for tests
    parseFileDescription,
    serializeFileDescription,
  )
where

import Control.Applicative (optional)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (base64P)

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
    chunkSize :: Word32,
    digest :: FileDigest,
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
    chunks :: [String]
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON YAMLFilePart where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data FilePartChunk = FilePartChunk
  { chunkNo :: Int,
    rcvId :: FileChunkRcvId,
    rcvKey :: C.Key, -- C.APrivateSignKey -- ? C.PrivateKey 'C.Ed25519
    digest :: Maybe FileDigest,
    chunkSize :: Maybe Word32
  }
  deriving (Show)

parseFileDescription :: ByteString -> Either String FileDescription
parseFileDescription bs = do
  YAMLFileDescription {name, size, chunkSize = fChunkSizeS, digest = fDigest, encKey, iv, parts} <- Y.decodeEither' bs
  fChunkSize <- parseFileChunkSize fChunkSizeS
  cm <- parseParts M.empty parts
  let chunks = map (\fc@FileChunk {replicas} -> fc {replicas = reverse replicas}) (M.elems cm)
  pure FileDescription {name, size, digest = fDigest, encKey, iv, chunks}
  where
    parseParts :: Map Int FileChunk -> [YAMLFilePart] -> Either String (Map Int FileChunk)
    parseParts cm [] = Right cm
    parseParts cm (YAMLFilePart {server, chunks} : ps) = case parseChunks cm chunks of
      Left e -> Left e
      Right cm' -> parseParts cm' ps
      where
        parseChunks :: Map Int FileChunk -> [String] -> Either String (Map Int FileChunk)
        parseChunks cm' [] = Right cm'
        parseChunks cm' (c : cs) = case parseChunk cm' c of
          Left e -> Left e
          Right cm'' -> parseChunks cm'' cs
        parseChunk :: Map Int FileChunk -> String -> Either String (Map Int FileChunk)
        parseChunk cm' chunkStr = do
          case parseFilePartChunk chunkStr of
            Left e -> Left $ "Failed to parse chunk: " <> e
            Right FilePartChunk {chunkNo, rcvId, rcvKey, digest = digest_, chunkSize = chunkSize_} ->
              case M.lookup chunkNo cm' of
                Nothing ->
                  case digest_ of
                    Nothing -> Left $ "First chunk replica has no digest: " <> chunkStr
                    Just digest ->
                      let chunkSize = fromMaybe fChunkSize chunkSize_
                          replicas = [FileChunkReplica {server, rcvId, rcvKey}]
                       in Right $ M.insert chunkNo FileChunk {chunkNo, digest, chunkSize, replicas} cm'
                Just fc@FileChunk {replicas} ->
                  let replicas' = FileChunkReplica {server, rcvId, rcvKey} : replicas
                   in Right $ M.insert chunkNo fc {replicas = replicas'} cm'

parseFileChunkSize :: String -> Either String Word32
parseFileChunkSize = A.parseOnly fileChunkSizeP . B.pack

parseFilePartChunk :: String -> Either String FilePartChunk
parseFilePartChunk = A.parseOnly filePartChunkP . B.pack

filePartChunkP :: Parser FilePartChunk
filePartChunkP =
  FilePartChunk
    <$> A.decimal <* A.char ':'
      <*> fileChunkRcvIdP <* A.char ':'
      <*> fileChunkRcvKeyP
      <*> optional (A.char ':' *> fileChunkDigestP)
      <*> optional (A.char ':' *> fileChunkSizeP) <* A.endOfInput
  where
    fileChunkRcvIdP = FileChunkRcvId <$> base64P
    fileChunkRcvKeyP = C.Key <$> base64P
    fileChunkDigestP = FileDigest <$> base64P

fileChunkSizeP :: Parser Word32
fileChunkSizeP = do
  n <- A.decimal
  _ <- A.char 'm'
  _ <- A.char 'b'
  pure $ n * 1024 * 1024

serializeFileDescription :: FileDescription -> ByteString
serializeFileDescription FileDescription {name, size, digest = fDigest, encKey, iv, chunks = fChunks} = do
  let fChunkSize = case fChunks of
        [] -> 0
        FileChunk {chunkSize} : _ -> chunkSize
      parts = serializeChunks fChunkSize
      yfd = YAMLFileDescription {name, size, chunkSize = serializeChunkSize fChunkSize, digest = fDigest, encKey, iv, parts}
  Y.encode yfd
  where
    serializeChunks :: Word32 -> [YAMLFilePart]
    serializeChunks fChunkSize =
      map
        (\fp@YAMLFilePart {chunks} -> fp {chunks = reverse chunks} :: YAMLFilePart)
        (M.elems $ serializeChunks' M.empty fChunks)
      where
        serializeChunks' :: Map String YAMLFilePart -> [FileChunk] -> Map String YAMLFilePart
        serializeChunks' pm [] = pm
        serializeChunks' pm (FileChunk {chunkNo, digest, chunkSize, replicas} : cs) = do
          let pm' = serializeReplicas False pm replicas
          serializeChunks' pm' cs
          where
            serializeReplicas :: Bool -> Map String YAMLFilePart -> [FileChunkReplica] -> Map String YAMLFilePart
            serializeReplicas _ pm' [] = pm'
            serializeReplicas aReplSerd pm' (r : rs) = serializeReplicas True (serializeReplica aReplSerd pm' r) rs
            serializeReplica :: Bool -> Map String YAMLFilePart -> FileChunkReplica -> Map String YAMLFilePart
            serializeReplica aReplSerd pm' FileChunkReplica {server, rcvId, rcvKey} = do
              let fpcDigest = if not aReplSerd then Just digest else Nothing
                  fpcSize = if not aReplSerd && chunkSize /= fChunkSize then Just chunkSize else Nothing
                  fpc = FilePartChunk {chunkNo, rcvId, rcvKey, digest = fpcDigest, chunkSize = fpcSize}
                  chunkStr = serializeFilePartChunk fpc
              case M.lookup server pm' of
                Nothing -> M.insert server (YAMLFilePart {server, chunks = [chunkStr]}) pm'
                Just fp@YAMLFilePart {chunks} -> M.insert server (fp {chunks = chunkStr : chunks} :: YAMLFilePart) pm'

serializeFilePartChunk :: FilePartChunk -> String
serializeFilePartChunk FilePartChunk {chunkNo, rcvId = FileChunkRcvId rId, rcvKey = C.Key rKey, digest = digest_, chunkSize = chunkSize_} =
  show chunkNo
    <> ":"
    <> serB64 rId
    <> ":"
    <> serB64 rKey
    <> maybe "" (\(FileDigest digest) -> ":" <> serB64 digest) digest_
    <> maybe "" (\chunkSize -> ":" <> serializeChunkSize chunkSize) chunkSize_
  where
    serB64 = B.unpack . B64.encode

serializeChunkSize :: Word32 -> String
serializeChunkSize n = show (n `div` 1024 `div` 1024) <> "mb"
