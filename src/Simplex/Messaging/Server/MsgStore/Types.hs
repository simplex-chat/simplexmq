{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant multi-way if" #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Util ((<$$>), ($>>=))

class (Monad (StoreMonad s), QueueStoreClass (StoreQueue s) (QueueStore s)) => MsgStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type MsgStoreConfig s = c | c -> s
  type StoreQueue s = q | q -> s
  type QueueStore s = qs | qs -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  closeMsgStore :: s -> IO ()
  withActiveMsgQueues :: Monoid a => s -> (StoreQueue s -> IO a) -> IO a
  -- This function can only be used in server CLI commands or before server is started.
  -- tty, withData, store
  unsafeWithAllMsgQueues :: Monoid a => Bool -> Bool -> s -> (StoreQueue s -> IO a) -> IO a
  -- tty, store, now, ttl
  expireOldMessages :: Bool -> s -> Int64 -> Int64 -> IO MessageStats
  logQueueStates :: s -> IO ()
  logQueueState :: StoreQueue s -> StoreMonad s ()
  queueStore :: s -> QueueStore s
  loadedQueueCounts :: s -> IO LoadedQueueCounts

  -- message store methods
  mkQueue :: s -> Bool -> RecipientId -> QueueRec -> IO (StoreQueue s)
  getMsgQueue :: s -> StoreQueue s -> Bool -> StoreMonad s (MsgQueue (StoreQueue s))
  getPeekMsgQueue :: s -> StoreQueue s -> StoreMonad s (Maybe (MsgQueue (StoreQueue s), Message))

  -- the journal queue will be closed after action if it was initially closed or idle longer than interval in config
  withIdleMsgQueue :: Int64 -> s -> StoreQueue s -> (MsgQueue (StoreQueue s) -> StoreMonad s a) -> StoreMonad s (Maybe a, Int)
  deleteQueue :: s -> StoreQueue s -> IO (Either ErrorType QueueRec)
  deleteQueueSize :: s -> StoreQueue s -> IO (Either ErrorType (QueueRec, Int))
  getQueueMessages_ :: Bool -> StoreQueue s -> MsgQueue (StoreQueue s) -> StoreMonad s [Message]
  writeMsg :: s -> StoreQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  setOverQuota_ :: StoreQueue s -> IO () -- can ONLY be used while restoring messages, not while server running
  getQueueSize_ :: MsgQueue (StoreQueue s) -> StoreMonad s Int
  tryPeekMsg_ :: StoreQueue s -> MsgQueue (StoreQueue s) -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: StoreQueue s -> MsgQueue (StoreQueue s) -> Bool -> StoreMonad s ()
  isolateQueue :: StoreQueue s -> Text -> StoreMonad s a -> ExceptT ErrorType IO a
  unsafeRunStore :: StoreQueue s -> Text -> StoreMonad s a -> IO a

data MSType = MSMemory | MSJournal

data QSType = QSMemory | QSPostgres

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data SQSType :: QSType -> Type where
  SQSMemory :: SQSType 'QSMemory
  SQSPostgres :: SQSType 'QSPostgres

data MessageStats = MessageStats
  { storedMsgsCount :: Int,
    expiredMsgsCount :: Int,
    storedQueues :: Int
  }

instance Monoid MessageStats where
  mempty = MessageStats 0 0 0
  {-# INLINE mempty #-}

instance Semigroup MessageStats where
  MessageStats a b c <> MessageStats x y z = MessageStats (a + x) (b + y) (c + z)
  {-# INLINE (<>) #-}

data LoadedQueueCounts = LoadedQueueCounts
  { loadedQueueCount :: Int,
    loadedNotifierCount :: Int,
    openJournalCount :: Int,
    queueLockCount :: Int,
    notifierLockCount :: Int
  }

newMessageStats :: MessageStats
newMessageStats = MessageStats 0 0 0

addQueue :: MsgStoreClass s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue st = addQueue_ (queueStore st) (mkQueue st True)
{-# INLINE addQueue #-}

getQueue :: (MsgStoreClass s, QueueParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
getQueue st = getQueue_ (queueStore st) (mkQueue st)
{-# INLINE getQueue #-}

getQueues :: (MsgStoreClass s, BatchParty p) => s -> SParty p -> [QueueId] -> IO [Either ErrorType (StoreQueue s)]
getQueues st = getQueues_ (queueStore st) (mkQueue st)
{-# INLINE getQueues #-}

getQueueRec :: (MsgStoreClass s, QueueParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s, QueueRec))
getQueueRec st party qId = getQueue st party qId $>>= readQueueRec

getQueueRecs :: (MsgStoreClass s, BatchParty p) => s -> SParty p -> [QueueId] -> IO [Either ErrorType (StoreQueue s, QueueRec)]
getQueueRecs st party qIds = getQueues st party qIds >>= mapM (fmap join . mapM readQueueRec)

readQueueRec :: StoreQueueClass q => q -> IO (Either ErrorType (q, QueueRec))
readQueueRec q = maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec q)
{-# INLINE readQueueRec #-}

getQueueSize :: MsgStoreClass s => s -> StoreQueue s -> ExceptT ErrorType IO Int
getQueueSize st q = withPeekMsgQueue st q "getQueueSize" $ maybe (pure 0) (getQueueSize_ . fst)
{-# INLINE getQueueSize #-}

tryPeekMsg :: MsgStoreClass s => s -> StoreQueue s -> ExceptT ErrorType IO (Maybe Message)
tryPeekMsg st q = snd <$$> withPeekMsgQueue st q "tryPeekMsg" pure
{-# INLINE tryPeekMsg #-}

tryDelMsg :: MsgStoreClass s => s -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message)
tryDelMsg st q msgId' =
  withPeekMsgQueue st q "tryDelMsg" $
    maybe (pure Nothing) $ \(mq, msg) ->
      if
        | messageId msg == msgId' ->
            tryDeleteMsg_ q mq True $> Just msg
        | otherwise -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgStoreClass s => s -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
tryDelPeekMsg st q msgId' =
  withPeekMsgQueue st q "tryDelPeekMsg" $
    maybe (pure (Nothing, Nothing)) $ \(mq, msg) ->
      if
        | messageId msg == msgId' -> (Just msg,) <$> (tryDeleteMsg_ q mq True >> tryPeekMsg_ q mq)
        | otherwise -> pure (Nothing, Just msg)

-- The action is called with Nothing when it is known that the queue is empty
withPeekMsgQueue :: MsgStoreClass s => s -> StoreQueue s -> Text -> (Maybe (MsgQueue (StoreQueue s), Message) -> StoreMonad s a) -> ExceptT ErrorType IO a
withPeekMsgQueue st q op a = isolateQueue q op $ getPeekMsgQueue st q >>= a
{-# INLINE withPeekMsgQueue #-}

deleteExpiredMsgs :: MsgStoreClass s => s -> StoreQueue s -> Int64 -> ExceptT ErrorType IO Int
deleteExpiredMsgs st q old =
  isolateQueue q "deleteExpiredMsgs" $
    getMsgQueue st q False >>= deleteExpireMsgs_ old q

expireQueueMsgs :: MsgStoreClass s => s -> Int64 -> Int64 -> StoreQueue s -> StoreMonad s MessageStats
expireQueueMsgs st now old q = do
  (expired_, stored) <- withIdleMsgQueue now st q $ deleteExpireMsgs_ old q
  pure MessageStats {storedMsgsCount = stored, expiredMsgsCount = fromMaybe 0 expired_, storedQueues = 1}

deleteExpireMsgs_ :: MsgStoreClass s => Int64 -> StoreQueue s -> MsgQueue (StoreQueue s) -> StoreMonad s Int
deleteExpireMsgs_ old q mq = do
  n <- loop 0
  logQueueState q
  pure n
  where
    loop dc =
      tryPeekMsg_ q mq >>= \case
        Just Message {msgTs}
          | systemSeconds msgTs < old ->
              tryDeleteMsg_ q mq False >> loop (dc + 1)
        _ -> pure dc
