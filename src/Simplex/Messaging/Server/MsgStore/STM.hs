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
import Data.Functor (($>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import Simplex.Messaging.Protocol (Message (..), RecipientId)
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

  closeMsgStore :: STMMsgStore -> IO ()
  closeMsgStore _ = pure ()

  getMsgQueues :: STMMsgStore -> IO (Map RecipientId STMMsgQueue)
  getMsgQueues = readTVarIO . msgQueues

  getMsgQueueIds :: STMMsgStore -> IO (Set RecipientId)
  getMsgQueueIds = fmap M.keysSet . readTVarIO . msgQueues

  -- The reason for double lookup is that majority of messaging queues exist,
  -- because multiple messages are sent to the same queue,
  -- so the first lookup without STM transaction will return the queue faster.
  -- In case the queue does not exist, it needs to be looked-up again inside transaction.
  getMsgQueue :: STMMsgStore -> RecipientId -> IO STMMsgQueue
  getMsgQueue STMMsgStore {msgQueues = qs, storeConfig = STMStoreConfig {quota}} rId =
    TM.lookupIO rId qs >>= maybe (atomically maybeNewQ) pure
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

  writeMsg :: STMMsgQueue -> Message -> IO (Maybe (Message, Bool))
  writeMsg STMMsgQueue {msgQueue = q, quota, canWrite, size} !msg = atomically $ do
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

  atomicQueue :: STMMsgQueue -> STM a -> IO a
  atomicQueue _ = atomically
