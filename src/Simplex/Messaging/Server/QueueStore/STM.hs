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
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM
  ( STMQueue (..),
    STMMsgQueue (..),
    addQueue',
    getQueue',
    secureQueue',
    secureQueueRec,
    addQueueNotifier',
    deleteQueueNotifier',
    suspendQueue',
    suspendQueueRec,
    updateQueueTime',
    updateQueueRecTime,
    deleteQueue',
  )
where

import Control.Monad
import Data.Functor (($>))
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=))
import UnliftIO.STM

data STMQueue q = STMQueue
  { queueLock :: Lock,
    queueRec :: TVar QueueRec,
    msgQueue_ :: TVar (Maybe q)
  }

data STMMsgQueue = STMMsgQueue
  { msgQueue :: TQueue Message,
    canWrite :: TVar Bool,
    size :: TVar Int
  }

addQueue' ::
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  QueueRec ->
  Lock ->
  IO (Either ErrorType (STMQueue q))
addQueue' queues senders notifiers qr@QueueRec {recipientId = rId, senderId = sId, notifier} lock = atomically $ do
  ifM hasId (pure $ Left DUPLICATE_) $ do
    q <- STMQueue lock <$> newTVar qr <*> newTVar Nothing
    TM.insert rId q queues
    TM.insert sId rId senders
    forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
    pure $ Right q
  where
    hasId = (||) <$> TM.member rId queues <*> TM.member sId senders

getQueue' ::
  DirectParty p =>
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  SParty p ->
  QueueId ->
  IO (Either ErrorType (STMQueue q))
getQueue' queues senders notifiers party qId =
  toResult <$> case party of
    SRecipient -> TM.lookupIO qId queues
    SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
    SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)

secureQueue' :: TMap RecipientId (STMQueue q) -> RecipientId -> SndPublicAuthKey -> IO (Either ErrorType QueueRec)
secureQueue' queues rId sKey =
  toResult <$> (TM.lookupIO rId queues $>>= \STMQueue {queueRec} -> atomically $ secureQueueRec queueRec sKey)

secureQueueRec :: TVar QueueRec -> SndPublicAuthKey -> STM (Maybe QueueRec)
secureQueueRec qr sKey = do
  q <- readTVar qr
  case senderKey q of
    Just k -> pure $ if sKey == k then Just q else Nothing
    _ ->
      let !q' = q {senderKey = Just sKey}
       in writeTVar qr q' $> Just q'

addQueueNotifier' :: TMap RecipientId (STMQueue q) -> TMap NotifierId RecipientId -> RecipientId -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier' queues notifiers rId ntfCreds@NtfCreds {notifierId = nId} = do
  TM.lookupIO rId queues >>= \case
    Just STMQueue {queueRec} -> atomically $ ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      q <- readTVar queueRec
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar queueRec q'
      TM.insert nId rId notifiers
      pure $ Right nId_
    Nothing -> pure $ Left AUTH

deleteQueueNotifier' :: TMap RecipientId (STMQueue q) -> TMap NotifierId RecipientId -> RecipientId -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' queues notifiers rId = withQueue rId queues $ deleteQueueRecNotifier notifiers

deleteQueueRecNotifier :: TMap NotifierId RecipientId -> TVar QueueRec -> STM (Maybe NotifierId)
deleteQueueRecNotifier notifiers qr = do
  q <- readTVar qr
  forM (notifier q) $ \NtfCreds {notifierId} -> do
    TM.delete notifierId notifiers
    writeTVar qr $! q {notifier = Nothing}
    pure notifierId

suspendQueue' :: TMap RecipientId (STMQueue q) -> RecipientId -> IO (Either ErrorType ())
suspendQueue' queues rId = withQueue rId queues $ suspendQueueRec

suspendQueueRec :: TVar QueueRec -> STM ()
suspendQueueRec = (`modifyTVar'` \q -> q {status = QueueOff})

updateQueueTime' :: TMap RecipientId (STMQueue q) -> RecipientId -> RoundedSystemTime -> IO ()
updateQueueTime' queues rId t =
  void $ withQueue rId queues (`updateQueueRecTime` t)

updateQueueRecTime :: TVar QueueRec -> RoundedSystemTime -> STM (QueueRec, Bool)
updateQueueRecTime qr t = do
  q@QueueRec {updatedAt} <- readTVar qr
  if updatedAt == Just t
    then pure (q, False)
    else let !q' = q {updatedAt = Just t} in writeTVar qr q' $> (q', True)

deleteQueue' ::
  TMap RecipientId (STMQueue q) ->
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  RecipientId ->
  STM (Either ErrorType (QueueRec, TVar (Maybe q)))
deleteQueue' queues senders notifiers rId = do
  TM.lookupDelete rId queues >>= \case
    Just STMQueue {queueRec, msgQueue_} ->
      readTVar queueRec >>= \q -> do
        TM.delete (senderId q) senders
        forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
        pure $ Right (q, msgQueue_)
    _ -> pure $ Left AUTH

toResult :: Maybe a -> Either ErrorType a
toResult = maybe (Left AUTH) Right

withQueue :: RecipientId -> TMap RecipientId (STMQueue q) -> (TVar QueueRec -> STM a) -> IO (Either ErrorType a)
withQueue rId queues f = toResult <$> TM.lookupIO rId queues >>= atomically . mapM (f . queueRec)
