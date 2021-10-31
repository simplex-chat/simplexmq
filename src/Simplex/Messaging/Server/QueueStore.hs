{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: RecipientId,
    senderId :: SenderId,
    notifyId :: Maybe NotifyId,
    recipientKey :: RecipientPublicKey,
    notifyKey :: Maybe SubscriberPublicKey,
    senderKey :: Maybe SenderPublicKey,
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff deriving (Eq)

class MonadQueueStore s m where
  addQueue :: s -> RecipientPublicKey -> Maybe SubscriberPublicKey -> SMPQueueIds -> m (Either ErrorType ())
  getQueue :: s -> SParty (a :: Party) -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SenderPublicKey -> m (Either ErrorType ())
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())

mkQueueRec :: RecipientPublicKey -> Maybe SubscriberPublicKey -> SMPQueueIds -> QueueRec
mkQueueRec recipientKey notifyKey (recipientId, senderId, notifyId) =
  QueueRec
    { recipientId,
      senderId,
      notifyId,
      recipientKey,
      notifyKey,
      senderKey = Nothing,
      status = QueueActive
    }
