{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM
  ( STMQueue (..),
    addQueue',
    getQueue',
    getQueueRec',
    secureQueue',
    addQueueNotifier',
    deleteQueueNotifier',
    suspendQueue',
    updateQueueTime',
    deleteQueue',
    withLog',
  )
where

import Control.Monad
import Data.Functor (($>))
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=))
import System.IO (IOMode (..))
import UnliftIO.STM

data STMQueue q = STMQueue
  { queueLock :: Lock,
    -- To avoid race conditions and errors when restoring queues,
    -- Nothing is written to TVar when queue is deleted.
    queueRec :: TVar (Maybe QueueRec),
    msgQueue_ :: TVar (Maybe q)
  }

addQueue' ::
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  TVar (Maybe (StoreLog 'WriteMode)) ->
  QueueRec ->
  Lock ->
  IO (Either ErrorType (STMQueue q))
addQueue' queues senders notifiers storeLog qr@QueueRec {recipientId = rId, senderId = sId, notifier} lock =
  atomically add >>= mapM (\q -> q <$ withLog' storeLog (`logCreateQueue` qr))
  where
    add = ifM hasId (pure $ Left DUPLICATE_) $ do
      q <- STMQueue lock <$> (newTVar $! Just qr) <*> newTVar Nothing
      TM.insert rId q queues
      TM.insert sId rId senders
      forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
      pure $ Right q
    hasId = or <$> sequence [TM.member rId queues, TM.member sId senders, hasNotifier]
    hasNotifier = maybe (pure False) (\NtfCreds {notifierId} -> TM.member notifierId notifiers) notifier

getQueue' ::
  DirectParty p =>
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  SParty p ->
  QueueId ->
  IO (Either ErrorType (STMQueue q))
getQueue' queues senders notifiers party qId =
  maybe (Left AUTH) Right <$> case party of
    SRecipient -> TM.lookupIO qId queues
    SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
    SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)

getQueueRec' :: 
  DirectParty p =>
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  SParty p ->
  QueueId ->
  IO (Either ErrorType (STMQueue q, QueueRec))
getQueueRec' queues senders notifiers party qId =
  getQueue' queues senders notifiers party qId
    $>>= (\q -> maybe (Left AUTH) (Right . (q,)) <$> readTVarIO (queueRec q))

secureQueue' :: TVar (Maybe (StoreLog 'WriteMode)) -> STMQueue q -> SndPublicAuthKey -> IO (Either ErrorType ())
secureQueue' storeLog sq sKey =
  atomically (readQueueRec qr $>>= secure)
    >>= mapM (\rId -> withLog' storeLog $ \s -> logSecureQueue s rId sKey)
  where
    qr = queueRec sq
    secure q@QueueRec {recipientId = rId} = case senderKey q of
      Just k -> pure $ if sKey == k then Right rId else Left AUTH
      Nothing -> do
        writeTVar qr $! Just q {senderKey = Just sKey}
        pure $ Right rId

addQueueNotifier' :: TMap NotifierId RecipientId -> TVar (Maybe (StoreLog 'WriteMode)) -> STMQueue q -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier' notifiers storeLog sq ntfCreds@NtfCreds {notifierId = nId} =
  atomically (readQueueRec qr $>>= add) >>= mapM log'
  where
    qr = queueRec sq
    add q@QueueRec {recipientId = rId} = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $! Just q'
      TM.insert nId rId notifiers
      pure $ Right (rId, nId_)
    log' (rId, nId_) = nId_ <$ withLog' storeLog (\s -> logAddNotifier s rId ntfCreds)

deleteQueueNotifier' :: TMap NotifierId RecipientId -> TVar (Maybe (StoreLog 'WriteMode)) -> STMQueue q -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' notifiers storeLog sq =
  atomically (readQueueRec qr >>= mapM delete) >>= mapM log'
  where
    qr = queueRec sq
    delete q = fmap (recipientId q,) $ forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId notifiers
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId
    log' (rId, nId_) = nId_ <$ withLog' storeLog (`logDeleteNotifier` rId)

suspendQueue' :: TVar (Maybe (StoreLog 'WriteMode)) -> STMQueue q -> IO (Either ErrorType ())
suspendQueue' storeLog sq =
  atomically (readQueueRec qr >>= mapM suspend)
    >>= mapM (\rId -> withLog' storeLog (`logSuspendQueue` rId))
  where
    qr = queueRec sq
    suspend q = do
      writeTVar qr $! Just q {status = QueueOff}
      pure $ recipientId q

updateQueueTime' :: TVar (Maybe (StoreLog 'WriteMode)) -> STMQueue q -> RoundedSystemTime -> IO (Either ErrorType QueueRec)
updateQueueTime' storeLog sq t = atomically (readQueueRec qr >>= mapM update) >>= mapM log'
  where
    qr = queueRec sq
    update q@QueueRec {updatedAt}
      | updatedAt == Just t = pure (q, False)
      | otherwise =
          let !q' = q {updatedAt = Just t}
           in (writeTVar qr $! Just q') $> (q', True)
    log' (q, changed) = do
      when changed $ withLog' storeLog $ \sl -> logUpdateQueueTime sl (recipientId q) t
      pure q

deleteQueue' ::
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  TVar (Maybe (StoreLog 'WriteMode)) -> 
  RecipientId ->
  STMQueue q ->
  IO (Either ErrorType (QueueRec, Maybe q))
deleteQueue' senders notifiers storeLog rId sq =
  atomically (readQueueRec qr >>= mapM delete) >>= mapM delMsgLog
  where
    qr = queueRec sq
    delete q = do
      writeTVar qr Nothing
      TM.delete (senderId q) senders
      forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
      pure q
    delMsgLog q = do
      withLog' storeLog (`logDeleteQueue` rId)
      mq_ <- atomically $ swapTVar (msgQueue_ sq) Nothing
      pure (q, mq_)

readQueueRec :: TVar (Maybe QueueRec) -> STM (Either ErrorType QueueRec)
readQueueRec qr = maybe (Left AUTH) Right <$> readTVar qr
{-# INLINE readQueueRec #-}

withLog' :: TVar (Maybe (StoreLog 'WriteMode)) -> (StoreLog 'WriteMode -> IO a) -> IO ()
withLog' sl action = readTVarIO sl >>= mapM_ action
