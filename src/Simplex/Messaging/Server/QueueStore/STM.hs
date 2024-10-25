{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
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
  ( QueueStore (..),
    newQueueStore,
    addQueue,
    getQueue,
    secureQueue,
    addQueueNotifier,
    deleteQueueNotifier,
    suspendQueue,
    updateQueueTime,
    deleteQueue,
  )
where

import Control.Monad
import Data.Functor (($>))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=))
import UnliftIO.STM

data QueueStore = QueueStore
  { queues :: TMap RecipientId (TVar QueueRec),
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId
  }

newQueueStore :: IO QueueStore
newQueueStore = do
  queues <- TM.emptyIO
  senders <- TM.emptyIO
  notifiers <- TM.emptyIO
  pure QueueStore {queues, senders, notifiers}

addQueue :: QueueStore -> QueueRec -> IO (Either ErrorType ())
addQueue QueueStore {queues, senders} q@QueueRec {recipientId = rId, senderId = sId} = atomically $ do
  ifM hasId (pure $ Left DUPLICATE_) $ do
    TM.insertM rId (newTVar q) queues
    TM.insert sId rId senders
    pure $ Right ()
  where
    hasId = (||) <$> TM.member rId queues <*> TM.member sId senders

getQueue :: DirectParty p => QueueStore -> SParty p -> QueueId -> IO (Either ErrorType QueueRec)
getQueue QueueStore {queues, senders, notifiers} party qId =
  toResult <$> (mapM readTVarIO =<< getVar)
  where
    getVar = case party of
      SRecipient -> TM.lookupIO qId queues
      SSender -> TM.lookupIO qId senders $>>= (`TM.lookupIO` queues)
      SNotifier -> TM.lookupIO qId notifiers $>>= (`TM.lookupIO` queues)

secureQueue :: QueueStore -> RecipientId -> SndPublicAuthKey -> IO (Either ErrorType QueueRec)
secureQueue QueueStore {queues} rId sKey = toResult <$> do
  TM.lookupIO rId queues $>>= \qVar -> atomically $ 
    readTVar qVar >>= \q -> case senderKey q of
      Just k -> pure $ if sKey == k then Just q else Nothing
      _ ->
        let !q' = q {senderKey = Just sKey}
         in writeTVar qVar q' $> Just q'

addQueueNotifier :: QueueStore -> RecipientId -> NtfCreds -> IO (Either ErrorType (Maybe NotifierId))
addQueueNotifier QueueStore {queues, notifiers} rId ntfCreds@NtfCreds {notifierId = nId} = do
  TM.lookupIO rId queues >>= \case
    Just qVar -> atomically $ ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $ do
      q <- readTVar qVar
      nId_ <- forM (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers $> notifierId
      let !q' = q {notifier = Just ntfCreds}
      writeTVar qVar q'
      TM.insert nId rId notifiers
      pure $ Right nId_
    Nothing -> pure $ Left AUTH

deleteQueueNotifier :: QueueStore -> RecipientId -> IO (Either ErrorType (Maybe NotifierId))
deleteQueueNotifier QueueStore {queues, notifiers} rId =
  withQueue rId queues $ \qVar -> do
    q <- readTVar qVar
    forM (notifier q) $ \NtfCreds {notifierId} -> do
      TM.delete notifierId notifiers
      writeTVar qVar $! q {notifier = Nothing}
      pure notifierId

suspendQueue :: QueueStore -> RecipientId -> IO (Either ErrorType ())
suspendQueue QueueStore {queues} rId =
  withQueue rId queues (`modifyTVar'` \q -> q {status = QueueOff})

updateQueueTime :: QueueStore -> RecipientId -> RoundedSystemTime -> IO ()
updateQueueTime QueueStore {queues} rId t =
  void $ withQueue rId queues (`modifyTVar'` \q -> q {updatedAt = Just t})

deleteQueue :: QueueStore -> RecipientId -> IO (Either ErrorType QueueRec)
deleteQueue QueueStore {queues, senders, notifiers} rId = atomically $ do
  TM.lookupDelete rId queues >>= \case
    Just qVar ->
      readTVar qVar >>= \q -> do
        TM.delete (senderId q) senders
        forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
        pure $ Right q
    _ -> pure $ Left AUTH

toResult :: Maybe a -> Either ErrorType a
toResult = maybe (Left AUTH) Right

withQueue :: RecipientId -> TMap RecipientId (TVar QueueRec) -> (TVar QueueRec -> STM a) -> IO (Either ErrorType a)
withQueue rId queues f = toResult <$> TM.lookupIO rId queues >>= atomically . mapM f
