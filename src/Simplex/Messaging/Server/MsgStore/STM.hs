{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.MsgStore.STM
  ( STMMsgStore (..),
    STMStoreConfig (..),
    STMQueue,
  )
where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Util ((<$$>), ($>>=))

data STMMsgStore = STMMsgStore
  { storeConfig :: STMStoreConfig,
    queueStore_ :: STMQueueStore STMQueue
  }

data STMQueue = STMQueue
  { -- To avoid race conditions and errors when restoring queues,
    -- Nothing is written to TVar when queue is deleted.
    recipientId' :: RecipientId,
    queueRec' :: TVar (Maybe QueueRec),
    msgQueue' :: TVar (Maybe STMMsgQueue)
  }

data STMMsgQueue = STMMsgQueue
  { msgTQueue :: TQueue Message,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

data STMStoreConfig = STMStoreConfig
  { storePath :: Maybe FilePath,
    quota :: Int
  }

instance StoreQueueClass STMQueue where
  recipientId = recipientId'
  {-# INLINE recipientId #-}
  queueRec = queueRec'
  {-# INLINE queueRec #-}
  withQueueLock _ _ = id
  {-# INLINE withQueueLock #-}

instance MsgStoreClass STMMsgStore where
  type StoreMonad STMMsgStore = STM
  type MsgQueue STMMsgStore = STMMsgQueue
  type QueueStore STMMsgStore = STMQueueStore STMQueue
  type StoreQueue STMMsgStore = STMQueue
  type MsgStoreConfig STMMsgStore = STMStoreConfig

  newMsgStore :: STMStoreConfig -> IO STMMsgStore
  newMsgStore storeConfig = do
    queueStore_ <- newQueueStore @STMQueue ()
    pure STMMsgStore {storeConfig, queueStore_}

  closeMsgStore = closeQueueStore @STMQueue . queueStore_
  {-# INLINE closeMsgStore #-}
  withActiveMsgQueues = withLoadedQueues . queueStore_
  {-# INLINE withActiveMsgQueues #-}
  unsafeWithAllMsgQueues _ = withLoadedQueues . queueStore_
  {-# INLINE unsafeWithAllMsgQueues #-}

  expireOldMessages :: Bool -> STMMsgStore -> Int64 -> Int64 -> IO MessageStats
  expireOldMessages _tty ms now ttl =
    withLoadedQueues (queueStore_ ms) $ atomically . expireQueueMsgs ms now (now - ttl)

  foldRcvServiceMessages :: STMMsgStore -> ServiceId -> (a -> RecipientId -> Either ErrorType (Maybe (QueueRec, Message)) -> IO a) -> a -> IO a
  foldRcvServiceMessages ms serviceId f=
    foldRcvServiceQueues (queueStore_ ms) serviceId $ \a (q, qr) ->
      runExceptT (tryPeekMsg ms q) >>= f a (recipientId q) . ((qr,) <$$>)

  logQueueStates _ = pure ()
  {-# INLINE logQueueStates #-}
  logQueueState _ = pure ()
  {-# INLINE logQueueState #-}
  queueStore = queueStore_
  {-# INLINE queueStore #-}

  loadedQueueCounts :: STMMsgStore -> IO LoadedQueueCounts
  loadedQueueCounts STMMsgStore {queueStore_ = st} = do
    loadedQueueCount <- M.size <$> readTVarIO (queues st)
    loadedNotifierCount <- M.size <$> readTVarIO (notifiers st)
    pure LoadedQueueCounts {loadedQueueCount, loadedNotifierCount, openJournalCount = 0, queueLockCount = 0, notifierLockCount = 0}

  mkQueue _ _ rId qr = STMQueue rId <$> newTVarIO (Just qr) <*> newTVarIO Nothing
  {-# INLINE mkQueue #-}

  getMsgQueue :: STMMsgStore -> STMQueue -> Bool -> STM STMMsgQueue
  getMsgQueue _ STMQueue {msgQueue'} _ = readTVar msgQueue' >>= maybe newQ pure
    where
      newQ = do
        msgTQueue <- newTQueue
        canWrite <- newTVar True
        size <- newTVar 0
        let q = STMMsgQueue {msgTQueue, canWrite, size}
        writeTVar msgQueue' (Just q)
        pure q

  getPeekMsgQueue :: STMMsgStore -> STMQueue -> STM (Maybe (STMMsgQueue, Message))
  getPeekMsgQueue _ q@STMQueue {msgQueue'} = readTVar msgQueue' $>>= \mq -> (mq,) <$$> tryPeekMsg_ q mq

  -- does not create queue if it does not exist, does not delete it if it does (can't just close in-memory queue)
  withIdleMsgQueue :: Int64 -> STMMsgStore -> STMQueue -> (STMMsgQueue -> STM a) -> STM (Maybe a, Int)
  withIdleMsgQueue _ _ STMQueue {msgQueue'} action = readTVar msgQueue' >>= \case
    Just q -> do
      r <- action q
      sz <- getQueueSize_ q
      pure (Just r, sz)
    Nothing -> pure (Nothing, 0)

  deleteQueue :: STMMsgStore -> STMQueue -> IO (Either ErrorType QueueRec)
  deleteQueue ms q = fst <$$> deleteQueue_ ms q

  deleteQueueSize :: STMMsgStore -> STMQueue -> IO (Either ErrorType (QueueRec, Int))
  deleteQueueSize ms q = deleteQueue_ ms q >>= mapM (traverse getSize)
    -- traverse operates on the second tuple element
    where
      getSize = maybe (pure 0) (\STMMsgQueue {size} -> readTVarIO size)

  getQueueMessages_ :: Bool -> STMQueue -> STMMsgQueue -> STM [Message]
  getQueueMessages_ drainMsgs _ = (if drainMsgs then flushTQueue else snapshotTQueue) . msgTQueue
    where
      snapshotTQueue q = do
        msgs <- flushTQueue q
        mapM_ (writeTQueue q) msgs
        pure msgs

  writeMsg :: STMMsgStore -> STMQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q' _logState msg = liftIO $ atomically $ do
    STMMsgQueue {msgTQueue = q, canWrite, size} <- getMsgQueue ms q' True
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

  setOverQuota_ :: STMQueue -> IO ()
  setOverQuota_ q = readTVarIO (msgQueue' q) >>= mapM_ (\mq -> atomically $ writeTVar (canWrite mq) False)

  getQueueSize_ :: STMMsgQueue -> STM Int
  getQueueSize_ STMMsgQueue {size} = readTVar size

  tryPeekMsg_ :: STMQueue -> STMMsgQueue -> STM (Maybe Message)
  tryPeekMsg_ _ = tryPeekTQueue . msgTQueue
  {-# INLINE tryPeekMsg_ #-}

  tryDeleteMsg_ :: STMQueue -> STMMsgQueue -> Bool -> STM ()
  tryDeleteMsg_ _ STMMsgQueue {msgTQueue = q, size} _logState =
    tryReadTQueue q >>= \case
      Just _ -> modifyTVar' size (subtract 1)
      _ -> pure ()

  isolateQueue :: STMMsgStore -> STMQueue -> Text -> STM a -> ExceptT ErrorType IO a
  isolateQueue _ _ _ = liftIO . atomically
  {-# INLINE isolateQueue #-}

  unsafeRunStore :: STMQueue -> Text -> STM a -> IO a
  unsafeRunStore _ _ = atomically
  {-# INLINE unsafeRunStore #-}

deleteQueue_ :: STMMsgStore -> STMQueue -> IO (Either ErrorType (QueueRec, Maybe STMMsgQueue))
deleteQueue_ ms q = deleteStoreQueue (queueStore_ ms) q >>= mapM remove
  where
    remove qr = (qr,) <$> atomically (swapTVar (msgQueue' q) Nothing)
