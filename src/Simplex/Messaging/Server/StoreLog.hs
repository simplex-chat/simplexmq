{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.StoreLog
  ( StoreLog, -- constructors are not exported
    StoreLogRecord (..),
    openWriteStoreLog,
    openReadStoreLog,
    closeStoreLog,
    writeStoreLogRecord,
    writeQueues,
    readQueues,
  )
where

import Control.Applicative (optional, (<|>))
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first, second)
import Data.ByteString.Base64 (encode)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (base64P, parseAll)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore (QueueRec (..), QueueStatus (..))
import Simplex.Messaging.Transport (trimCR)
import System.IO

-- | opaque container for file handle with a type-safe IOMode
-- constructors are not exported, openWriteStoreLog and openReadStoreLog should be used instead
data StoreLog (a :: IOMode) where
  ReadStoreLog :: Handle -> StoreLog 'ReadMode
  WriteStoreLog :: Handle -> StoreLog 'WriteMode

data StoreLogRecord
  = CreateQueue QueueRec
  | SecureQueue QueueId SenderPublicKey
  | SuspendQueue QueueId
  | DeleteQueue QueueId

storeLogRecordP :: Parser StoreLogRecord
storeLogRecordP =
  "CREATE " *> createQueue
    <|> "SECURE " *> secureQueue
    <|> "SUSPEND " *> (SuspendQueue <$> base64P)
    <|> "DELETE " *> (DeleteQueue <$> base64P)
  where
    createQueue = CreateQueue <$> queueRecP
    secureQueue = SecureQueue <$> base64P <* A.space <*> C.pubKeyP
    queueRecP = do
      recipientId <- "rid=" *> base64P <* A.space
      senderId <- "sid=" *> base64P <* A.space
      recipientKey <- "rk=" *> C.pubKeyP <* A.space
      senderKey <- "sk=" *> optional C.pubKeyP
      pure QueueRec {recipientId, senderId, recipientKey, senderKey, status = QueueActive}

serializeStoreLogRecord :: StoreLogRecord -> ByteString
serializeStoreLogRecord = \case
  CreateQueue q -> "CREATE " <> serializeQueue q
  SecureQueue rId sKey -> "SECURE " <> encode rId <> " " <> C.serializePubKey sKey
  SuspendQueue rId -> "SUSPEND " <> encode rId
  DeleteQueue rId -> "DELETE " <> encode rId
  where
    serializeQueue QueueRec {recipientId, senderId, recipientKey, senderKey} =
      B.unwords
        [ "rid=" <> encode recipientId,
          "sid=" <> encode senderId,
          "rk=" <> C.serializePubKey recipientKey,
          "sk=" <> maybe "" C.serializePubKey senderKey
        ]

openWriteStoreLog :: FilePath -> IO (StoreLog 'WriteMode)
openWriteStoreLog f = WriteStoreLog <$> openFile f WriteMode

openReadStoreLog :: FilePath -> IO (StoreLog 'ReadMode)
openReadStoreLog f = ReadStoreLog <$> openFile f ReadMode

closeStoreLog :: StoreLog a -> IO ()
closeStoreLog = \case
  WriteStoreLog h -> hClose h
  ReadStoreLog h -> hClose h

writeStoreLogRecord :: StoreLog 'WriteMode -> StoreLogRecord -> IO ()
writeStoreLogRecord (WriteStoreLog h) = B.hPutStr h . serializeStoreLogRecord

writeQueues :: StoreLog 'WriteMode -> Map RecipientId QueueRec -> IO ()
writeQueues s = mapM_ (writeStoreLogRecord s . CreateQueue) . M.filter active
  where
    active QueueRec {status} = status == QueueActive

type LogParsingError = (String, ByteString)

readQueues :: StoreLog 'ReadMode -> IO (Map RecipientId QueueRec)
readQueues (ReadStoreLog h) = LB.hGetContents h >>= returnResult . procStoreLog
  where
    procStoreLog :: LB.ByteString -> ([LogParsingError], Map RecipientId QueueRec)
    procStoreLog = second (foldl' procLogRecord M.empty) . partitionEithers . map parseLogRecord . LB.lines
    returnResult :: ([LogParsingError], Map RecipientId QueueRec) -> IO (Map RecipientId QueueRec)
    returnResult (errs, res) = mapM_ printError errs $> res
    parseLogRecord :: LB.ByteString -> Either LogParsingError StoreLogRecord
    parseLogRecord = (\s -> first (,s) $ parseAll storeLogRecordP s) . trimCR . LB.toStrict
    procLogRecord :: Map RecipientId QueueRec -> StoreLogRecord -> Map RecipientId QueueRec
    procLogRecord m = \case
      CreateQueue q -> M.insert (recipientId q) q m
      SecureQueue qId sKey -> M.adjust (\q -> q {senderKey = Just sKey}) qId m
      SuspendQueue qId -> M.delete qId m
      DeleteQueue qId -> M.delete qId m
    printError :: LogParsingError -> IO ()
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
