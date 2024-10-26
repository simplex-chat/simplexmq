{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
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
import Simplex.Messaging.Protocol (ErrorType, Message (..), MsgId, RecipientId)
import Simplex.Messaging.TMap (TMap)

class Monad (StoreMonad s) => MsgStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type MsgStoreConfig s = c | c -> s
  type MsgQueue s = q | q -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  closeMsgStore :: s -> IO ()
  activeMsgQueues :: s -> TMap RecipientId (MsgQueue s)
  withAllMsgQueues :: Monoid a => Bool -> s -> (RecipientId -> MsgQueue s -> IO a) -> IO a
  logQueueStates :: s -> IO ()
  logQueueState :: MsgQueue s -> IO ()
  getMsgQueue :: s -> RecipientId -> ExceptT ErrorType IO (MsgQueue s)
  delMsgQueue :: s -> RecipientId -> IO ()
  delMsgQueueSize :: s -> RecipientId -> IO Int
  getQueueMessages :: Bool -> MsgQueue s -> IO [Message]
  writeMsg :: s -> MsgQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  setOverQuota_ :: MsgQueue s -> IO () -- can ONLY be used while restoring messages, not while server running
  getQueueSize :: MsgQueue s -> IO Int
  tryPeekMsg_ :: MsgQueue s -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: MsgQueue s -> Bool -> StoreMonad s ()
  isolateQueue :: MsgQueue s -> String -> StoreMonad s a -> ExceptT ErrorType IO a

data MSType = MSMemory | MSJournal

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSJournal :: SMSType 'MSJournal

data AMSType = forall s. AMSType (SMSType s)

withActiveMsgQueues :: (MsgStoreClass s, Monoid a) => s -> (RecipientId -> MsgQueue s -> IO a) -> IO a
withActiveMsgQueues st f = readTVarIO (activeMsgQueues st) >>= foldM run mempty . M.assocs
  where
    run !acc (k, v) = do
      r <- f k v
      pure $! acc <> r

tryPeekMsg :: MsgStoreClass s => MsgQueue s -> ExceptT ErrorType IO (Maybe Message)
tryPeekMsg mq = isolateQueue mq "tryPeekMsg" $ tryPeekMsg_ mq
{-# INLINE tryPeekMsg #-}

tryDelMsg :: MsgStoreClass s => MsgQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message)
tryDelMsg mq msgId' =
  isolateQueue mq "tryDelMsg" $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' ->
            tryDeleteMsg_ mq True >> pure msg_
      _ -> pure Nothing

-- atomic delete (== read) last and peek next message if available
tryDelPeekMsg :: MsgStoreClass s => MsgQueue s -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
tryDelPeekMsg mq msgId' =
  isolateQueue mq "tryDelPeekMsg" $
    tryPeekMsg_ mq >>= \case
      msg_@(Just msg)
        | msgId msg == msgId' -> (msg_,) <$> (tryDeleteMsg_ mq True >> tryPeekMsg_ mq)
        | otherwise -> pure (Nothing, msg_)
      _ -> pure (Nothing, Nothing)

deleteExpiredMsgs :: MsgStoreClass s => MsgQueue s -> Bool -> Int64 -> ExceptT ErrorType IO Int
deleteExpiredMsgs mq logState old = isolateQueue mq "deleteExpiredMsgs" $ loop 0
  where
    loop dc =
      tryPeekMsg_ mq >>= \case
        Just Message {msgTs}
          | systemSeconds msgTs < old ->
              tryDeleteMsg_ mq logState >> loop (dc + 1)
        _ -> pure dc
