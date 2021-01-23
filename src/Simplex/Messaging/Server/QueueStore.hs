{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Types
import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: QueueId,
    senderId :: QueueId,
    recipientKey :: PublicKey,
    senderKey :: Maybe PublicKey,
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff

class MonadQueueStore s m where
  addQueue :: s -> RecipientKey -> (RecipientId, SenderId) -> m (Either SMPErrorType ())
  getQueue :: s -> SParty (a :: Party) -> QueueId -> m (Either SMPErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SenderKey -> m (Either SMPErrorType ())
  suspendQueue :: s -> RecipientId -> m (Either SMPErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either SMPErrorType ())

mkQueueRec :: RecipientKey -> (RecipientId, SenderId) -> QueueRec
mkQueueRec recipientKey (recipientId, senderId) =
  QueueRec
    { recipientId,
      senderId,
      recipientKey,
      senderKey = Nothing,
      status = QueueActive
    }
