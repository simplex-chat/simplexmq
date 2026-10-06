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
    loadedQueueCounts,
    getQueueMessages,
    setOverQuota_,
    deleteQuotaMsg,
  )
where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Functor (($>))
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Time.Clock.System (SystemTime (systemSeconds))
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

instance MsgStoreClass STMMsgStore where
  type QueueStore STMMsgStore = STMQueueStore STMQueue
  type StoreQueue STMMsgStore = STMQueue
  type MsgStoreConfig STMMsgStore = STMStoreConfig

  newMsgStore :: STMStoreConfig -> IO STMMsgStore
  newMsgStore storeConfig = do
    queueStore_ <- newQueueStore @STMQueue ()
    pure STMMsgStore {storeConfig, queueStore_}

  closeMsgStore = closeQueueStore @STMQueue . queueStore_
  {-# INLINE closeMsgStore #-}

  expireOldMessages :: Bool -> STMMsgStore -> Int64 -> Int64 -> IO MessageStats
  expireOldMessages _tty ms now ttl =
    withLoadedQueues (queueStore_ ms) $ atomically . expireQueueMsgs (now - ttl)

  foldRcvServiceMessages :: STMMsgStore -> ServiceId -> (a -> RecipientId -> Either ErrorType (Maybe (QueueRec, Message)) -> IO a) -> a -> IO (Either ErrorType a)
  foldRcvServiceMessages ms serviceId f = fmap Right . foldRcvServiceQueues (queueStore_ ms) serviceId f'
    where
      f' a (q, qr) = runExceptT (tryPeekMsg ms q) >>= f a (recipientId q) . ((qr,) <$$>)

  queueStore = queueStore_
  {-# INLINE queueStore #-}

  mkQueue _ rId qr = STMQueue rId <$> newTVarIO (Just qr) <*> newTVarIO Nothing
  {-# INLINE mkQueue #-}

  deleteQueue :: STMMsgStore -> STMQueue -> IO (Either ErrorType QueueRec)
  deleteQueue ms q = fst <$$> deleteQueue_ ms q

  deleteQueueSize :: STMMsgStore -> STMQueue -> IO (Either ErrorType (QueueRec, Int))
  deleteQueueSize ms q = deleteQueue_ ms q >>= mapM (traverse getSize)
    -- traverse operates on the second tuple element
    where
      getSize = maybe (pure 0) (\STMMsgQueue {size} -> readTVarIO size)

  writeMsg :: STMMsgStore -> STMQueue -> Bool -> Message -> ExceptT ErrorType IO (Maybe (Message, Bool))
  writeMsg ms q' _logState msg = liftIO $ atomically $ do
    STMMsgQueue {msgTQueue = q, canWrite, size} <- getMsgQueue q'
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

  tryPeekMsg :: STMMsgStore -> STMQueue -> ExceptT ErrorType IO (Maybe Message)
  tryPeekMsg _ q = snd <$$> withPeekMsgQueue q pure
  {-# INLINE tryPeekMsg #-}

  tryPeekMsgs :: STMMsgStore -> [STMQueue] -> ExceptT ErrorType IO (M.Map RecipientId Message)
  tryPeekMsgs st qs = M.fromList . catMaybes <$> mapM (\q -> (recipientId q,) <$$> tryPeekMsg st q) qs

  tryDelMsg :: STMMsgStore -> STMQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message)
  tryDelMsg _ q msgId' =
    withPeekMsgQueue q $
      maybe (pure Nothing) $ \(mq, msg) ->
        if messageId msg == msgId'
          then tryDeleteMsg_ mq $> Just msg
          else pure Nothing

  tryDelPeekMsg :: STMMsgStore -> STMQueue -> MsgId -> ExceptT ErrorType IO (Maybe Message, Maybe Message)
  tryDelPeekMsg _ q msgId' =
    withPeekMsgQueue q $
      maybe (pure (Nothing, Nothing)) $ \(mq, msg) ->
        if messageId msg == msgId'
          then (Just msg,) <$> (tryDeleteMsg_ mq >> tryPeekMsg_ mq)
          else pure (Nothing, Just msg)

  deleteExpiredMsgs :: STMMsgStore -> STMQueue -> Int64 -> ExceptT ErrorType IO Int
  deleteExpiredMsgs _ q old = liftIO $ atomically $ getMsgQueue q >>= deleteExpireMsgs_ old

  getQueueSize :: STMMsgStore -> STMQueue -> ExceptT ErrorType IO Int
  getQueueSize _ q = withPeekMsgQueue q $ maybe (pure 0) (getQueueSize_ . fst)
  {-# INLINE getQueueSize #-}

loadedQueueCounts :: STMMsgStore -> IO LoadedQueueCounts
loadedQueueCounts STMMsgStore {queueStore_ = st} = do
  loadedQueueCount <- M.size <$> readTVarIO (queues st)
  loadedNotifierCount <- M.size <$> readTVarIO (notifiers st)
  pure LoadedQueueCounts {loadedQueueCount, loadedNotifierCount}

getMsgQueue :: STMQueue -> STM STMMsgQueue
getMsgQueue STMQueue {msgQueue'} = readTVar msgQueue' >>= maybe newQ pure
  where
    newQ = do
      msgTQueue <- newTQueue
      canWrite <- newTVar True
      size <- newTVar 0
      let q = STMMsgQueue {msgTQueue, canWrite, size}
      writeTVar msgQueue' (Just q)
      pure q

-- The action is called with Nothing when it is known that the queue is empty
withPeekMsgQueue :: STMQueue -> (Maybe (STMMsgQueue, Message) -> STM a) -> ExceptT ErrorType IO a
withPeekMsgQueue STMQueue {msgQueue'} a =
  liftIO $ atomically $ (readTVar msgQueue' $>>= \mq -> (mq,) <$$> tryPeekMsg_ mq) >>= a

getQueueMessages :: Bool -> STMQueue -> IO [Message]
getQueueMessages drainMsgs q = atomically $ (if drainMsgs then flushTQueue else snapshotTQueue) . msgTQueue =<< getMsgQueue q
  where
    snapshotTQueue mq = do
      msgs <- flushTQueue mq
      mapM_ (writeTQueue mq) msgs
      pure msgs

-- can ONLY be used while restoring messages, not while server running
setOverQuota_ :: STMQueue -> IO ()
setOverQuota_ q = readTVarIO (msgQueue' q) >>= mapM_ (\mq -> atomically $ writeTVar (canWrite mq) False)

-- if the first message in queue head is "quota", remove it
deleteQuotaMsg :: STMQueue -> ExceptT ErrorType IO ()
deleteQuotaMsg q =
  withPeekMsgQueue q $ \case
    Just (mq, MessageQuota {}) -> tryDeleteMsg_ mq
    _ -> pure ()

expireQueueMsgs :: Int64 -> STMQueue -> STM MessageStats
expireQueueMsgs old STMQueue {msgQueue'} =
  readTVar msgQueue' >>= \case
    Just mq -> do
      expiredMsgsCount <- deleteExpireMsgs_ old mq
      storedMsgsCount <- getQueueSize_ mq
      pure MessageStats {storedMsgsCount, expiredMsgsCount, storedQueues = 1}
    -- does not create queue if it does not exist
    Nothing -> pure newMessageStats {storedQueues = 1}

deleteExpireMsgs_ :: Int64 -> STMMsgQueue -> STM Int
deleteExpireMsgs_ old mq = loop 0
  where
    loop dc =
      tryPeekMsg_ mq >>= \case
        Just Message {msgTs}
          | systemSeconds msgTs < old ->
              tryDeleteMsg_ mq >> loop (dc + 1)
        _ -> pure dc

getQueueSize_ :: STMMsgQueue -> STM Int
getQueueSize_ STMMsgQueue {size} = readTVar size

tryPeekMsg_ :: STMMsgQueue -> STM (Maybe Message)
tryPeekMsg_ = tryPeekTQueue . msgTQueue
{-# INLINE tryPeekMsg_ #-}

tryDeleteMsg_ :: STMMsgQueue -> STM ()
tryDeleteMsg_ STMMsgQueue {msgTQueue = q, size} =
  tryReadTQueue q >>= \case
    Just _ -> modifyTVar' size (subtract 1)
    _ -> pure ()

deleteQueue_ :: STMMsgStore -> STMQueue -> IO (Either ErrorType (QueueRec, Maybe STMMsgQueue))
deleteQueue_ ms q = deleteStoreQueue (queueStore_ ms) q >>= mapM remove
  where
    remove qr = (qr,) <$> atomically (swapTVar (msgQueue' q) Nothing)
