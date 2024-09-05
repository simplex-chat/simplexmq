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
    qVar <- newTVar q
    TM.insert rId qVar queues
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
secureQueue QueueStore {queues} rId sKey =
  atomically $ withQueue rId queues $ \qVar ->
    readTVar qVar >>= \q -> case senderKey q of
      Just k -> pure $ if sKey == k then Just q else Nothing
      _ ->
        let !q' = q {senderKey = Just sKey}
         in writeTVar qVar q' $> Just q'

addQueueNotifier :: QueueStore -> RecipientId -> NtfCreds -> IO (Either ErrorType QueueRec)
addQueueNotifier QueueStore {queues, notifiers} rId ntfCreds@NtfCreds {notifierId = nId} = atomically $ do
  ifM (TM.member nId notifiers) (pure $ Left DUPLICATE_) $
    withQueue rId queues $ \qVar -> do
      q <- readTVar qVar
      forM_ (notifier q) $ (`TM.delete` notifiers) . notifierId
      writeTVar qVar $! q {notifier = Just ntfCreds}
      TM.insert nId rId notifiers
      pure $ Just q

deleteQueueNotifier :: QueueStore -> RecipientId -> IO (Either ErrorType ())
deleteQueueNotifier QueueStore {queues, notifiers} rId =
  atomically $ withQueue rId queues $ \qVar -> do
    q <- readTVar qVar
    forM_ (notifier q) $ \NtfCreds {notifierId} -> TM.delete notifierId notifiers
    writeTVar qVar $! q {notifier = Nothing}
    pure $ Just ()

suspendQueue :: QueueStore -> RecipientId -> IO (Either ErrorType ())
suspendQueue QueueStore {queues} rId =
  atomically $ withQueue rId queues $ \qVar -> modifyTVar' qVar (\q -> q {status = QueueOff}) $> Just ()

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

withQueue :: RecipientId -> TMap RecipientId (TVar QueueRec) -> (TVar QueueRec -> STM (Maybe a)) -> STM (Either ErrorType a)
withQueue rId queues f = toResult <$> TM.lookup rId queues $>>= f
