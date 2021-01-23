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
import Simplex.Messaging.Types
import UnliftIO.STM

data QueueStoreData = QueueStoreData
  { queues :: Map RecipientId QueueRec,
    senders :: Map SenderId RecipientId
  }

type QueueStore = TVar QueueStoreData

newQueueStore :: STM QueueStore
newQueueStore = newTVar QueueStoreData {queues = M.empty, senders = M.empty}

instance MonadQueueStore QueueStore STM where
  addQueue :: QueueStore -> RecipientKey -> (RecipientId, SenderId) -> STM (Either ErrorType ())
  addQueue store rKey ids@(rId, sId) = do
    cs@QueueStoreData {queues, senders} <- readTVar store
    if M.member rId queues || M.member sId senders
      then return $ Left DUPLICATE
      else do
        writeTVar store $
          cs
            { queues = M.insert rId (mkQueueRec rKey ids) queues,
              senders = M.insert sId rId senders
            }
        return $ Right ()

  getQueue :: QueueStore -> SParty (p :: Party) -> QueueId -> STM (Either ErrorType QueueRec)
  getQueue store SRecipient rId = do
    cs <- readTVar store
    return $ getRcpQueue cs rId
  getQueue store SSender sId = do
    cs <- readTVar store
    let rId = M.lookup sId $ senders cs
    return $ maybe (Left AUTH) (getRcpQueue cs) rId
  getQueue _ SBroker _ =
    return $ Left INTERNAL

  secureQueue store rId sKey =
    updateQueues store rId $ \cs c ->
      case senderKey c of
        Just _ -> (Left AUTH, cs)
        _ -> (Right (), cs {queues = M.insert rId c {senderKey = Just sKey} (queues cs)})

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
  (QueueStoreData -> QueueRec -> (Either ErrorType (), QueueStoreData)) ->
  STM (Either ErrorType ())
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
