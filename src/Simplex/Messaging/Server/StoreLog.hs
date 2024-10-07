{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Server.StoreLog
  ( StoreLog, -- constructors are not exported
    StoreLogRecord (..), -- used in tests
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
    logUpdateQueueTime,
    readWriteStoreLog,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (foldM, unless, when)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor (($>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Util (ifM)
import System.Directory (doesFileExist, renameFile)
import System.IO

-- | opaque container for file handle with a type-safe IOMode
-- constructors are not exported, openWriteStoreLog and openReadStoreLog should be used instead
data StoreLog (a :: IOMode) where
  ReadStoreLog :: FilePath -> Handle -> StoreLog 'ReadMode
  WriteStoreLog :: FilePath -> Handle -> StoreLog 'WriteMode

data StoreLogRecord
  = CreateQueue QueueRec
  | SecureQueue QueueId SndPublicAuthKey
  | AddNotifier QueueId NtfCreds
  | SuspendQueue QueueId
  | DeleteQueue QueueId
  | DeleteNotifier QueueId
  | UpdateTime QueueId RoundedSystemTime
  deriving (Show)

data SLRTag
  = CreateQueue_
  | SecureQueue_
  | AddNotifier_
  | SuspendQueue_
  | DeleteQueue_
  | DeleteNotifier_
  | UpdateTime_

instance StrEncoding QueueRec where
  strEncode QueueRec {recipientId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, updatedAt} =
    B.unwords
      [ "rid=" <> strEncode recipientId,
        "rk=" <> strEncode recipientKey,
        "rdh=" <> strEncode rcvDhSecret,
        "sid=" <> strEncode senderId,
        "sk=" <> strEncode senderKey
      ]
      <> sndSecureStr
      <> maybe "" notifierStr notifier
      <> maybe "" updatedAtStr updatedAt
    where
      sndSecureStr = if sndSecure then " sndSecure=" <> strEncode sndSecure else ""
      notifierStr ntfCreds = " notifier=" <> strEncode ntfCreds
      updatedAtStr t = " updated_at=" <> strEncode t

  strP = do
    recipientId <- "rid=" *> strP_
    recipientKey <- "rk=" *> strP_
    rcvDhSecret <- "rdh=" *> strP_
    senderId <- "sid=" *> strP_
    senderKey <- "sk=" *> strP
    sndSecure <- (" sndSecure=" *> strP) <|> pure False
    notifier <- optional $ " notifier=" *> strP
    updatedAt <- optional $ " updated_at=" *> strP
    pure QueueRec {recipientId, recipientKey, rcvDhSecret, senderId, senderKey, sndSecure, notifier, status = QueueActive, updatedAt}

instance StrEncoding SLRTag where
  strEncode = \case
    CreateQueue_ -> "CREATE"
    SecureQueue_ -> "SECURE"
    AddNotifier_ -> "NOTIFIER"
    SuspendQueue_ -> "SUSPEND"
    DeleteQueue_ -> "DELETE"
    DeleteNotifier_ -> "NDELETE"
    UpdateTime_ -> "TIME"

  strP =
    A.takeTill (== ' ') >>= \case
      "CREATE" -> pure CreateQueue_
      "SECURE" -> pure SecureQueue_
      "NOTIFIER" -> pure AddNotifier_
      "SUSPEND" -> pure SuspendQueue_
      "DELETE" -> pure DeleteQueue_
      "NDELETE" -> pure DeleteNotifier_
      "TIME" -> pure UpdateTime_
      s -> fail $ "invalid log record tag: " <> B.unpack s

instance StrEncoding StoreLogRecord where
  strEncode = \case
    CreateQueue q -> strEncode (CreateQueue_, q)
    SecureQueue rId sKey -> strEncode (SecureQueue_, rId, sKey)
    AddNotifier rId ntfCreds -> strEncode (AddNotifier_, rId, ntfCreds)
    SuspendQueue rId -> strEncode (SuspendQueue_, rId)
    DeleteQueue rId -> strEncode (DeleteQueue_, rId)
    DeleteNotifier rId -> strEncode (DeleteNotifier_, rId)
    UpdateTime rId t ->  strEncode (UpdateTime_, rId, t)

  strP =
    strP_ >>= \case
      CreateQueue_ -> CreateQueue <$> strP
      SecureQueue_ -> SecureQueue <$> strP_ <*> strP
      AddNotifier_ -> AddNotifier <$> strP_ <*> strP
      SuspendQueue_ -> SuspendQueue <$> strP
      DeleteQueue_ -> DeleteQueue <$> strP
      DeleteNotifier_ -> DeleteNotifier <$> strP
      UpdateTime_ -> UpdateTime <$> strP_ <*> strP

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
  B.hPut h $ strEncode r `B.snoc` '\n' -- hPutStrLn makes write non-atomic for length > 1024
  hFlush h

logCreateQueue :: StoreLog 'WriteMode -> QueueRec -> IO ()
logCreateQueue s = writeStoreLogRecord s . CreateQueue

logSecureQueue :: StoreLog 'WriteMode -> QueueId -> SndPublicAuthKey -> IO ()
logSecureQueue s qId sKey = writeStoreLogRecord s $ SecureQueue qId sKey

logAddNotifier :: StoreLog 'WriteMode -> QueueId -> NtfCreds -> IO ()
logAddNotifier s qId ntfCreds = writeStoreLogRecord s $ AddNotifier qId ntfCreds

logSuspendQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logSuspendQueue s = writeStoreLogRecord s . SuspendQueue

logDeleteQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteQueue s = writeStoreLogRecord s . DeleteQueue

logDeleteNotifier :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteNotifier s = writeStoreLogRecord s . DeleteNotifier

logUpdateQueueTime :: StoreLog 'WriteMode -> QueueId -> RoundedSystemTime -> IO ()
logUpdateQueueTime s qId t = writeStoreLogRecord s $ UpdateTime qId t

readWriteStoreLog :: FilePath -> IO (Map RecipientId QueueRec, StoreLog 'WriteMode)
readWriteStoreLog f = do
  qs <- ifM (doesFileExist f) readQS (pure M.empty)
  s <- openWriteStoreLog f
  writeQueues s qs
  pure (qs, s)
  where
    readQS = readQueues f <* renameFile f (f <> ".bak")

writeQueues :: StoreLog 'WriteMode -> Map RecipientId QueueRec -> IO ()
writeQueues s = mapM_ $ \q -> when (active q) $ logCreateQueue s q
  where
    active QueueRec {status} = status == QueueActive

readQueues :: FilePath -> IO (Map RecipientId QueueRec)
readQueues f = foldM processLine M.empty . LB.lines =<< LB.readFile f
  where
    processLine :: Map RecipientId QueueRec -> LB.ByteString -> IO (Map RecipientId QueueRec)
    processLine m s' = case strDecode $ trimCR s of
      Right r -> pure $ procLogRecord r
      Left e -> printError e $> m
      where
        s = LB.toStrict s'
        procLogRecord :: StoreLogRecord -> Map RecipientId QueueRec
        procLogRecord = \case
          CreateQueue q -> M.insert (recipientId q) q m
          SecureQueue qId sKey -> M.adjust (\q -> q {senderKey = Just sKey}) qId m
          AddNotifier qId ntfCreds -> M.adjust (\q -> q {notifier = Just ntfCreds}) qId m
          SuspendQueue qId -> M.adjust (\q -> q {status = QueueOff}) qId m
          DeleteQueue qId -> M.delete qId m
          DeleteNotifier qId -> M.adjust (\q -> q {notifier = Nothing}) qId m
          UpdateTime qId t -> M.adjust (\q -> q {updatedAt = Just t}) qId m
        printError :: String -> IO ()
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
