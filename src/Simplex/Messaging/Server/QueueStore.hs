{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import qualified Simplex.Messaging.Protocol as SMP

data QueueRec = QueueRec
  { recipientId :: SMP.QueueId,
    senderId :: SMP.QueueId,
    recipientKey :: SMP.PublicKey,
    senderKey :: Maybe SMP.PublicKey,
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff

class MonadQueueStore s m where
  addQueue :: s -> SMP.RecipientKey -> (SMP.RecipientId, SMP.SenderId) -> m (Either SMP.ErrorType ())
  getQueue :: s -> SMP.SParty (a :: SMP.Party) -> SMP.QueueId -> m (Either SMP.ErrorType QueueRec)
  secureQueue :: s -> SMP.RecipientId -> SMP.SenderKey -> m (Either SMP.ErrorType ())
  suspendQueue :: s -> SMP.RecipientId -> m (Either SMP.ErrorType ())
  deleteQueue :: s -> SMP.RecipientId -> m (Either SMP.ErrorType ())

mkQueueRec :: SMP.RecipientKey -> (SMP.RecipientId, SMP.SenderId) -> QueueRec
mkQueueRec recipientKey (recipientId, senderId) =
  QueueRec
    { recipientId,
      senderId,
      recipientKey,
      senderKey = Nothing,
      status = QueueActive
    }
