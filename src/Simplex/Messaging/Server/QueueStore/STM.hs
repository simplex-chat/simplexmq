{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM where

import Control.Monad
import Data.Functor (($>))
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM)
import UnliftIO.STM

data QueueStore = QueueStore
  { queues :: TMap RecipientId QueueRec,
    senders :: TMap SenderId RecipientId,
    notifiers :: TMap NotifierId RecipientId
  }

newQueueStore :: STM QueueStore
newQueueStore = do
  queues <- TM.empty
  senders <- TM.empty
  notifiers <- TM.empty
  pure QueueStore {queues, senders, notifiers}

instance MonadQueueStore QueueStore STM where
  addQueue :: QueueStore -> QueueRec -> STM (Either ErrorType ())
  addQueue QueueStore {queues, senders} qRec@QueueRec {recipientId = rId, senderId = sId} = do
    ifM hasId (pure $ Left DUPLICATE_) $ do
      TM.insert rId qRec queues
      TM.insert sId rId senders
      pure $ Right ()
    where
      hasId = (||) <$> TM.member rId queues <*> TM.member sId senders

  getQueue :: QueueStore -> SParty p -> QueueId -> STM (Either ErrorType QueueRec)
  getQueue QueueStore {queues, senders, notifiers} party qId =
    toResult <$> case party of
      SRecipient -> TM.lookup qId queues
      SSender -> TM.lookup qId senders >>= get
      SNotifier -> TM.lookup qId notifiers >>= get
    where
      get = fmap join . mapM (`TM.lookup` queues)

  secureQueue :: QueueStore -> RecipientId -> SndPublicVerifyKey -> STM (Either ErrorType QueueRec)
  secureQueue QueueStore {queues} rId sKey =
    withQueue rId queues $ \q -> case senderKey q of
      Just _ -> pure Nothing
      _ -> TM.insert rId q {senderKey = Just sKey} queues $> Just q

  addQueueNotifier :: QueueStore -> RecipientId -> NotifierId -> NtfPublicVerifyKey -> STM (Either ErrorType QueueRec)
  addQueueNotifier QueueStore {queues, notifiers} rId nId nKey = do
    ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $
      withQueue rId queues $ \q -> case notifier q of
        Just _ -> pure Nothing
        _ -> do
          TM.insert rId q {notifier = Just (nId, nKey)} queues
          TM.insert nId rId notifiers
          pure $ Just q

  suspendQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
  suspendQueue QueueStore {queues} rId =
    withQueue rId queues $ \q ->
      TM.insert rId q {status = QueueOff} queues $> Just ()

  deleteQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
  deleteQueue QueueStore {queues, senders, notifiers} rId = do
    TM.lookupDelete rId queues >>= \case
      Just q -> do
        TM.delete (senderId q) senders
        forM_ (notifier q) $ \(nId, _) -> TM.delete nId notifiers
        pure $ Right ()
      _ -> pure $ Left AUTH

toResult :: Maybe a -> Either ErrorType a
toResult = maybe (Left AUTH) Right

withQueue :: RecipientId -> TMap RecipientId QueueRec -> (QueueRec -> STM (Maybe a)) -> STM (Either ErrorType a)
withQueue rId queues f = toResult <$> (TM.lookup rId queues >>= fmap join . mapM f)
