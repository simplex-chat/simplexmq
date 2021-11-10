{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.StoreLog
  ( StoreLog, -- constructors are not exported
    openWriteStoreLog,
    openReadStoreLog,
    storeLogFilePath,
    closeStoreLog,
    logCreateQueue,
    logSecureQueue,
    logDeleteQueue,
    readWriteStoreLog,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless)
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
import Simplex.Messaging.Util (maybeWord)
import System.Directory (doesFileExist)
import System.IO

-- | opaque container for file handle with a type-safe IOMode
-- constructors are not exported, openWriteStoreLog and openReadStoreLog should be used instead
data StoreLog (a :: IOMode) where
  ReadStoreLog :: FilePath -> Handle -> StoreLog 'ReadMode
  WriteStoreLog :: FilePath -> Handle -> StoreLog 'WriteMode

data StoreLogRecord
  = CreateQueue QueueRec
  | SecureQueue QueueId SenderPublicKey
  | EnableNotifications QueueId NotifierId NotifierPublicKey
  | DeleteQueue QueueId

storeLogRecordP :: Parser StoreLogRecord
storeLogRecordP =
  "CREATE " *> createQueueP
    <|> "SECURE " *> secureQueueP
    <|> "NOTIFY " *> enableNotificationsP
    <|> "DELETE " *> (DeleteQueue <$> base64P)
  where
    createQueueP = CreateQueue <$> queueRecP
    secureQueueP = SecureQueue <$> base64P <* A.space <*> C.pubKeyP
    enableNotificationsP =
      EnableNotifications <$> base64P <* A.space <*> base64P <* A.space <*> C.pubKeyP
    queueRecP = do
      recipientId <- "rid=" *> base64P <* A.space
      senderId <- "sid=" *> base64P <* A.space
      recipientKey <- "rk=" *> C.pubKeyP <* A.space
      senderKey <- "sk=" *> optional C.pubKeyP
      notifierId <- optional $ " nid=" *> base64P
      notifierKey <- optional $ " nk=" *> C.pubKeyP
      pure QueueRec {recipientId, senderId, notifierId, recipientKey, notifierKey, senderKey, status = QueueActive}

serializeStoreLogRecord :: StoreLogRecord -> ByteString
serializeStoreLogRecord = \case
  CreateQueue q -> "CREATE " <> serializeQueue q
  SecureQueue rId sKey -> "SECURE " <> encode rId <> " " <> C.serializePubKey sKey
  EnableNotifications rId nId nKey -> B.unwords ["NOTIFY", encode rId, encode nId, C.serializePubKey nKey]
  DeleteQueue rId -> "DELETE " <> encode rId
  where
    serializeQueue QueueRec {recipientId, senderId, notifierId, recipientKey, notifierKey, senderKey} =
      B.unwords
        [ "rid=" <> encode recipientId,
          "sid=" <> encode senderId,
          "rk=" <> C.serializePubKey recipientKey,
          "sk=" <> maybe "" C.serializePubKey senderKey
        ]
        <> maybeWord (("nid=" <>) . encode) notifierId
        <> maybeWord (("nk=" <>) . C.serializePubKey) notifierKey

openWriteStoreLog :: FilePath -> IO (StoreLog 'WriteMode)
openWriteStoreLog f = WriteStoreLog f <$> openFile f WriteMode

openReadStoreLog :: FilePath -> IO (StoreLog 'ReadMode)
openReadStoreLog f = do
  doesFileExist f >>= (`unless` writeFile f "")
  ReadStoreLog f <$> openFile f ReadMode

storeLogFilePath :: StoreLog a -> FilePath
storeLogFilePath = \case
  WriteStoreLog f _ -> f
  ReadStoreLog f _ -> f

closeStoreLog :: StoreLog a -> IO ()
closeStoreLog = \case
  WriteStoreLog _ h -> hClose h
  ReadStoreLog _ h -> hClose h

writeStoreLogRecord :: StoreLog 'WriteMode -> StoreLogRecord -> IO ()
writeStoreLogRecord (WriteStoreLog _ h) r = do
  B.hPutStrLn h $ serializeStoreLogRecord r
  hFlush h

logCreateQueue :: StoreLog 'WriteMode -> QueueRec -> IO ()
logCreateQueue s = writeStoreLogRecord s . CreateQueue

logSecureQueue :: StoreLog 'WriteMode -> QueueId -> SenderPublicKey -> IO ()
logSecureQueue s qId sKey = writeStoreLogRecord s $ SecureQueue qId sKey

logDeleteQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteQueue s = writeStoreLogRecord s . DeleteQueue

readWriteStoreLog :: StoreLog 'ReadMode -> IO (Map RecipientId QueueRec, StoreLog 'WriteMode)
readWriteStoreLog s@(ReadStoreLog f _) = do
  qs <- readQueues s
  closeStoreLog s
  s' <- openWriteStoreLog f
  writeQueues s' qs
  pure (qs, s')

writeQueues :: StoreLog 'WriteMode -> Map RecipientId QueueRec -> IO ()
writeQueues s = mapM_ (writeStoreLogRecord s . CreateQueue) . M.filter active
  where
    active QueueRec {status} = status == QueueActive

type LogParsingError = (String, ByteString)

readQueues :: StoreLog 'ReadMode -> IO (Map RecipientId QueueRec)
readQueues (ReadStoreLog _ h) = LB.hGetContents h >>= returnResult . procStoreLog
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
      EnableNotifications qId nId nKey -> M.adjust (\q -> q {notifierId = Just nId, notifierKey = Just nKey}) qId m
      DeleteQueue qId -> M.delete qId m
    printError :: LogParsingError -> IO ()
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
