{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant multi-way if" #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Control.Concurrent.STM
import Control.Monad (foldM)
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind
import qualified Data.Map.Strict as M
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Util ((<$$>))
import System.IO (IOMode (..))

class MsgStoreClass s => STMQueueStore s where
  queues' :: s -> TMap QueueId (QueueReference (StoreQueue s))
  queueCount' :: s -> TVar Int
  notifierCount' :: s -> TVar Int

  -- senders' :: s -> TMap SenderId RecipientId
  -- notifiers' :: s -> TMap NotifierId RecipientId
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
  activeMsgQueues :: s -> TMap RecipientId (QueueReference (StoreQueue s))
  withAllMsgQueues :: Monoid a => Bool -> s -> (RecipientId -> StoreQueue s -> IO a) -> IO a
  logQueueStates :: s -> IO ()
  logQueueState :: StoreQueue s -> StoreMonad s ()
  queueRec' :: StoreQueue s -> TVar (Maybe QueueRec)
  getPeekMsgQueue :: s -> RecipientId -> StoreQueue s -> StoreMonad s (Maybe (MsgQueue s, Message))
  getMsgQueue :: s -> RecipientId -> StoreQueue s -> StoreMonad s (MsgQueue s)

  -- the journal queue will be closed after action if it was initially closed or idle longer than interval in config
  withIdleMsgQueue :: Int64 -> s -> RecipientId -> StoreQueue s -> (MsgQueue s -> StoreMonad s a) -> StoreMonad s (Maybe a, Int)
  deleteQueue :: s -> RecipientId -> StoreQueue s -> IO (Either ErrorType QueueRec)
  deleteQueueSize :: s -> RecipientId -> StoreQueue s -> IO (Either ErrorType (QueueRec, Int))
  getQueueMessages_ :: Bool -> MsgQueue s -> StoreMonad s [Message]
  writeMsg :: s -> RecipientId -> StoreQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  setOverQuota_ :: StoreQueue s -> IO () -- can ONLY be used while restoring messages, not while server running
  getQueueSize_ :: MsgQueue s -> StoreMonad s Int
  tryPeekMsg_ :: StoreQueue s -> MsgQueue s -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: StoreQueue s -> MsgQueue s -> Bool -> StoreMonad s ()
  isolateQueue :: RecipientId -> StoreQueue s -> String -> StoreMonad s a -> ExceptT ErrorType IO a

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data AMSType = forall s. AMSType (SMSType s)

withActiveMsgQueues :: (MsgStoreClass s, Monoid a) => s -> (RecipientId -> StoreQueue s -> IO a) -> IO a
withActiveMsgQueues st f = readTVarIO (activeMsgQueues st) >>= foldM run mempty . M.assocs
  where
    run !acc (k, QRRecipient v) = do
      r <- f k v
      pure $! acc <> r
    run acc _ = pure acc

getQueueMessages :: MsgStoreClass s => Bool -> s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO [Message]
getQueueMessages drainMsgs st rId q = withPeekMsgQueue st rId q "getQueueSize" $ maybe (pure []) (getQueueMessages_ drainMsgs . fst)
{-# INLINE getQueueMessages #-}

getQueueSize :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO Int
getQueueSize st rId q = withPeekMsgQueue st rId q "getQueueSize" $ maybe (pure 0) (getQueueSize_ . fst)
{-# INLINE getQueueSize #-}

tryPeekMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> ExceptT ErrorType IO (Maybe Message)
tryPeekMsg st rId q = snd <$$> withPeekMsgQueue st rId q "tryPeekMsg" pure
{-# INLINE tryPeekMsg #-}

tryDelMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message)
tryDelMsg st rId q msgId' =
  withPeekMsgQueue st rId q "tryDelMsg" $
    maybe (pure Nothing) $ \(mq, msg) ->
      if
        | messageId msg == msgId' ->
            tryDeleteMsg_ q mq True $> Just msg
        | otherwise -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
tryDelPeekMsg st rId q msgId' =
  withPeekMsgQueue st rId q "tryDelPeekMsg" $
    maybe (pure (Nothing, Nothing)) $ \(mq, msg) ->
      if
        | messageId msg == msgId' -> (Just msg,) <$> (tryDeleteMsg_ q mq True >> tryPeekMsg_ q mq)
        | otherwise -> pure (Nothing, Just msg)

-- The action is called with Nothing when it is known that the queue is empty
withPeekMsgQueue :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> String -> (Maybe (MsgQueue s, Message) -> StoreMonad s a) -> ExceptT ErrorType IO a
withPeekMsgQueue st rId q op a = isolateQueue rId q op $ getPeekMsgQueue st rId q >>= a
{-# INLINE withPeekMsgQueue #-}

deleteExpiredMsgs :: MsgStoreClass s => s -> RecipientId -> StoreQueue s -> Int64 -> ExceptT ErrorType IO Int
deleteExpiredMsgs st rId q old =
  isolateQueue rId q "deleteExpiredMsgs" $
    getMsgQueue st rId q >>= deleteExpireMsgs_ old q

-- closed and idle queues will be closed after expiration
-- returns (expired count, queue size after expiration)
idleDeleteExpiredMsgs :: MsgStoreClass s => Int64 -> s -> RecipientId -> StoreQueue s -> Int64 -> ExceptT ErrorType IO (Maybe Int, Int)
idleDeleteExpiredMsgs now st rId q old =
  isolateQueue rId q "idleDeleteExpiredMsgs" $
    withIdleMsgQueue now st rId q (deleteExpireMsgs_ old q)

deleteExpireMsgs_ :: MsgStoreClass s => Int64 -> StoreQueue s -> MsgQueue s -> StoreMonad s Int
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
