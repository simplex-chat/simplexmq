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
    QueueData (..),
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
import Control.Concurrent.STM
import Control.Exception (bracket_)
import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Numeric.Natural
import Simplex.Messaging.Encoding.String
  ( Str (Str),
    StrEncoding (..),
    strP_,
  )
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore (Message (..))
import Simplex.Messaging.Server.QueueStore (QueueRec (..), QueueStatus (..))
import Simplex.Messaging.Transport (trimCR)
import Simplex.Messaging.Util (ifM, snapshotTBQueue)
import System.Directory (doesFileExist)
import System.IO

-- | opaque container for file handle with a type-safe IOMode
-- constructors are not exported, openWriteStoreLog and openReadStoreLog should be used instead
data StoreLog (a :: IOMode) where
  ReadStoreLog :: FilePath -> Handle -> StoreLog 'ReadMode
  WriteStoreLog :: FilePath -> Handle -> TMVar () -> StoreLog 'WriteMode

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
openWriteStoreLog f = WriteStoreLog f <$> openFile f WriteMode <*> newTMVarIO ()

openReadStoreLog :: FilePath -> IO (StoreLog 'ReadMode)
openReadStoreLog f = do
  doesFileExist f >>= (`unless` writeFile f "")
  ReadStoreLog f <$> openFile f ReadMode

storeLogFilePath :: StoreLog a -> FilePath
storeLogFilePath = \case
  WriteStoreLog f _ _ -> f
  ReadStoreLog f _ -> f

closeStoreLog :: StoreLog a -> IO ()
closeStoreLog = \case
  WriteStoreLog _ h _ -> hClose h
  ReadStoreLog _ h -> hClose h

writeStoreLogRecord :: StoreLog 'WriteMode -> StoreLogRecord -> IO ()
writeStoreLogRecord (WriteStoreLog _ h lock) r =
  bracket_
    (atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())
    $ do
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

data QueueData = QueueData
  { queueRec :: TVar QueueRec,
    pendingAck :: TVar (Maybe MsgId),
    messageQueue :: TBQueue Message
  }

readWriteStoreLog :: StoreLog 'ReadMode -> Natural -> IO (Map RecipientId QueueData, StoreLog 'WriteMode)
readWriteStoreLog s@(ReadStoreLog f _) quota = do
  qd <- readQueueData s quota
  closeStoreLog s
  s' <- openWriteStoreLog f
  writeQueueData s' qd
  pure (qd, s')

writeQueueData :: StoreLog 'WriteMode -> Map RecipientId QueueData -> IO ()
writeQueueData s = mapM_ logQueueData
  where
    logQueueData qd = do
      (q, ms) <- atomically $ getQueueData qd
      when (status q == QueueActive) $ do
        logCreateQueue s q
        mapM_ (logCreateMsg s $ recipientId q) ms
    getQueueData QueueData {queueRec, messageQueue} = (,) <$> readTVar queueRec <*> snapshotTBQueue messageQueue

readQueueData :: StoreLog 'ReadMode -> Natural -> IO (Map RecipientId QueueData)
readQueueData (ReadStoreLog _ h) quota = processLogLine M.empty
  where
    processLogLine m = ifM (hIsEOF h) (pure m) $ do
      s <- trimCR <$> B.hGetLine h
      case strDecode s of
        Left e -> printError (e, s) >> processLogLine m
        Right r -> case r of
          CreateQueue q -> do
            qd <- atomically $ newQueueData q
            processLogLine $ M.insert (recipientId q) qd m
          SecureQueue rId sKey ->
            updateQueue rId $ \QueueData {queueRec} ->
              atomically $ modifyTVar queueRec $ \q -> q {senderKey = Just sKey}
          AddNotifier rId nId nKey ->
            updateQueue rId $ \QueueData {queueRec} ->
              atomically $ modifyTVar queueRec $ \q -> q {notifier = Just (nId, nKey)}
          DeleteQueue rId -> processLogLine $ M.delete rId m
          CreateMsg rId msg@Message {msgId} ->
            updateQueue rId $ \QueueData {pendingAck, messageQueue} -> atomically $ do
              readTVar pendingAck >>= \case
                Just msgId'
                  | msgId' == msgId -> pure ()
                  | otherwise -> writeTBQueue messageQueue msg
                _ -> writeTBQueue messageQueue msg
          AcknowledgeMsg rId msgId' ->
            updateQueue rId $ \QueueData {pendingAck, messageQueue} -> atomically $ do
              tryPeekTBQueue messageQueue >>= \case
                Just Message {msgId}
                  | msgId' == msgId -> void $ readTBQueue messageQueue
                  | otherwise -> writeTVar pendingAck $ Just msgId'
                _ -> writeTVar pendingAck $ Just msgId'
      where
        updateQueue qId f = do
          case M.lookup qId m of
            Just qd -> f qd
            _ -> pure ()
          processLogLine m
    newQueueData q = do
      queueRec <- newTVar q
      pendingAck <- newTVar Nothing
      messageQueue <- newTBQueue quota
      pure QueueData {queueRec, pendingAck, messageQueue}
    printError (e, s) = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
