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
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.QueueStore
import UnliftIO.STM

data QueueStoreData = QueueStoreData
  { queues :: Map SMP.RecipientId QueueRec,
    senders :: Map SMP.SenderId SMP.RecipientId
  }

type QueueStore = TVar QueueStoreData

newQueueStore :: STM QueueStore
newQueueStore = newTVar QueueStoreData {queues = M.empty, senders = M.empty}

instance MonadQueueStore QueueStore STM where
  addQueue :: QueueStore -> SMP.RecipientKey -> (SMP.RecipientId, SMP.SenderId) -> STM (Either SMP.ErrorType ())
  addQueue store rKey ids@(rId, sId) = do
    cs@QueueStoreData {queues, senders} <- readTVar store
    if M.member rId queues || M.member sId senders
      then return $ Left SMP.DUPLICATE
      else do
        writeTVar store $
          cs
            { queues = M.insert rId (mkQueueRec rKey ids) queues,
              senders = M.insert sId rId senders
            }
        return $ Right ()

  getQueue :: QueueStore -> SMP.SParty (p :: SMP.Party) -> SMP.QueueId -> STM (Either SMP.ErrorType QueueRec)
  getQueue store SMP.SRecipient rId = do
    cs <- readTVar store
    return $ getRcpQueue cs rId
  getQueue store SMP.SSender sId = do
    cs <- readTVar store
    let rId = M.lookup sId $ senders cs
    return $ maybe (Left SMP.AUTH) (getRcpQueue cs) rId
  getQueue _ SMP.SBroker _ =
    return $ Left SMP.INTERNAL

  secureQueue store rId sKey =
    updateQueues store rId $ \cs c ->
      case senderKey c of
        Just _ -> (Left SMP.AUTH, cs)
        _ -> (Right (), cs {queues = M.insert rId c {senderKey = Just sKey} (queues cs)})

  suspendQueue :: QueueStore -> SMP.RecipientId -> STM (Either SMP.ErrorType ())
  suspendQueue store rId =
    updateQueues store rId $ \cs c ->
      (Right (), cs {queues = M.insert rId c {status = QueueOff} (queues cs)})

  deleteQueue :: QueueStore -> SMP.RecipientId -> STM (Either SMP.ErrorType ())
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
  SMP.RecipientId ->
  (QueueStoreData -> QueueRec -> (Either SMP.ErrorType (), QueueStoreData)) ->
  STM (Either SMP.ErrorType ())
updateQueues store rId update = do
  cs <- readTVar store
  let conn = getRcpQueue cs rId
  either (return . Left) (_update cs) conn
  where
    _update cs c = do
      let (res, cs') = update cs c
      writeTVar store cs'
      return res

getRcpQueue :: QueueStoreData -> SMP.RecipientId -> Either SMP.ErrorType QueueRec
getRcpQueue cs rId = maybe (Left SMP.AUTH) Right . M.lookup rId $ queues cs
