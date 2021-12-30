{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Server.QueueStore.STM where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore
import UnliftIO.STM

data QueueStoreData = QueueStoreData
  { queues :: Map RecipientId QueueRec,
    senders :: Map SenderId RecipientId,
    notifiers :: Map NotifierId RecipientId
  }

type QueueStore = TVar QueueStoreData

newQueueStore :: STM QueueStore
newQueueStore = newTVar QueueStoreData {queues = M.empty, senders = M.empty, notifiers = M.empty}

instance MonadQueueStore QueueStore STM where
  addQueue :: QueueStore -> QueueRec -> STM (Either ErrorType ())
  addQueue store qRec@QueueRec {recipientId = rId, senderId = sId} = do
    cs@QueueStoreData {queues, senders} <- readTVar store
    if M.member rId queues || M.member sId senders
      then return $ Left DUPLICATE_
      else do
        writeTVar store $
          cs
            { queues = M.insert rId qRec queues,
              senders = M.insert sId rId senders
            }
        return $ Right ()

  getQueue :: IsClient p => QueueStore -> SParty p -> QueueId -> STM (Either ErrorType QueueRec)
  getQueue st party qId = do
    cs <- readTVar st
    pure $ case party of
      SRecipient -> getRcpQueue cs qId
      SSender -> getPartyQueue cs senders
      SNotifier -> getPartyQueue cs notifiers
    where
      getPartyQueue ::
        QueueStoreData ->
        (QueueStoreData -> Map QueueId RecipientId) ->
        Either ErrorType QueueRec
      getPartyQueue cs recipientIds =
        case M.lookup qId $ recipientIds cs of
          Just rId -> getRcpQueue cs rId
          Nothing -> Left AUTH

  secureQueue :: QueueStore -> RecipientId -> SndPublicVerifyKey -> STM (Either ErrorType QueueRec)
  secureQueue store rId sKey =
    updateQueues store rId $ \cs c ->
      case senderKey c of
        Just _ -> (Left AUTH, cs)
        _ -> (Right c, cs {queues = M.insert rId c {senderKey = Just sKey} (queues cs)})

  addQueueNotifier :: QueueStore -> RecipientId -> NotifierId -> NtfPublicVerifyKey -> STM (Either ErrorType QueueRec)
  addQueueNotifier store rId nId nKey = do
    cs@QueueStoreData {queues, notifiers} <- readTVar store
    if M.member nId notifiers
      then pure $ Left DUPLICATE_
      else case M.lookup rId queues of
        Nothing -> pure $ Left AUTH
        Just q -> case notifier q of
          Just _ -> pure $ Left AUTH
          _ -> do
            writeTVar store $
              cs
                { queues = M.insert rId q {notifier = Just (nId, nKey)} queues,
                  notifiers = M.insert nId rId notifiers
                }
            pure $ Right q

  suspendQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
  suspendQueue store rId =
    updateQueues store rId $ \cs c ->
      (Right (), cs {queues = M.insert rId c {status = QueueOff} (queues cs)})

  deleteQueue :: QueueStore -> RecipientId -> STM (Either ErrorType ())
  deleteQueue store rId =
    updateQueues store rId $ \cs c ->
      ( Right (),
        cs
          { queues = M.delete rId (queues cs),
            senders = M.delete (senderId c) (senders cs)
          }
      )

updateQueues ::
  QueueStore ->
  RecipientId ->
  (QueueStoreData -> QueueRec -> (Either ErrorType a, QueueStoreData)) ->
  STM (Either ErrorType a)
updateQueues store rId update = do
  cs <- readTVar store
  let conn = getRcpQueue cs rId
  either (return . Left) (_update cs) conn
  where
    _update cs c = do
      let (res, cs') = update cs c
      writeTVar store cs'
      return res

getRcpQueue :: QueueStoreData -> RecipientId -> Either ErrorType QueueRec
getRcpQueue cs rId = maybe (Left AUTH) Right . M.lookup rId $ queues cs
