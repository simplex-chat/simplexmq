{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Server.StoreLog
  ( StoreLog,
    LogParsingError,
    RecordLog (..),
    openWriteStoreLog,
    openReadStoreLog,
    storeLogFilePath,
    closeStoreLog,
    logCreateQueue,
    logSecureQueue,
    logAddNotifier,
    logDeleteQueue,
    logMsgReceived,
    logMsgAcknowledged,
    readWriteStoreLog,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless)
import qualified Data.Attoparsec.ByteString.Char8 as A
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

data QueueLogRecord
  = CreateQueue QueueRec
  | SecureQueue QueueId SndPublicVerifyKey
  | AddNotifier QueueId NotifierId NtfPublicVerifyKey
  | DeleteQueue QueueId

data MsgLogRecord
  = MsgReceived RecipientId Message
  | MsgAcknowledged RecipientId MsgId

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

instance StrEncoding QueueLogRecord where
  strEncode = \case
    CreateQueue q -> strEncode (Str "CREATE", q)
    SecureQueue rId sKey -> strEncode (Str "SECURE", rId, sKey)
    AddNotifier rId nId nKey -> strEncode (Str "NOTIFIER", rId, nId, nKey)
    DeleteQueue rId -> strEncode (Str "DELETE", rId)

  strP =
    "CREATE " *> (CreateQueue <$> strP)
      <|> "SECURE " *> (SecureQueue <$> strP_ <*> strP)
      <|> "NOTIFIER " *> (AddNotifier <$> strP_ <*> strP_ <*> strP)
      <|> "DELETE " *> (DeleteQueue <$> strP)

instance StrEncoding MsgLogRecord where
  strEncode = \case
    MsgReceived rId msg -> strEncode ('R', rId, msg)
    MsgAcknowledged rId msgId -> strEncode ('D', rId, msgId)
  strP =
    (A.anyChar <* A.space) >>= \case
      'R' -> MsgReceived <$> strP_ <*> strP
      'D' -> MsgAcknowledged <$> strP_ <*> strP
      _ -> fail "bad MsgLogRecord"

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

writeStoreLogRecord :: StrEncoding a => StoreLog 'WriteMode -> a -> IO ()
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

readWriteStoreLog :: RecordLog r => StoreLog 'ReadMode -> IO (Map RecipientId r, StoreLog 'WriteMode)
readWriteStoreLog s@(ReadStoreLog f _) = do
  recs <- readRecords s
  closeStoreLog s
  s' <- openWriteStoreLog f
  writeRecords s' recs
  pure (recs, s')

class RecordLog r where
  writeRecords :: StoreLog 'WriteMode -> Map RecipientId r -> IO ()
  readRecords :: StoreLog 'ReadMode -> IO (Map RecipientId r)

instance RecordLog QueueRec where
  writeRecords s = mapM_ (writeStoreLogRecord s . CreateQueue) . M.filter active
    where
      active QueueRec {status} = status == QueueActive
  readRecords = (`readStoreLog` procLogRecord)
    where
      procLogRecord :: Map RecipientId QueueRec -> QueueLogRecord -> Map RecipientId QueueRec
      procLogRecord m = \case
        CreateQueue q -> M.insert (recipientId q) q m
        SecureQueue qId sKey -> M.adjust (\q -> q {senderKey = Just sKey}) qId m
        AddNotifier qId nId nKey -> M.adjust (\q -> q {notifier = Just (nId, nKey)}) qId m
        DeleteQueue qId -> M.delete qId m

logMsgReceived :: StoreLog 'WriteMode -> RecipientId -> Message -> IO ()
logMsgReceived s = writeStoreLogRecord s .: MsgReceived

logMsgAcknowledged :: StoreLog 'WriteMode -> RecipientId -> MsgId -> IO ()
logMsgAcknowledged s = writeStoreLogRecord s .: MsgAcknowledged

instance RecordLog (Seq Message) where
  writeRecords s = mapM_ writeMsgSeq . M.assocs . M.filter Seq.null
    where
      writeMsgSeq (rId, ms) = mapM_ (writeStoreLogRecord s . MsgReceived rId) ms
  readRecords = (`readStoreLog` procMsgLogRecord)
    where
      procMsgLogRecord :: Map RecipientId (Seq Message) -> MsgLogRecord -> Map RecipientId (Seq Message)
      procMsgLogRecord m = \case
        MsgReceived rId msg -> M.alter (Just . rcvMsg msg) rId m
        MsgAcknowledged rId msgId -> M.alter (ackMsg msgId) rId m
        where
          rcvMsg msg = \case
            Just s -> s |> msg
            _ -> Seq.singleton msg
          ackMsg msgId' = \case
            Just Seq.Empty -> Just Seq.Empty
            Just s@(Message {msgId} :<| s')
              | msgId' == msgId -> Just s'
              | otherwise -> Just s
            _ -> Nothing

type LogParsingError = (String, ByteString)

readStoreLog :: forall a r. StrEncoding a => StoreLog 'ReadMode -> (Map RecipientId r -> a -> Map RecipientId r) -> IO (Map RecipientId r)
readStoreLog (ReadStoreLog _ h) procRecord = LB.hGetContents h >>= returnResult . procStoreLog
  where
    procStoreLog :: LB.ByteString -> ([LogParsingError], Map RecipientId r)
    procStoreLog = second (foldl' procRecord M.empty) . partitionEithers . map parseLogRecord . LB.lines

parseLogRecord :: StrEncoding a => LB.ByteString -> Either LogParsingError a
parseLogRecord = (\s -> first (,s) $ strDecode s) . trimCR . LB.toStrict

returnResult :: ([LogParsingError], Map RecipientId a) -> IO (Map RecipientId a)
returnResult (errs, res) = mapM_ printError errs $> res
  where
    printError :: LogParsingError -> IO ()
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
