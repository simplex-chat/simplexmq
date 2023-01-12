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

newQueueStore :: STM QueueStore
newQueueStore = do
  queues <- TM.empty
  senders <- TM.empty
  notifiers <- TM.empty
  pure QueueStore {queues, senders, notifiers}

addQueue :: QueueStore -> QueueRec -> STM (Either ErrorType ())
addQueue QueueStore {queues, senders} q@QueueRec {recipientId = rId, senderId = sId} = do
  ifM hasId (pure $ Left DUPLICATE_) $ do
    qVar <- newTVar q
    TM.insert rId qVar queues
    TM.insert sId rId senders
    pure $ Right ()
  where
    hasId = (||) <$> TM.member rId queues <*> TM.member sId senders

getQueue :: QueueStore -> SParty p -> QueueId -> STM (Either ErrorType QueueRec)
getQueue QueueStore {queues, senders, notifiers} party qId =
  toResult <$> (mapM readTVar =<< getVar)
  where
    getVar = case party of
      SRecipient -> TM.lookup qId queues
      SSender -> TM.lookup qId senders $>>= (`TM.lookup` queues)
      SNotifier -> TM.lookup qId notifiers $>>= (`TM.lookup` queues)

secureQueue :: QueueStore -> RecipientId -> SndPublicVerifyKey -> STM (Either ErrorType QueueRec)
secureQueue QueueStore {queues} rId sKey =
  withQueue rId queues $ \qVar ->
    readTVar qVar >>= \q -> case senderKey q of
      Just k -> pure $ if sKey == k then Just q else Nothing
      _ ->
        let q' = q {senderKey = Just sKey}
         in writeTVar qVar q' $> Just q'

addQueueNotifier :: QueueStore -> RecipientId -> NtfCreds -> STM (Either ErrorType QueueRec)
addQueueNotifier QueueStore {queues, notifiers} rId ntfCreds@NtfCreds {notifierId = nId} = do
  ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $
    withQueue rId queues $ \qVar -> do
      q <- readTVar qVar
      forM_ (notifier q) $ (`TM.delete` notifiers) . notifierId
      writeTVar qVar $! q {notifier = Just ntfCreds}
      TM.insert nId rId notifiers
      pure $ Just q

deleteQueueNotifier :: QueueStore -> RecipientId -> STM (Either ErrorType ())
deleteQueueNotifier QueueStore {queues, notifiers} rId =
  withQueue rId queues $ \qVar -> do
    q <- readTVar qVar
    forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
    writeTVar qVar $! q {notifier = Nothing}
    pure $ Just ()

suspendQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
suspendQueue QueueStore {queues} rId =
  withQueue rId queues $ \qVar -> modifyTVar' qVar (\q -> q {status = QueueOff}) $> Just ()

deleteQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
deleteQueue QueueStore {queues, senders, notifiers} rId = do
  TM.lookupDelete rId queues >>= \case
    Just qVar ->
      readTVar qVar >>= \q -> do
        TM.delete (senderId q) senders
        forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
        pure $ Right ()
    _ -> pure $ Left AUTH

toResult :: Maybe a -> Either ErrorType a
toResult = maybe (Left AUTH) Right

withQueue :: RecipientId -> TMap RecipientId (TVar QueueRec) -> (TVar QueueRec -> STM (Maybe a)) -> STM (Either ErrorType a)
withQueue rId queues f = toResult <$> TM.lookup rId queues $>>= f
