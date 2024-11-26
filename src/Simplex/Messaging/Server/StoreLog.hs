{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
    writeQueueStore,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.IO (catchAny)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog.Types
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, tshow, unlessM, whenM)
import System.Directory (doesFileExist, renameFile)
import System.IO

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
  unlessM (doesFileExist f) (writeFile f "")
  ReadStoreLog f <$> openFile f ReadMode

storeLogFilePath :: StoreLog a -> FilePath
storeLogFilePath = \case
  WriteStoreLog f _ -> f
  ReadStoreLog f _ -> f

closeStoreLog :: StoreLog a -> IO ()
closeStoreLog = \case
  WriteStoreLog _ h -> close_ h
  ReadStoreLog _ h -> close_ h
  where
    close_ h = hClose h `catchAny` \e -> logError ("STORE: closeStoreLog, error closing, " <> tshow e)

writeStoreLogRecord :: StrEncoding r => StoreLog 'WriteMode -> r -> IO ()
writeStoreLogRecord (WriteStoreLog _ h) r = E.uninterruptibleMask_ $ do
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

readWriteStoreLog :: (FilePath -> s -> IO ()) -> (StoreLog 'WriteMode -> s -> IO ()) -> FilePath -> s -> IO (StoreLog 'WriteMode)
readWriteStoreLog readStore writeStore f st =
  ifM
    (doesFileExist tempBackup)
    (useTempBackup >> readWriteLog)
    (ifM (doesFileExist f) readWriteLog (writeLog "creating store log..."))
  where
    f' = T.pack f
    tempBackup = f <> ".start"
    useTempBackup = do
      -- preserve current file, use temp backup
      logWarn $ "Server terminated abnormally on last start, restoring state from " <> T.pack tempBackup
      whenM (doesFileExist f) $ do
        renameFile f (f <> ".bak")
        logInfo $ "preserved incomplete state " <> f' <> " as " <> (f' <> ".bak")
      renameFile tempBackup f
    readWriteLog = do
      -- log backup is made in two steps to mitigate the crash during the compacting.
      -- Temporary backup file .start will be used when it is present.
      readStore f st
      renameFile f tempBackup -- 1) make temp backup
      s <- writeLog "compacting store log (do not terminate)..." -- 2) save state
      renameBackup -- 3) timed backup
      pure s
    writeLog msg = do
      s <- openWriteStoreLog f
      logInfo msg
      writeStore s st
      pure s
    renameBackup = do
      ts <- getCurrentTime
      let timedBackup = f <> "." <> iso8601Show ts
      renameFile tempBackup timedBackup
      logInfo $ "original state preserved as " <> T.pack timedBackup

writeQueueStore :: STMQueueStore s => StoreLog 'WriteMode -> s -> IO ()
writeQueueStore s st = readTVarIO (activeMsgQueues st) >>= mapM_ writeQueue . M.assocs
  where
    writeQueue (rId, q) =
      readTVarIO (queueRec' q) >>= \case
        Just q' -> when (active q') $ logCreateQueue s q' -- TODO we should log suspended queues when we use them
        Nothing -> atomically $ TM.delete rId $ activeMsgQueues st
    active QueueRec {status} = status == QueueActive
