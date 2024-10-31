{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Control.Concurrent.STM
import Control.Monad (foldM)
import Control.Monad.Trans.Except
import Data.Int (Int64)
import Data.Kind
import qualified Data.Map.Strict as M
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.TMap (TMap)
import System.IO (IOMode (..))

class MsgStoreClass s => STMQueueStore s where
  queues' :: s -> TMap RecipientId (StoreQueue s)
  senders' :: s -> TMap SenderId RecipientId
  notifiers' :: s -> TMap NotifierId RecipientId
  storeLog' :: s -> TVar (Maybe (StoreLog 'WriteMode))
  mkQueue :: s -> QueueRec -> STM (StoreQueue s)
  msgQueue_' :: StoreQueue s -> TVar (Maybe (MsgQueue s))

class Monad (StoreMonad s) => MsgStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type MsgStoreConfig s = c | c -> s
  type StoreQueue s = q | q -> s
  type MsgQueue s = q | q -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  setStoreLog :: s -> StoreLog 'WriteMode -> IO ()
  closeMsgStore :: s -> IO ()
  activeMsgQueues :: s -> TMap RecipientId (StoreQueue s)
  withAllMsgQueues :: Monoid a => Bool -> s -> (RecipientId -> StoreQueue s -> IO a) -> IO a
  logQueueStates :: s -> IO ()
  logQueueState :: StoreQueue s -> IO ()
  queueRec' :: StoreQueue s -> TVar (Maybe QueueRec)
  getMsgQueue :: s -> RecipientId -> StoreQueue s -> StoreMonad s (MsgQueue s)
  openedMsgQueue :: StoreQueue s -> StoreMonad s (Maybe (MsgQueue s))
  deleteQueue :: s -> RecipientId -> StoreQueue s -> IO (Either ErrorType QueueRec)
  deleteQueueSize :: s -> RecipientId -> StoreQueue s -> IO (Either ErrorType (QueueRec, Int))
  getQueueMessages_ :: Bool -> MsgQueue s -> StoreMonad s [Message]
  writeMsg :: s -> RecipientId -> StoreQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  setOverQuota_ :: StoreQueue s -> IO () -- can ONLY be used while restoring messages, not while server running
  getQueueSize_ :: MsgQueue s -> StoreMonad s Int
  tryPeekMsg_ :: MsgQueue s -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: MsgQueue s -> Bool -> StoreMonad s ()
  isolateQueue :: RecipientId -> StoreQueue s -> String -> StoreMonad s a -> ExceptT ErrorType IO a

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data AMSType = forall s. AMSType (SMSType s)

withActiveMsgQueues :: (MsgStoreClass s, Monoid a) => s -> (RecipientId -> StoreQueue s -> IO a) -> IO a
withActiveMsgQueues st f = readTVarIO (activeMsgQueues st) >>= foldM run mempty . M.assocs
  where
    run !acc (k, v) = do
      r <- f k v
      pure $! acc <> r

getQueueMessages :: MsgStoreClass s => Bool -> s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO [Message]
getQueueMessages drainMsgs st rId q = withMsgQueue st rId q "getQueueSize" $ getQueueMessages_ drainMsgs
{-# INLINE getQueueMessages #-}

getQueueSize :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO Int
getQueueSize st rId q = withMsgQueue st rId q "getQueueSize" $ getQueueSize_
{-# INLINE getQueueSize #-}

tryPeekMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO (Maybe Message)
tryPeekMsg st rId q = withMsgQueue st rId q "tryPeekMsg" $ tryPeekMsg_
{-# INLINE tryPeekMsg #-}

tryDelMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message)
tryDelMsg st rId q msgId' =
  withMsgQueue st rId q "tryDelMsg" $ \mq ->
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | messageId msg == msgId' ->
            tryDeleteMsg_ mq True >> pure msg_
      _ -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
tryDelPeekMsg st rId q msgId' =
  withMsgQueue st rId q "tryDelPeekMsg" $ \mq ->
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | messageId msg == msgId' -> (msg_,) <$> (tryDeleteMsg_ mq True >> tryPeekMsg_ mq)
        | otherwise -> pure (Nothing, msg_)
      _ -> pure (Nothing, Nothing)

withMsgQueue :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> String -> (MsgQueue s -> StoreMonad s a) -> ExceptT ErrorType IO a
withMsgQueue st rId q op a = isolateQueue rId q op $ getMsgQueue st rId q >>= a
{-# INLINE withMsgQueue #-}

deleteExpiredMsgs :: MsgStoreClass s => RecipientId -> StoreQueue s -> Bool -> Int64 -> ExceptT ErrorType IO Int
deleteExpiredMsgs rId q logState old =
  isolateQueue rId q "deleteExpiredMsgs" $ openedMsgQueue q >>= maybe (pure 0) (loop 0)
  where
    loop dc mq =
      tryPeekMsg_ mq >>= \case
        Just Message {msgTs}
          | systemSeconds msgTs < old ->
              tryDeleteMsg_ mq logState >> loop (dc + 1) mq
        _ -> pure dc
