{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}
module Simplex.Messaging.Server.MsgStore.Types
  ( MsgStoreClass (..),
    MSType (..),
    QSType (..),
    SMSType (..),
    SQSType (..),
    MessageStats (..),
    LoadedQueueCounts (..),
    newMessageStats,
    addQueue,
    getQueue,
    getQueueRec,
    getQueues,
    getQueueRecs,
    readQueueRec,
  ) where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans.Except
import Data.Int (Int64)
import Data.Kind
import Data.Map.Strict (Map)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Util (($>>=))

class QueueStoreClass (StoreQueue s) (QueueStore s) => MsgStoreClass s where
  type MsgStoreConfig s = c | c -> s
  type StoreQueue s = q | q -> s
  type QueueStore s = qs | qs -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  closeMsgStore :: s -> IO ()
  -- tty, store, now, ttl
  expireOldMessages :: Bool -> s -> Int64 -> Int64 -> IO MessageStats
  foldRcvServiceMessages :: s -> ServiceId -> (a -> RecipientId -> Either ErrorType (Maybe (QueueRec, Message)) -> IO a) -> a -> IO (Either ErrorType a)
  queueStore :: s -> QueueStore s

  -- message store methods
  mkQueue :: s -> RecipientId -> QueueRec -> IO (StoreQueue s)
  deleteQueue :: s -> StoreQueue s -> IO (Either ErrorType QueueRec)
  deleteQueueSize :: s -> StoreQueue s -> IO (Either ErrorType (QueueRec, Int))
  writeMsg :: s -> StoreQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  tryPeekMsg :: s -> StoreQueue s -> ExceptT ErrorType IO (Maybe Message)
  tryPeekMsgs :: s -> [StoreQueue s] -> ExceptT ErrorType IO (Map RecipientId Message)
  tryDelMsg :: s -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message)
  -- atomic delete (== read) last and peek next message if available
  tryDelPeekMsg :: s -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
  deleteExpiredMsgs :: s -> StoreQueue s -> Int64 -> ExceptT ErrorType IO Int
  getQueueSize :: s -> StoreQueue s -> ExceptT ErrorType IO Int

data MSType = MSMemory | MSPostgres

data QSType = QSMemory | QSPostgres

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSPostgres :: SMSType 'MSPostgres

data SQSType :: QSType -> Type where
  SQSMemory :: SQSType 'QSMemory
  SQSPostgres :: SQSType 'QSPostgres

data MessageStats = MessageStats
  { storedMsgsCount :: Int,
    expiredMsgsCount :: Int,
    storedQueues :: Int
  }
  deriving (Show)

instance Monoid MessageStats where
  mempty = MessageStats 0 0 0
  {-# INLINE mempty #-}

instance Semigroup MessageStats where
  MessageStats a b c <> MessageStats x y z = MessageStats (a + x) (b + y) (c + z)
  {-# INLINE (<>) #-}

data LoadedQueueCounts = LoadedQueueCounts
  { loadedQueueCount :: Int,
    loadedNotifierCount :: Int
  }

newMessageStats :: MessageStats
newMessageStats = MessageStats 0 0 0

addQueue :: MsgStoreClass s => s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
addQueue st = addQueue_ (queueStore st) (mkQueue st)
{-# INLINE addQueue #-}

getQueue :: (MsgStoreClass s, QueueParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
getQueue st = getQueue_ (queueStore st) (mkQueue st)
{-# INLINE getQueue #-}

getQueueRec :: (MsgStoreClass s, QueueParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s, QueueRec))
getQueueRec st party qId = getQueue st party qId $>>= readQueueRec

getQueues :: (MsgStoreClass s, BatchParty p) => s -> SParty p -> [QueueId] -> IO [Either ErrorType (StoreQueue s)]
getQueues st = getQueues_ (queueStore st) (mkQueue st)
{-# INLINE getQueues #-}

getQueueRecs :: (MsgStoreClass s, BatchParty p) => s -> SParty p -> [QueueId] -> IO [Either ErrorType (StoreQueue s, QueueRec)]
getQueueRecs st party qIds = getQueues st party qIds >>= mapM (fmap join . mapM readQueueRec)

readQueueRec :: StoreQueueClass q => q -> IO (Either ErrorType (q, QueueRec))
readQueueRec q = maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec q)
{-# INLINE readQueueRec #-}
