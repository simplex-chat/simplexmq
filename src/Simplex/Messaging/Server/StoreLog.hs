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
    logCreateLink,
    logDeleteLink,
    logSecureQueue,
    logUpdateKeys,
    logAddNotifier,
    logSuspendQueue,
    logBlockQueue,
    logUnblockQueue,
    logDeleteQueue,
    logDeleteNotifier,
    logUpdateQueueTime,
    readWriteStoreLog,
    readLogLines,
    foldLogLines,
  )
where

import Control.Applicative (optional, (<|>))
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List (sort, stripPrefix)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime, nominalDay)
import Data.Time.Format.ISO8601 (iso8601Show, iso8601ParseM)
import GHC.IO (catchAny)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
-- import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.Util (ifM, tshow, unlessM, whenM)
import System.Directory (doesFileExist, listDirectory, removeFile, renameFile)
import System.IO
import System.FilePath (takeDirectory, takeFileName)

data StoreLogRecord
  = CreateQueue RecipientId QueueRec
  | CreateLink RecipientId LinkId QueueLinkData
  | DeleteLink RecipientId
  | SecureQueue QueueId SndPublicAuthKey
  | UpdateKeys RecipientId (NonEmpty RcvPublicAuthKey)
  | AddNotifier QueueId NtfCreds
  | SuspendQueue QueueId
  | BlockQueue QueueId BlockingInfo
  | UnblockQueue QueueId
  | DeleteQueue QueueId
  | DeleteNotifier QueueId
  | UpdateTime QueueId RoundedSystemTime
  deriving (Show)

data SLRTag
  = CreateQueue_
  | CreateLink_
  | DeleteLink_
  | SecureQueue_
  | UpdateKeys_
  | AddNotifier_
  | SuspendQueue_
  | BlockQueue_
  | UnblockQueue_
  | DeleteQueue_
  | DeleteNotifier_
  | UpdateTime_

instance StrEncoding QueueRec where
  strEncode QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier, status, updatedAt} =
    B.unwords
      [ "rk=" <> strEncode recipientKeys,
        "rdh=" <> strEncode rcvDhSecret,
        "sid=" <> strEncode senderId,
        "sk=" <> strEncode senderKey
      ]
      <> maybe "" ((" queue_mode=" <>) . smpEncode) queueMode
      <> opt " link_id=" (fst <$> queueData)
      <> opt " queue_data=" (snd <$> queueData)
      <> opt " notifier=" notifier
      <> opt " updated_at=" updatedAt
      <> statusStr
    where
      opt :: StrEncoding a => ByteString -> Maybe a -> ByteString
      opt param = maybe "" ((param <>) . strEncode)
      statusStr = case status of
        EntityActive -> ""
        _ -> " status=" <> strEncode status

  strP = do
    recipientKeys <- "rk=" *> strP_
    rcvDhSecret <- "rdh=" *> strP_
    senderId <- "sid=" *> strP_
    senderKey <- "sk=" *> strP
    queueMode <-
      toQueueMode <$> (" sndSecure=" *> strP)
        <|> Just <$> (" queue_mode=" *> smpP)
        <|> pure Nothing -- unknown queue mode, we cannot imply that it is contact address
    queueData <- optional $ (,) <$> (" link_id=" *> strP) <*> (" queue_data=" *> strP)
    notifier <- optional $ " notifier=" *> strP
    updatedAt <- optional $ " updated_at=" *> strP
    status <- (" status=" *> strP) <|> pure EntityActive
    pure QueueRec {recipientKeys, rcvDhSecret, senderId, senderKey, queueMode, queueData, notifier, status, updatedAt}
    where
      toQueueMode sndSecure = Just $ if sndSecure then QMMessaging else QMContact

instance StrEncoding SLRTag where
  strEncode = \case
    CreateQueue_ -> "CREATE"
    CreateLink_ -> "LINK"
    DeleteLink_ -> "LDELETE"
    SecureQueue_ -> "SECURE"
    UpdateKeys_ -> "KEYS"
    AddNotifier_ -> "NOTIFIER"
    SuspendQueue_ -> "SUSPEND"
    BlockQueue_ -> "BLOCK"
    UnblockQueue_ -> "UNBLOCK"
    DeleteQueue_ -> "DELETE"
    DeleteNotifier_ -> "NDELETE"
    UpdateTime_ -> "TIME"

  strP =
    A.choice
      [ "CREATE" $> CreateQueue_,
        "LINK" $> CreateLink_,
        "LDELETE" $> DeleteLink_,
        "SECURE" $> SecureQueue_,
        "KEYS" $> UpdateKeys_,
        "NOTIFIER" $> AddNotifier_,
        "SUSPEND" $> SuspendQueue_,
        "BLOCK" $> BlockQueue_,
        "UNBLOCK" $> UnblockQueue_,
        "DELETE" $> DeleteQueue_,
        "NDELETE" $> DeleteNotifier_,
        "TIME" $> UpdateTime_
      ]

instance StrEncoding StoreLogRecord where
  strEncode = \case
    CreateQueue rId q -> B.unwords [strEncode CreateQueue_, "rid=" <> strEncode rId, strEncode q]
    CreateLink rId lnkId d -> strEncode (CreateLink_, rId, lnkId, d)
    DeleteLink rId -> strEncode (DeleteLink_, rId)
    SecureQueue rId sKey -> strEncode (SecureQueue_, rId, sKey)
    UpdateKeys rId rKeys -> strEncode (UpdateKeys_, rId, rKeys)
    AddNotifier rId ntfCreds -> strEncode (AddNotifier_, rId, ntfCreds)
    SuspendQueue rId -> strEncode (SuspendQueue_, rId)
    BlockQueue rId info -> strEncode (BlockQueue_, rId, info)
    UnblockQueue rId -> strEncode (UnblockQueue_, rId)
    DeleteQueue rId -> strEncode (DeleteQueue_, rId)
    DeleteNotifier rId -> strEncode (DeleteNotifier_, rId)
    UpdateTime rId t ->  strEncode (UpdateTime_, rId, t)

  strP =
    strP_ >>= \case
      CreateQueue_ -> CreateQueue <$> ("rid=" *> strP_) <*> strP
      CreateLink_ -> CreateLink <$> strP_ <*> strP_ <*> strP
      DeleteLink_ -> DeleteLink <$> strP
      SecureQueue_ -> SecureQueue <$> strP_ <*> strP
      UpdateKeys_ -> UpdateKeys <$> strP_ <*> strP
      AddNotifier_ -> AddNotifier <$> strP_ <*> strP
      SuspendQueue_ -> SuspendQueue <$> strP
      BlockQueue_ -> BlockQueue <$> strP_ <*> strP
      UnblockQueue_ -> UnblockQueue <$> strP
      DeleteQueue_ -> DeleteQueue <$> strP
      DeleteNotifier_ -> DeleteNotifier <$> strP
      UpdateTime_ -> UpdateTime <$> strP_ <*> strP

openWriteStoreLog :: Bool -> FilePath -> IO (StoreLog 'WriteMode)
openWriteStoreLog append f = do
  h <- openFile f $ if append then AppendMode else WriteMode
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

logCreateQueue :: StoreLog 'WriteMode -> RecipientId -> QueueRec -> IO ()
logCreateQueue s rId q = writeStoreLogRecord s $ CreateQueue rId q

logCreateLink :: StoreLog 'WriteMode -> RecipientId -> LinkId -> QueueLinkData -> IO ()
logCreateLink s rId lnkId d = writeStoreLogRecord s $ CreateLink rId lnkId d

logDeleteLink :: StoreLog 'WriteMode -> RecipientId -> IO ()
logDeleteLink s = writeStoreLogRecord s . DeleteLink

logSecureQueue :: StoreLog 'WriteMode -> QueueId -> SndPublicAuthKey -> IO ()
logSecureQueue s qId sKey = writeStoreLogRecord s $ SecureQueue qId sKey

logUpdateKeys :: StoreLog 'WriteMode -> QueueId -> NonEmpty RcvPublicAuthKey -> IO ()
logUpdateKeys s rId rKeys = writeStoreLogRecord s $ UpdateKeys rId rKeys

logAddNotifier :: StoreLog 'WriteMode -> QueueId -> NtfCreds -> IO ()
logAddNotifier s qId ntfCreds = writeStoreLogRecord s $ AddNotifier qId ntfCreds

logSuspendQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logSuspendQueue s = writeStoreLogRecord s . SuspendQueue

logBlockQueue :: StoreLog 'WriteMode -> QueueId -> BlockingInfo -> IO ()
logBlockQueue s qId info = writeStoreLogRecord s $ BlockQueue qId info

logUnblockQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logUnblockQueue s = writeStoreLogRecord s . UnblockQueue

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
        logNote $ "preserved incomplete state " <> f' <> " as " <> (f' <> ".bak")
      renameFile tempBackup f
    readWriteLog = do
      -- log backup is made in two steps to mitigate the crash during the compacting.
      -- Temporary backup file .start will be used when it is present.
      readStore f st
      renameFile f tempBackup -- 1) make temp backup
      s <- writeLog "compacting store log (do not terminate)..." -- 2) save state
      renameBackup -- 3) timed backup
      removeStoreLogBackups f
      pure s
    writeLog msg = do
      s <- openWriteStoreLog False f
      logNote msg
      writeStore s st
      pure s
    renameBackup = do
      ts <- getCurrentTime
      let timedBackup = f <> "." <> iso8601Show ts
      renameFile tempBackup timedBackup
      logNote $ "original state preserved as " <> T.pack timedBackup

removeStoreLogBackups :: FilePath -> IO ()
removeStoreLogBackups f = do
  ts <- getCurrentTime
  times <- sort . mapMaybe backupPathTime <$> listDirectory (takeDirectory f)
  let new = addUTCTime (- nominalDay) ts
      old = addUTCTime (- oldBackupTTL) ts
      times1 = filter (< new) times -- exclude backups newer than 24 hours
      times2 = take (length times1 - minOldBackups) times1 -- keep 3 backups older than 24 hours
      toDelete = filter (< old) times2 -- remove all backups older than 21 day
  mapM_ (removeFile . backupPath) toDelete
  when (length toDelete > 0) $ do
    putStrLn $ "Removed " <> show (length toDelete) <> " backups:"
    mapM_ (putStrLn . backupPath) toDelete
  where
    backupPathTime :: FilePath -> Maybe UTCTime
    backupPathTime = iso8601ParseM <=< stripPrefix backupPathPfx
    backupPath :: UTCTime -> FilePath
    backupPath ts = f <> "." <> iso8601Show ts
    backupPathPfx = takeFileName f <> "."
    minOldBackups = 3
    oldBackupTTL = 21 * nominalDay

readLogLines :: Bool -> FilePath -> (Bool -> B.ByteString -> IO ()) -> IO ()
readLogLines tty f action = foldLogLines tty f (const action) ()

foldLogLines :: Bool -> FilePath -> (a -> Bool -> B.ByteString -> IO a) -> a -> IO a
foldLogLines tty f action initValue = do
  (count :: Int, acc) <- withFile f ReadMode $ \h -> ifM (hIsEOF h) (pure (0, initValue)) (loop h 0 initValue)
  putStrLn $ progress count
  pure acc
  where
    loop h !i !acc = do
      s <- B.hGetLine h
      eof <- hIsEOF h
      acc' <- action acc eof s
      let i' = i + 1
      when (tty && i' `mod` 100000 == 0) $ putStr (progress i' <> "\r") >> hFlush stdout
      if eof then pure (i', acc') else loop h i' acc'
    progress i = "Processed: " <> show i <> " log lines"
