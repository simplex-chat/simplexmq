{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: RecipientId,
    senderId :: SenderId,
    notifierId :: Maybe NotifierId,
    recipientKey :: RecipientPublicKey,
    notifierKey :: Maybe NotifierPublicKey,
    senderKey :: Maybe SenderPublicKey,
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff deriving (Eq)

class MonadQueueStore s m where
  addQueue :: s -> RecipientPublicKey -> (RecipientId, SenderId) -> m (Either ErrorType ())
  getQueue :: s -> SParty (a :: Party) -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SenderPublicKey -> m (Either ErrorType ())
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())

mkQueueRec :: RecipientPublicKey -> (RecipientId, SenderId) -> QueueRec
mkQueueRec recipientKey (recipientId, senderId) =
  QueueRec
    { recipientId,
      senderId,
      notifierId = Nothing,
      recipientKey,
      notifierKey = Nothing,
      senderKey = Nothing,
      status = QueueActive
    }
