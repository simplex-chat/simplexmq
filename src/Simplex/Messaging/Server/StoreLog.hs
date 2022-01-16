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
    logCreateQueue,
    logSecureQueue,
    logAddNotifier,
    logDeleteQueue,
    logCreateMsg,
    logAcknowledgeMsg,
    readWriteStoreLog,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless)
import Data.Bifunctor (first, second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Composition ((.:))
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Sequence (Seq (..), (|>))
import qualified Data.Sequence as Seq
import Simplex.Messaging.Encoding.String
  ( Str (Str),
    StrEncoding (..),
    strP_,
  )
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore (Message (..))
import Simplex.Messaging.Server.QueueStore (QueueRec (..), QueueStatus (..))
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
  | AddNotifier QueueId NotifierId NtfPublicVerifyKey
  | DeleteQueue QueueId
  | CreateMsg RecipientId Message
  | AcknowledgeMsg RecipientId MsgId

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
      notifierStr (nId, nKey) = " nid=" <> strEncode nId <> " nk=" <> strEncode nKey

  strP = do
    recipientId <- "rid=" *> strP_
    recipientKey <- "rk=" *> strP_
    rcvDhSecret <- "rdh=" *> strP_
    senderId <- "sid=" *> strP_
    senderKey <- "sk=" *> strP
    notifier <- optional $ (,) <$> (" nid=" *> strP_) <*> ("nk=" *> strP)
    pure QueueRec {recipientId, recipientKey, rcvDhSecret, senderId, senderKey, notifier, status = QueueActive}

instance StrEncoding StoreLogRecord where
  strEncode = \case
    CreateQueue q -> strEncode (Str "CREATE", q)
    SecureQueue rId sKey -> strEncode (Str "SECURE", rId, sKey)
    AddNotifier rId nId nKey -> strEncode (Str "NOTIFIER", rId, nId, nKey)
    DeleteQueue rId -> strEncode (Str "DELETE", rId)
    CreateMsg rId msg -> strEncode (Str "MSG", rId, msg)
    AcknowledgeMsg rId msgId -> strEncode (Str "ACK", rId, msgId)

  strP =
    "CREATE " *> (CreateQueue <$> strP)
      <|> "SECURE " *> (SecureQueue <$> strP_ <*> strP)
      <|> "NOTIFIER " *> (AddNotifier <$> strP_ <*> strP_ <*> strP)
      <|> "DELETE " *> (DeleteQueue <$> strP)
      <|> "MSG " *> (CreateMsg <$> strP_ <*> strP)
      <|> "ACK " *> (AcknowledgeMsg <$> strP_ <*> strP)

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
  B.hPutStrLn h $ strEncode r
  hFlush h

logCreateQueue :: StoreLog 'WriteMode -> QueueRec -> IO ()
logCreateQueue s = writeStoreLogRecord s . CreateQueue

logSecureQueue :: StoreLog 'WriteMode -> QueueId -> SndPublicVerifyKey -> IO ()
logSecureQueue s qId sKey = writeStoreLogRecord s $ SecureQueue qId sKey

logAddNotifier :: StoreLog 'WriteMode -> QueueId -> NotifierId -> NtfPublicVerifyKey -> IO ()
logAddNotifier s qId nId nKey = writeStoreLogRecord s $ AddNotifier qId nId nKey

logDeleteQueue :: StoreLog 'WriteMode -> QueueId -> IO ()
logDeleteQueue s = writeStoreLogRecord s . DeleteQueue

logCreateMsg :: StoreLog 'WriteMode -> RecipientId -> Message -> IO ()
logCreateMsg s = writeStoreLogRecord s .: CreateMsg

logAcknowledgeMsg :: StoreLog 'WriteMode -> RecipientId -> MsgId -> IO ()
logAcknowledgeMsg s = writeStoreLogRecord s .: AcknowledgeMsg

type QueueData = (QueueRec, Seq Message)

readWriteStoreLog :: StoreLog 'ReadMode -> IO (Map RecipientId QueueData, StoreLog 'WriteMode)
readWriteStoreLog s@(ReadStoreLog f _) = do
  qd <- readQueueData s
  closeStoreLog s
  s' <- openWriteStoreLog f
  writeQueueData s' qd
  pure (qd, s')

writeQueueData :: StoreLog 'WriteMode -> Map RecipientId QueueData -> IO ()
writeQueueData s = mapM_ logQueueData . M.filter (active . fst)
  where
    active QueueRec {status} = status == QueueActive
    logQueueData (q, ms) = do
      logCreateQueue s q
      mapM_ (logCreateMsg s $ recipientId q) ms

type LogParsingError = (String, ByteString)

readQueueData :: StoreLog 'ReadMode -> IO (Map RecipientId QueueData)
readQueueData (ReadStoreLog _ h) = LB.hGetContents h >>= returnResult . procStoreLog
  where
    procStoreLog :: LB.ByteString -> ([LogParsingError], Map RecipientId QueueData)
    procStoreLog = second (foldl' procLogRecord M.empty) . partitionEithers . map parseLogRecord . LB.lines
    returnResult :: ([LogParsingError], Map RecipientId QueueData) -> IO (Map RecipientId QueueData)
    returnResult (errs, res) = mapM_ printError errs $> res
    parseLogRecord :: LB.ByteString -> Either LogParsingError StoreLogRecord
    parseLogRecord = (\s -> first (,s) $ strDecode s) . trimCR . LB.toStrict
    procLogRecord :: Map RecipientId QueueData -> StoreLogRecord -> Map RecipientId QueueData
    procLogRecord m = \case
      CreateQueue q -> M.insert (recipientId q) (q, Seq.empty) m
      SecureQueue qId sKey -> M.adjust (first $ \q -> q {senderKey = Just sKey}) qId m
      AddNotifier qId nId nKey -> M.adjust (first $ \q -> q {notifier = Just (nId, nKey)}) qId m
      DeleteQueue qId -> M.delete qId m
      CreateMsg rId msg -> M.adjust (second (|> msg)) rId m
      AcknowledgeMsg rId msgId -> M.adjust (second $ ackMsg msgId) rId m
      where
        ackMsg msgId' = \case
          Seq.Empty -> Seq.Empty
          s@(Message {msgId} :<| s')
            | msgId' == msgId -> s'
            | otherwise -> s
    printError :: LogParsingError -> IO ()
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
