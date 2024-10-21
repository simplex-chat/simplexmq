{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore (..),
    STMMsgQueue (msgQueue),
    STMStoreConfig (..),
  )
where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Simplex.Messaging.Protocol (ErrorType, Message (..), RecipientId)
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM

data STMMsgQueue = STMMsgQueue
  { msgQueue :: TQueue Message,
    quota :: Int,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

data STMMsgStore = STMMsgStore
  { storeConfig :: STMStoreConfig,
    msgQueues :: TMap RecipientId STMMsgQueue
  }

data STMStoreConfig = STMStoreConfig
  { storePath :: Maybe FilePath,
    quota :: Int
  }

instance MsgStoreClass STMMsgStore where
  type StoreMonad STMMsgStore = STM
  type MsgQueue STMMsgStore = STMMsgQueue
  type MsgStoreConfig STMMsgStore = STMStoreConfig

  newMsgStore :: STMStoreConfig -> IO STMMsgStore
  newMsgStore storeConfig = do
    msgQueues <- TM.emptyIO
    pure STMMsgStore {storeConfig, msgQueues}

  closeMsgStore _ = pure ()

  activeMsgQueues = msgQueues
  {-# INLINE activeMsgQueues #-}

  withAllMsgQueues = withActiveMsgQueues
  {-# INLINE withAllMsgQueues #-}

  logQueueStates _ = pure ()

  -- The reason for double lookup is that majority of messaging queues exist,
  -- because multiple messages are sent to the same queue,
  -- so the first lookup without STM transaction will return the queue faster.
  -- In case the queue does not exist, it needs to be looked-up again inside transaction.
  getMsgQueue :: STMMsgStore -> RecipientId -> ExceptT ErrorType IO STMMsgQueue
  getMsgQueue STMMsgStore {msgQueues = qs, storeConfig = STMStoreConfig {quota}} rId =
    liftIO $ TM.lookupIO rId qs >>= maybe (atomically maybeNewQ) pure
    where
      maybeNewQ = TM.lookup rId qs >>= maybe newQ pure
      newQ = do
        msgQueue <- newTQueue
        canWrite <- newTVar True
        size <- newTVar 0
        let q = STMMsgQueue {msgQueue, quota, canWrite, size}
        TM.insert rId q qs
        pure q

  delMsgQueue :: STMMsgStore -> RecipientId -> IO ()
  delMsgQueue st rId = atomically $ TM.delete rId $ msgQueues st

  delMsgQueueSize :: STMMsgStore -> RecipientId -> IO Int
  delMsgQueueSize st rId = atomically (TM.lookupDelete rId $ msgQueues st) >>= maybe (pure 0) (\STMMsgQueue {size} -> readTVarIO size)

  getQueueMessages :: Bool -> STMMsgQueue -> IO [Message]
  getQueueMessages drainMsgs = atomically . (if drainMsgs then flushTQueue else snapshotTQueue) . msgQueue
    where
      snapshotTQueue q = do
        msgs <- flushTQueue q
        mapM_ (writeTQueue q) msgs
        pure msgs

  writeMsg :: STMMsgStore -> STMMsgQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg _ STMMsgQueue {msgQueue = q, quota, canWrite, size} _logState !msg = liftIO $ atomically $ do
    canWrt <- readTVar canWrite
    empty <- isEmptyTQueue q
    if canWrt || empty
      then do
        canWrt' <- (quota >) <$> readTVar size
        writeTVar canWrite $! canWrt'
        modifyTVar' size (+ 1)
        if canWrt'
          then writeTQueue q msg $> Just (msg, empty)
          else (writeTQueue q $! msgQuota) $> Nothing
      else pure Nothing
    where
      msgQuota = MessageQuota {msgId = msgId msg, msgTs = msgTs msg}

  getQueueSize :: STMMsgQueue -> IO Int
  getQueueSize STMMsgQueue {size} = readTVarIO size

  tryPeekMsg_ :: STMMsgQueue -> STM (Maybe Message)
  tryPeekMsg_ = tryPeekTQueue . msgQueue
  {-# INLINE tryPeekMsg_ #-}

  tryDeleteMsg_ :: STMMsgQueue -> STM ()
  tryDeleteMsg_ STMMsgQueue {msgQueue = q, size} =
    tryReadTQueue q >>= \case
      Just _ -> modifyTVar' size (subtract 1)
      _ -> pure ()

  isolateQueue :: STMMsgQueue -> String -> STM a -> ExceptT ErrorType IO a
  isolateQueue _ _ = liftIO . atomically
