{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Server.StoreLog
  ( StoreLog, -- constructors are not exported
    openWriteStoreLog,
    openReadStoreLog,
    storeLogFilePath,
    closeStoreLog,
    writeStoreLogRecord,
    logCreateQueue,
    logSecureQueue,
    logAddNotifier,
    logSuspendQueue,
    logDeleteQueue,
    logDeleteNotifier,
    readWriteStoreLog,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless)
import Data.Bifunctor (first, second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore (NtfCreds (..), QueueRec (..), QueueStatus (..))
import Simplex.Messaging.Transport (trimCR)
import System.Directory (doesFileExist)
import System.IO

-- | opaque container for file handle with a type-safe IOMode
-- constructors are not exported, openWriteStoreLog and openReadStoreLog should be used instead
data StoreLog (a :: IOMode) where
  ReadStoreLog :: FilePath -> Handle -> StoreLog 'ReadMode
  WriteStoreLog :: FilePath -> Handle -> StoreLog 'WriteMode

data StoreLogRecord
  = CreateQueue QueueRec
  | SecureQueue QueueId SndPublicVerifyKey
  | AddNotifier QueueId NtfCreds
  | SuspendQueue QueueId
  | DeleteQueue QueueId
  | DeleteNotifier QueueId

instance StrEncoding QueueRec where
  strEncode QueueRec {recipientId, recipientKey, rcvDhSecret, senderId, senderKey, notifier} =
    B.unwords
      [ "rid=" <> strEncode recipientId,
        "rk=" <> strEncode recipientKey,
        "rdh=" <> strEncode rcvDhSecret,
        "sid=" <> strEncode senderId,
        "sk=" <> strEncode senderKey
      ]
      <> maybe "" notifierStr notifier
    where
      notifierStr ntfCreds = " notifier=" <> strEncode ntfCreds

  strP = do
    recipientId <- "rid=" *> strP_
    recipientKey <- "rk=" *> strP_
    rcvDhSecret <- "rdh=" *> strP_
    senderId <- "sid=" *> strP_
    senderKey <- "sk=" *> strP
    notifier <- optional $ " notifier=" *> strP
    pure QueueRec {recipientId, recipientKey, rcvDhSecret, senderId, senderKey, notifier, status = QueueActive}

instance StrEncoding StoreLogRecord where
  strEncode = \case
    CreateQueue q -> strEncode (Str "CREATE", q)
    SecureQueue rId sKey -> strEncode (Str "SECURE", rId, sKey)
    AddNotifier rId ntfCreds -> strEncode (Str "NOTIFIER", rId, ntfCreds)
    SuspendQueue rId -> strEncode (Str "SUSPEND", rId)
    DeleteQueue rId -> strEncode (Str "DELETE", rId)
    DeleteNotifier rId -> strEncode (Str "NDELETE", rId)

  strP =
    "CREATE " *> (CreateQueue <$> strP)
      <|> "SECURE " *> (SecureQueue <$> strP_ <*> strP)
      <|> "NOTIFIER " *> (AddNotifier <$> strP_ <*> strP)
      <|> "SUSPEND " *> (SuspendQueue <$> strP)
      <|> "DELETE " *> (DeleteQueue <$> strP)
      <|> "NDELETE " *> (DeleteNotifier <$> strP)

openWriteStoreLog :: FilePath -> IO (StoreLog 'WriteMode)
openWriteStoreLog f = do
  h <- openFile f WriteMode
  hSetBuffering h LineBuffering
  pure $ WriteStoreLog f h

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

writeStoreLogRecord :: StrEncoding r => StoreLog 'WriteMode -> r -> IO ()
writeStoreLogRecord (WriteStoreLog _ h) r = do
  B.hPutStrLn h $ strEncode r
  hFlush h

logCreateQueue :: StoreLog 'WriteMode -> QueueRec -> IO ()
logCreateQueue s = writeStoreLogRecord s . CreateQueue

logSecureQueue :: StoreLog 'WriteMode -> QueueId -> SndPublicVerifyKey -> IO ()
logSecureQueue s qId sKey = writeStoreLogRecord s $ SecureQueue qId sKey

logAddNotifier :: StoreLog 'WriteMode -> QueueId -> NtfCreds -> IO ()
logAddNotifier s qId ntfCreds = writeStoreLogRecord s $ AddNotifier qId ntfCreds

logSuspendQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logSuspendQueue s = writeStoreLogRecord s . SuspendQueue

logDeleteQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteQueue s = writeStoreLogRecord s . DeleteQueue

logDeleteNotifier :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteNotifier s = writeStoreLogRecord s . DeleteNotifier

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
    parseLogRecord = (\s -> first (,s) $ strDecode s) . trimCR . LB.toStrict
    procLogRecord :: Map RecipientId QueueRec -> StoreLogRecord -> Map RecipientId QueueRec
    procLogRecord m = \case
      CreateQueue q -> M.insert (recipientId q) q m
      SecureQueue qId sKey -> M.adjust (\q -> q {senderKey = Just sKey}) qId m
      AddNotifier qId ntfCreds -> M.adjust (\q -> q {notifier = Just ntfCreds}) qId m
      SuspendQueue qId -> M.adjust (\q -> q {status = QueueOff}) qId m
      DeleteQueue qId -> M.delete qId m
      DeleteNotifier qId -> M.adjust (\q -> q {notifier = Nothing}) qId m
    printError :: LogParsingError -> IO ()
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
