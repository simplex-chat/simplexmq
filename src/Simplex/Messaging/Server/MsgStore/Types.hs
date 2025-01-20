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
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

{-# HLINT ignore "Redundant multi-way if" #-}

module Simplex.Messaging.Server.MsgStore.Types where

import Control.Concurrent.STM
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind
import Data.Time.Clock.System (SystemTime (systemSeconds))
import GHC.TypeLits (ErrorMessage (..), TypeError)
import qualified GHC.TypeLits as Type
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Util ((<$$>), ($>>=))
import System.IO (IOMode (..))

data STMQueueStore q = STMQueueStore
  { queues :: TMap RecipientId q,
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId,
    storeLog :: TVar (Maybe (StoreLog 'WriteMode))
  }

class MsgStoreClass s => STMStoreClass s where
  stmQueueStore :: s -> STMQueueStore (StoreQueue s)
  mkQueue :: s -> RecipientId -> QueueRec -> IO (StoreQueue s)

class Monad (StoreMonad s) => MsgStoreClass s where
  type StoreMonad s = (m :: Type -> Type) | m -> s
  type MsgStoreConfig s = c | c -> s
  type StoreQueue s = q | q -> s
  type MsgQueue s = q | q -> s
  newMsgStore :: MsgStoreConfig s -> IO s
  closeMsgStore :: s -> IO ()
  withActiveMsgQueues :: Monoid a => s -> (StoreQueue s -> IO a) -> IO a
  withAllMsgQueues :: Monoid a => Bool -> s -> (StoreQueue s -> IO a) -> IO a
  logQueueStates :: s -> IO ()
  logQueueState :: StoreQueue s -> StoreMonad s ()
  recipientId' :: StoreQueue s -> RecipientId
  queueRec' :: StoreQueue s -> TVar (Maybe QueueRec)
  msgQueue_' :: StoreQueue s -> TVar (Maybe (MsgQueue s))
  queueCounts :: s -> IO QueueCounts

  addQueue :: s -> RecipientId -> QueueRec -> IO (Either ErrorType (StoreQueue s))
  getQueue :: DirectParty p => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s))
  secureQueue :: s -> StoreQueue s -> SndPublicAuthKey -> IO (Either ErrorType ())
  addQueueNotifier :: s -> StoreQueue s -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
  deleteQueueNotifier :: s -> StoreQueue s -> IO (Either ErrorType (Maybe NotifierId))
  suspendQueue :: s -> StoreQueue s -> IO (Either ErrorType ())
  blockQueue :: s -> StoreQueue s -> BlockingInfo -> IO (Either ErrorType ())
  unblockQueue :: s -> StoreQueue s -> IO (Either ErrorType ())
  updateQueueTime :: s -> StoreQueue s -> RoundedSystemTime -> IO (Either ErrorType QueueRec)

  getPeekMsgQueue :: s -> StoreQueue s -> StoreMonad s (Maybe (MsgQueue s, Message))
  getMsgQueue :: s -> StoreQueue s -> StoreMonad s (MsgQueue s)

  -- the journal queue will be closed after action if it was initially closed or idle longer than interval in config
  withIdleMsgQueue :: Int64 -> s -> StoreQueue s -> (MsgQueue s -> StoreMonad s a) -> StoreMonad s (Maybe a, Int)
  deleteQueue :: s -> StoreQueue s -> IO (Either ErrorType QueueRec)
  deleteQueueSize :: s -> StoreQueue s -> IO (Either ErrorType (QueueRec, Int))
  getQueueMessages_ :: Bool -> StoreQueue s -> MsgQueue s -> StoreMonad s [Message]
  writeMsg :: s -> StoreQueue s -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  setOverQuota_ :: StoreQueue s -> IO () -- can ONLY be used while restoring messages, not while server running
  getQueueSize_ :: MsgQueue s -> StoreMonad s Int
  tryPeekMsg_ :: StoreQueue s -> MsgQueue s -> StoreMonad s (Maybe Message)
  tryDeleteMsg_ :: StoreQueue s -> MsgQueue s -> Bool -> StoreMonad s ()
  isolateQueue :: StoreQueue s -> String -> StoreMonad s a -> ExceptT ErrorType IO a

data QueueCounts = QueueCounts
  { queueCount :: Int,
    notifierCount :: Int
  }

data MSType = MSMemory | MSHybrid | MSJournal
  deriving (Show)

data SMSType :: MSType -> Type where
  SMSMemory :: SMSType 'MSMemory
  SMSHybrid :: SMSType 'MSHybrid
  SMSJournal :: SMSType 'MSJournal

type family JournalStoreType (s :: MSType) :: Constraint where
  JournalStoreType 'MSHybrid = ()
  JournalStoreType 'MSJournal = ()
  JournalStoreType p =
    (Int ~ Bool, TypeError ('Type.Text "Store " :<>: 'ShowType p :<>: 'Type.Text " is not journal"))

data AMSType = forall s. AMSType (SMSType s)

getQueueRec :: (MsgStoreClass s, DirectParty p) => s -> SParty p -> QueueId -> IO (Either ErrorType (StoreQueue s, QueueRec))
getQueueRec st party qId =
  getQueue st party qId
    $>>= (\q -> maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec' q))

getQueueMessages :: MsgStoreClass s => Bool -> s -> StoreQueue s -> ExceptT ErrorType IO [Message]
getQueueMessages drainMsgs st q = withPeekMsgQueue st q "getQueueSize" $ maybe (pure []) (getQueueMessages_ drainMsgs q . fst)
{-# INLINE getQueueMessages #-}

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
withPeekMsgQueue :: MsgStoreClass s => s -> StoreQueue s -> String -> (Maybe (MsgQueue s, Message) -> StoreMonad s a) -> ExceptT ErrorType IO a
withPeekMsgQueue st q op a = isolateQueue q op $ getPeekMsgQueue st q >>= a
{-# INLINE withPeekMsgQueue #-}

deleteExpiredMsgs :: MsgStoreClass s => s -> StoreQueue s -> Int64 -> ExceptT ErrorType IO Int
deleteExpiredMsgs st q old =
  isolateQueue q "deleteExpiredMsgs" $
    getMsgQueue st q >>= deleteExpireMsgs_ old q

-- closed and idle queues will be closed after expiration
-- returns (expired count, queue size after expiration)
idleDeleteExpiredMsgs :: MsgStoreClass s => Int64 -> s -> StoreQueue s -> Int64 -> ExceptT ErrorType IO (Maybe Int, Int)
idleDeleteExpiredMsgs now st q old =
  isolateQueue q "idleDeleteExpiredMsgs" $
    withIdleMsgQueue now st q (deleteExpireMsgs_ old q)

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
