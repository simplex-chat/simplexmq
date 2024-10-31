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
    deleteQueueRec',
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
    -- To avoid race conditions and errors when restoring queues,
    -- Nothing is written to TVar when queue is deleted.
    queueRec :: TVar (Maybe QueueRec),
    msgQueue_ :: TVar (Maybe q)
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
    q <- STMQueue lock <$> (newTVar $! Just qr) <*> newTVar Nothing
    TM.insert rId q queues
    TM.insert sId rId senders
    forM_ notifier $ \NtfCreds {notifierId} -> TM.insert notifierId rId notifiers
    pure $ Right q
  where
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

secureQueue' :: TVar (Maybe QueueRec) -> SndPublicAuthKey -> STM (Either ErrorType QueueRec)
secureQueue' qr sKey = readQueueRec qr $>>= secure
  where
    secure q = case senderKey q of
      Just k -> pure $ if sKey == k then Right q else Left AUTH
      Nothing ->
        let !q' = q {senderKey = Just sKey}
         in (writeTVar qr $ Just q') $> Right q'

addQueueNotifier' :: TMap NotifierId RecipientId -> TVar (Maybe QueueRec) -> NtfCreds -> STM (Either ErrorType (Maybe NotifierId))
addQueueNotifier' notifiers qr ntfCreds@NtfCreds {notifierId = nId} = readQueueRec qr $>>= add
  where
    add q = ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qr $! Just q'
      TM.insert nId (recipientId q) notifiers
      pure $ Right nId_

deleteQueueNotifier' :: TMap NotifierId RecipientId -> TVar (Maybe QueueRec) -> STM (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier' notifiers qr = readQueueRec qr >>= mapM delete
  where
    delete q = forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId notifiers
      writeTVar qr $! Just q {notifier = Nothing}
      pure notifierId

suspendQueue' :: TVar (Maybe QueueRec) -> STM (Either ErrorType ())
suspendQueue' qr = readQueueRec qr >>= mapM (\q -> writeTVar qr $! Just q {status = QueueOff})

updateQueueTime' :: TVar (Maybe QueueRec) -> RoundedSystemTime -> STM (Either ErrorType (QueueRec, Bool))
updateQueueTime' qr t = readQueueRec qr >>= mapM update
  where
    update q@QueueRec {updatedAt}
      | updatedAt == Just t = pure (q, False)
      | otherwise =
          let !q' = q {updatedAt = Just t}
           in (writeTVar qr $! Just q') $> (q', True)

deleteQueueRec' ::
  TMap SenderId RecipientId ->
  TMap NotifierId RecipientId ->
  TVar (Maybe QueueRec) ->
  STM (Either ErrorType QueueRec)
deleteQueueRec' senders notifiers qr = readQueueRec qr >>= mapM delete
  where
    delete q = do
      writeTVar qr Nothing
      TM.delete (senderId q) senders
      forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
      pure q

readQueueRec :: TVar (Maybe QueueRec) -> STM (Either ErrorType QueueRec)
readQueueRec qr = maybe (Left AUTH) Right <$> readTVar qr
{-# INLINE readQueueRec #-}
