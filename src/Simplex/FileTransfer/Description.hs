{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.FileTransfer.Description
  ( FileDescription (..),
    RedirectFileInfo (..),
    AFileDescription (..),
    ValidFileDescription, -- constructor is not exported, use pattern
    pattern ValidFileDescription,
    AValidFileDescription (..),
    FileDigest (..),
    FileChunk (..),
    FileChunkReplica (..),
    FileServerReplica (..),
    FileSize (..),
    ChunkReplicaId (..),
    YAMLFileDescription (..), -- for tests
    YAMLServerReplicas (..), -- for tests
    validateFileDescription,
    groupReplicasByServer,
    fdSeparator,
    kb,
    mb,
    gb,
    FileDescriptionURI (..),
    FileClientData,
    fileDescriptionURI,
    qrSizeLimit,
    maxFileSize,
    maxFileSizeStr,
    maxFileSizeHard,
    fileSizeLen,
  )
where

import Control.Applicative (optional)
import Control.Monad ((<=<))
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.String
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word32)
import qualified Data.Yaml as Y
import Simplex.FileTransfer.Chunks
import Simplex.FileTransfer.Protocol
import Simplex.Messaging.Agent.QueryString
import Simplex.Messaging.Agent.Store.DB (Binary (..), FromField (..), ToField (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON, parseAll)
import Simplex.Messaging.Protocol (XFTPServer)
import Simplex.Messaging.ServiceScheme (ServiceScheme (..))
import Simplex.Messaging.Util (bshow, safeDecodeUtf8, (<$?>))

data FileDescription (p :: FileParty) = FileDescription
  { party :: SFileParty p,
    size :: FileSize Int64,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: FileSize Word32,
    chunks :: [FileChunk],
    redirect :: Maybe RedirectFileInfo
  }
  deriving (Eq, Show)

data RedirectFileInfo = RedirectFileInfo
  { size :: FileSize Int64,
    digest :: FileDigest
  }
  deriving (Eq, Show)

data AFileDescription = forall p. FilePartyI p => AFD (FileDescription p)

newtype ValidFileDescription p = ValidFD (FileDescription p)
  deriving (Eq, Show)

pattern ValidFileDescription :: FileDescription p -> ValidFileDescription p
pattern ValidFileDescription fd = ValidFD fd

{-# COMPLETE ValidFileDescription #-}

data AValidFileDescription = forall p. FilePartyI p => AVFD (ValidFileDescription p)

fdSeparator :: IsString s => s
fdSeparator = "################################\n"

newtype FileDigest = FileDigest {unFileDigest :: ByteString}
  deriving (Eq, Show)
  deriving newtype (FromField)

instance ToField FileDigest where toField (FileDigest s) = toField $ Binary s

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
    chunkSize :: FileSize Word32,
    digest :: FileDigest,
    replicas :: [FileChunkReplica]
  }
  deriving (Eq, Show)

data FileChunkReplica = FileChunkReplica
  { server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateAuthKey
  }
  deriving (Eq, Show)

newtype ChunkReplicaId = ChunkReplicaId {unChunkReplicaId :: XFTPFileId}
  deriving (Eq, Show)
  deriving newtype (StrEncoding)

instance FromJSON ChunkReplicaId where
  parseJSON = strParseJSON "ChunkReplicaId"

instance ToJSON ChunkReplicaId where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data YAMLFileDescription = YAMLFileDescription
  { party :: FileParty,
    size :: String,
    digest :: FileDigest,
    key :: C.SbKey,
    nonce :: C.CbNonce,
    chunkSize :: String,
    replicas :: [YAMLServerReplicas],
    redirect :: Maybe RedirectFileInfo
  }
  deriving (Eq, Show)

data YAMLServerReplicas = YAMLServerReplicas
  { server :: XFTPServer,
    chunks :: [String]
  }
  deriving (Eq, Show)

data FileServerReplica = FileServerReplica
  { chunkNo :: Int,
    server :: XFTPServer,
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateAuthKey,
    digest :: Maybe FileDigest,
    chunkSize :: Maybe (FileSize Word32)
  }
  deriving (Show)

newtype FileSize a = FileSize {unFileSize :: a}
  deriving (Eq, Show)

instance FromJSON a => FromJSON (FileSize a) where
  parseJSON v = FileSize <$> Y.parseJSON v

instance ToJSON a => ToJSON (FileSize a) where
  toJSON = Y.toJSON . unFileSize

$(J.deriveJSON defaultJSON ''YAMLServerReplicas)

$(J.deriveJSON defaultJSON ''RedirectFileInfo)

$(J.deriveJSON defaultJSON ''YAMLFileDescription)

instance FilePartyI p => StrEncoding (ValidFileDescription p) where
  strEncode (ValidFD fd) = strEncode fd
  strDecode s = strDecode s >>= (\(AVFD fd) -> checkParty fd)
  strP = strDecode <$?> A.takeByteString

instance StrEncoding AValidFileDescription where
  strEncode (AVFD fd) = strEncode fd
  strDecode = (\(AFD fd) -> AVFD <$> validateFileDescription fd) <=< strDecode
  strP = strDecode <$?> A.takeByteString

instance FilePartyI p => StrEncoding (FileDescription p) where
  strEncode = Y.encode . encodeFileDescription
  strDecode s = strDecode s >>= (\(AFD fd) -> checkParty fd)
  strP = strDecode <$?> A.takeByteString

instance StrEncoding AFileDescription where
  strEncode (AFD fd) = strEncode fd
  strDecode = decodeFileDescription <=< first show . Y.decodeEither'
  strP = strDecode <$?> A.takeByteString

validateFileDescription :: FileDescription p -> Either String (ValidFileDescription p)
validateFileDescription fd@FileDescription {size, chunks}
  | chunkNos /= [1 .. length chunks] = Left "chunk numbers are not sequential"
  | chunksSize chunks /= unFileSize size = Left "chunks total size is different than file size"
  | otherwise = Right $ ValidFD fd
  where
    chunkNos = map (\FileChunk {chunkNo} -> chunkNo) chunks
    chunksSize = foldl' (\(s :: Int64) FileChunk {chunkSize} -> s + fromIntegral (unFileSize chunkSize)) 0

encodeFileDescription :: FileDescription p -> YAMLFileDescription
encodeFileDescription FileDescription {party, size, digest, key, nonce, chunkSize, chunks, redirect} =
  YAMLFileDescription
    { party = toFileParty party,
      size = B.unpack $ strEncode size,
      digest,
      key,
      nonce,
      chunkSize = B.unpack $ strEncode chunkSize,
      replicas = encodeFileReplicas chunkSize chunks,
      redirect
    }

data FileDescriptionURI = FileDescriptionURI
  { scheme :: ServiceScheme,
    description :: ValidFileDescription 'FRecipient,
    clientData :: Maybe FileClientData -- JSON-encoded extensions to pass in a link
  }
  deriving (Eq, Show)

type FileClientData = Text

fileDescriptionURI :: ValidFileDescription 'FRecipient -> FileDescriptionURI
fileDescriptionURI vfd = FileDescriptionURI SSSimplex vfd mempty

instance StrEncoding FileDescriptionURI where
  strEncode FileDescriptionURI {scheme, description, clientData} = mconcat [strEncode scheme, "/file", "#/?", queryStr]
    where
      queryStr = strEncode $ QSP QEscape qs
      qs = ("desc", strEncode description) : maybe [] (\cd -> [("data", encodeUtf8 cd)]) clientData
  strP = do
    scheme <- strP
    _ <- "/file" <* optional (A.char '/') <* "#/?"
    query <- strP
    description <- queryParam "desc" query
    let clientData = safeDecodeUtf8 <$> queryParamStr "data" query
    pure FileDescriptionURI {scheme, description, clientData}

-- | URL length in QR code before jumping up to a next size.
qrSizeLimit :: Int
qrSizeLimit = 1002 -- ~2 chunks in URLencoded YAML with some spare size for server hosts

-- | Soft limit for XFTP clients. Should be checked and reported to user.
maxFileSize :: Int64
maxFileSize = gb 1

maxFileSizeStr :: String
maxFileSizeStr = B.unpack . strEncode $ FileSize maxFileSize

-- | Hard internal limit for XFTP agent after which it refuses to prepare chunks.
maxFileSizeHard :: Int64
maxFileSizeHard = gb 5

fileSizeLen :: Int64
fileSizeLen = 8


instance (Integral a, Show a) => StrEncoding (FileSize a) where
  strEncode (FileSize b)
    | b' /= 0 = bshow b
    | ks' /= 0 = bshow ks <> "kb"
    | ms' /= 0 = bshow ms <> "mb"
    | otherwise = bshow gs <> "gb"
    where
      (ks, b') = b `divMod` 1024
      (ms, ks') = ks `divMod` 1024
      (gs, ms') = ms `divMod` 1024
  strP =
    FileSize
      <$> A.choice
        [ gb <$> A.decimal <* "gb",
          mb <$> A.decimal <* "mb",
          kb <$> A.decimal <* "kb",
          A.decimal
        ]

instance (Integral a, Show a) => IsString (FileSize a) where
  fromString = either error id . strDecode . B.pack

deriving newtype instance FromField a => FromField (FileSize a)

deriving newtype instance ToField a => ToField (FileSize a)

groupReplicasByServer :: FileSize Word32 -> [FileChunk] -> [NonEmpty FileServerReplica]
groupReplicasByServer defChunkSize =
  L.groupAllWith (\FileServerReplica {server} -> server) . unfoldChunksToReplicas defChunkSize

encodeFileReplicas :: FileSize Word32 -> [FileChunk] -> [YAMLServerReplicas]
encodeFileReplicas defChunkSize =
  map encodeServerReplicas . groupReplicasByServer defChunkSize
  where
    encodeServerReplicas fs@(FileServerReplica {server} :| _) =
      YAMLServerReplicas
        { server,
          chunks = map (B.unpack . encodeServerReplica) $ L.toList fs
        }

encodeServerReplica :: FileServerReplica -> ByteString
encodeServerReplica FileServerReplica {chunkNo, replicaId, replicaKey, digest, chunkSize} =
  bshow chunkNo
    <> ":"
    <> strEncode replicaId
    <> ":"
    <> strEncode replicaKey
    <> maybe "" ((":" <>) . strEncode) digest
    <> maybe "" ((":" <>) . strEncode) chunkSize

serverReplicaP :: XFTPServer -> Parser FileServerReplica
serverReplicaP server = do
  chunkNo <- A.decimal
  replicaId <- A.char ':' *> strP
  replicaKey <- A.char ':' *> strP
  digest <- optional (A.char ':' *> strP)
  chunkSize <- optional (A.char ':' *> strP)
  pure FileServerReplica {chunkNo, server, replicaId, replicaKey, digest, chunkSize}

unfoldChunksToReplicas :: FileSize Word32 -> [FileChunk] -> [FileServerReplica]
unfoldChunksToReplicas defChunkSize = concatMap chunkReplicas
  where
    chunkReplicas c@FileChunk {replicas} = zipWith (replicaToServerReplica c) [1 ..] replicas
    replicaToServerReplica :: FileChunk -> Int -> FileChunkReplica -> FileServerReplica
    replicaToServerReplica FileChunk {chunkNo, digest, chunkSize} replicaNo FileChunkReplica {server, replicaId, replicaKey} =
      let chunkSize' = if chunkSize /= defChunkSize && replicaNo == 1 then Just chunkSize else Nothing
          digest' = if replicaNo == 1 then Just digest else Nothing
       in FileServerReplica {chunkNo, server, replicaId, replicaKey, digest = digest', chunkSize = chunkSize'}

decodeFileDescription :: YAMLFileDescription -> Either String AFileDescription
decodeFileDescription YAMLFileDescription {party, size, digest, key, nonce, chunkSize, replicas, redirect} = do
  size' <- strDecode $ B.pack size
  chunkSize' <- strDecode $ B.pack chunkSize
  replicas' <- decodeFileParts replicas
  chunks <- foldReplicasToChunks chunkSize' replicas'
  pure $ case aFileParty party of
    AFP party' -> AFD FileDescription {party = party', size = size', digest, key, nonce, chunkSize = chunkSize', chunks, redirect}
  where
    decodeFileParts = fmap concat . mapM decodeYAMLServerReplicas

decodeYAMLServerReplicas :: YAMLServerReplicas -> Either String [FileServerReplica]
decodeYAMLServerReplicas YAMLServerReplicas {server, chunks} =
  mapM (parseAll (serverReplicaP server) . B.pack) chunks

-- this function should fail if:
-- 1. no replica has digest or two replicas have different digests
-- 2. two replicas have different chunk sizes
foldReplicasToChunks :: FileSize Word32 -> [FileServerReplica] -> Either String [FileChunk]
foldReplicasToChunks defChunkSize fs = do
  sd <- foldSizesDigests fs
  -- TODO validate (check that chunks match) or in separate function
  sortOn (\FileChunk {chunkNo} -> chunkNo) . map reverseReplicas . M.elems <$> foldChunks sd fs
  where
    foldSizesDigests :: [FileServerReplica] -> Either String (Map Int (FileSize Word32), Map Int FileDigest)
    foldSizesDigests = foldl' addSizeDigest $ Right (M.empty, M.empty)
    addSizeDigest :: Either String (Map Int (FileSize Word32), Map Int FileDigest) -> FileServerReplica -> Either String (Map Int (FileSize Word32), Map Int FileDigest)
    addSizeDigest (Left e) _ = Left e
    addSizeDigest (Right (ms, md)) FileServerReplica {chunkNo, chunkSize, digest} =
      (,) <$> combineChunk ms chunkNo chunkSize <*> combineChunk md chunkNo digest
    combineChunk :: Eq a => Map Int a -> Int -> Maybe a -> Either String (Map Int a)
    combineChunk m _ Nothing = Right m
    combineChunk m chunkNo (Just value) = case M.lookup chunkNo m of
      Nothing -> Right $ M.insert chunkNo value m
      Just v -> if v == value then Right m else Left "different size or digest in chunk replicas"
    foldChunks :: (Map Int (FileSize Word32), Map Int FileDigest) -> [FileServerReplica] -> Either String (Map Int FileChunk)
    foldChunks sd = foldl' (addReplica sd) (Right M.empty)
    addReplica :: (Map Int (FileSize Word32), Map Int FileDigest) -> Either String (Map Int FileChunk) -> FileServerReplica -> Either String (Map Int FileChunk)
    addReplica _ (Left e) _ = Left e
    addReplica (ms, md) (Right cs) FileServerReplica {chunkNo, server, replicaId, replicaKey} = do
      case M.lookup chunkNo cs of
        Just chunk@FileChunk {replicas} ->
          let replica = FileChunkReplica {server, replicaId, replicaKey}
           in Right $ M.insert chunkNo ((chunk :: FileChunk) {replicas = replica : replicas}) cs
        _ -> do
          case M.lookup chunkNo md of
            Just digest' ->
              let replica = FileChunkReplica {server, replicaId, replicaKey}
                  chunkSize' = fromMaybe defChunkSize $ M.lookup chunkNo ms
                  chunk = FileChunk {chunkNo, digest = digest', chunkSize = chunkSize', replicas = [replica]}
               in Right $ M.insert chunkNo chunk cs
            _ -> Left "no digest for chunk"
    reverseReplicas c@FileChunk {replicas} = (c :: FileChunk) {replicas = reverse replicas}
