{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Control.Concurrent.STM
import Data.Int (Int64)
import Data.Kind
import Data.Time.Clock.System (SystemTime (systemSeconds))
import Simplex.Messaging.Protocol (Message (..), MsgId, RecipientId)
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Util (traverseWithKey_)

class Monad (StoreMonad s) => MsgStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type MsgStoreConfig s = c | c -> s
  type MsgQueue s = q | q -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  closeMsgStore :: s -> IO ()
  activeMsgQueues :: s -> TMap RecipientId (MsgQueue s)
  withAllMsgQueues :: s -> (RecipientId -> MsgQueue s -> IO ()) -> IO ()
  getMsgQueue :: s -> RecipientId -> IO (MsgQueue s)
  delMsgQueue :: s -> RecipientId -> IO ()
  delMsgQueueSize :: s -> RecipientId -> IO Int
  getQueueMessages :: Bool -> MsgQueue s -> IO [Message]
  writeMsg :: MsgQueue s -> Message -> IO (Maybe (Message, Bool))
  getQueueSize :: MsgQueue s -> IO Int
  tryPeekMsg_ :: MsgQueue s -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: MsgQueue s -> StoreMonad s ()
  atomicQueue :: MsgQueue s -> StoreMonad s a -> IO a

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data AMSType = forall s. AMSType (SMSType s)

withActiveMsgQueues :: MsgStoreClass s => s -> (RecipientId -> MsgQueue s -> IO ()) -> IO ()
withActiveMsgQueues st f = readTVarIO (activeMsgQueues st) >>= traverseWithKey_ f

tryPeekMsg :: MsgStoreClass s => MsgQueue s -> IO (Maybe Message)
tryPeekMsg mq = atomicQueue mq $ tryPeekMsg_ mq
{-# INLINE tryPeekMsg #-}

tryDelMsg :: MsgStoreClass s => MsgQueue s -> MsgId -> IO (Maybe Message)
tryDelMsg mq msgId' =
  atomicQueue mq $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' ->
            tryDeleteMsg_ mq >> pure msg_
      _ -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgStoreClass s => MsgQueue s -> MsgId -> IO (Maybe Message, Maybe Message)
tryDelPeekMsg mq msgId' =
  atomicQueue mq $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' -> (msg_,) <$> (tryDeleteMsg_ mq >> tryPeekMsg_ mq)
        | otherwise -> pure (Nothing, msg_)
      _ -> pure (Nothing, Nothing)

deleteExpiredMsgs :: MsgStoreClass s => MsgQueue s -> Int64 -> IO Int
deleteExpiredMsgs mq old = atomicQueue mq $ loop 0
  where
    loop dc =
      tryPeekMsg_ mq >>= \case
        Just Message {msgTs}
          | systemSeconds msgTs < old ->
              tryDeleteMsg_ mq >> loop (dc + 1)
        _ -> pure dc
