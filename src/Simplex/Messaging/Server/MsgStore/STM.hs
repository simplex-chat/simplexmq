{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore (..),
    STMStoreConfig (..),
  )
where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

data STMMsgStore = STMMsgStore
  { storeConfig :: STMStoreConfig,
    queues :: TMap RecipientId STMQueue',
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId
  }

type STMQueue' = STMQueue STMMsgQueue

data STMStoreConfig = STMStoreConfig
  { storePath :: Maybe FilePath,
    quota :: Int
  }

instance MsgStoreClass STMMsgStore where
  type StoreMonad STMMsgStore = STM
  type StoreQueue STMMsgStore = STMQueue'
  type MsgQueue STMMsgStore = STMMsgQueue
  type MsgStoreConfig STMMsgStore = STMStoreConfig

  newMsgStore :: STMStoreConfig -> IO STMMsgStore
  newMsgStore storeConfig = do
    queues <- TM.emptyIO
    senders <- TM.emptyIO
    notifiers <- TM.emptyIO
    pure STMMsgStore {storeConfig, queues, senders, notifiers}

  closeMsgStore _ = pure ()

  activeMsgQueues = queues
  {-# INLINE activeMsgQueues #-}

  queuesAndNotifiers st = (queues st, notifiers st)
  {-# INLINE queuesAndNotifiers #-}

  withAllMsgQueues _ = withActiveMsgQueues
  {-# INLINE withAllMsgQueues #-}

  logQueueStates _ = pure ()

  logQueueState _ = pure ()

  addQueue STMMsgStore {queues, senders, notifiers} q =
    addQueue' queues senders notifiers q =<< createLockIO
  {-# INLINE addQueue #-}

  getQueue STMMsgStore {queues, senders, notifiers} = getQueue' queues senders notifiers
  {-# INLINE getQueue #-}

  queueRec' = queueRec
  {-# INLINE queueRec' #-}

  getMsgQueue :: STMMsgStore -> RecipientId -> STMQueue' -> STM STMMsgQueue
  getMsgQueue _ _ STMQueue {msgQueue_} = readTVar msgQueue_ >>= maybe newQ pure
    where
      newQ = do
        msgQueue <- newTQueue
        canWrite <- newTVar True
        size <- newTVar 0
        let q = STMMsgQueue {msgQueue, canWrite, size}
        writeTVar msgQueue_ $! Just q
        pure q

  openedMsgQueue :: STMQueue' -> STM (Maybe STMMsgQueue)
  openedMsgQueue = readTVar . msgQueue_
  {-# INLINE openedMsgQueue #-}

  secureQueue = secureQueue' . queues
  {-# INLINE secureQueue #-}
  
  addQueueNotifier STMMsgStore {queues, notifiers} = addQueueNotifier' queues notifiers
  {-# INLINE addQueueNotifier #-}
  
  deleteQueueNotifier STMMsgStore {queues, notifiers} = deleteQueueNotifier' queues notifiers
  {-# INLINE deleteQueueNotifier #-}
  
  suspendQueue = suspendQueue' . queues
  {-# INLINE suspendQueue #-}

  updateQueueTime = updateQueueTime' . queues
  {-# INLINE updateQueueTime #-}

  deleteQueue :: STMMsgStore -> RecipientId -> ExceptT ErrorType IO QueueRec
  deleteQueue STMMsgStore {queues, senders, notifiers} rId =
    fst <$> ExceptT (atomically $ deleteQueue' queues senders notifiers rId)

  deleteQueueSize :: STMMsgStore -> RecipientId -> ExceptT ErrorType IO (QueueRec, Int)
  deleteQueueSize STMMsgStore {queues, senders, notifiers} rId =
    ExceptT (atomically $ deleteQueue' queues senders notifiers rId)
      >>= liftIO . traverse (readTVarIO >=> maybe (pure 0) (\STMMsgQueue {size} -> readTVarIO size))
    -- traverse operates on the second tuple element

  getQueueMessages_ :: Bool -> STMMsgQueue -> STM [Message]
  getQueueMessages_ drainMsgs = (if drainMsgs then flushTQueue else snapshotTQueue) . msgQueue
    where
      snapshotTQueue q = do
        msgs <- flushTQueue q
        mapM_ (writeTQueue q) msgs
        pure msgs

  writeMsg :: STMMsgStore -> RecipientId -> STMQueue' -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms rId q' _logState msg = liftIO $ atomically $ do
    STMMsgQueue {msgQueue = q, canWrite, size} <- getMsgQueue ms rId q'
    canWrt <- readTVar canWrite
    empty <- isEmptyTQueue q
    if canWrt || empty
      then do
        canWrt' <- (quota >) <$> readTVar size
        writeTVar canWrite $! canWrt'
        modifyTVar' size (+ 1)
        if canWrt'
          then (writeTQueue q $! msg) $> Just (msg, empty)
          else (writeTQueue q $! msgQuota) $> Nothing
      else pure Nothing
    where
      STMMsgStore {storeConfig = STMStoreConfig {quota}} = ms
      msgQuota = MessageQuota {msgId = messageId msg, msgTs = messageTs msg}

  setOverQuota_ :: STMQueue' -> IO ()
  setOverQuota_ q = readTVarIO (msgQueue_ q) >>= mapM_ (\mq -> atomically $ writeTVar (canWrite mq) False)

  getQueueSize_ :: STMMsgQueue -> STM Int
  getQueueSize_ STMMsgQueue {size} = readTVar size

  tryPeekMsg_ :: STMMsgQueue -> STM (Maybe Message)
  tryPeekMsg_ = tryPeekTQueue . msgQueue
  {-# INLINE tryPeekMsg_ #-}

  tryDeleteMsg_ :: STMMsgQueue -> Bool -> STM ()
  tryDeleteMsg_ STMMsgQueue {msgQueue = q, size} _logState =
    tryReadTQueue q >>= \case
      Just _ -> modifyTVar' size (subtract 1)
      _ -> pure ()

  isolateQueue :: RecipientId -> STMQueue' -> String -> STM a -> ExceptT ErrorType IO a
  isolateQueue _ _ _ = liftIO . atomically
