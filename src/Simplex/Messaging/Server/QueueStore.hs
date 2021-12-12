{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: RecipientId,
    senderId :: SenderId,
    recipientKey :: RcvPublicVerifyKey,
    rcvSrvSignKey :: RcvPrivateSignKey,
    rcvDhSecret :: RcvDHSecret,
    senderKey :: Maybe SndPublicVerifyKey,
    sndSrvSignKey :: SndPrivateSignKey,
    notifier :: Maybe (NotifierId, NtfPublicVerifyKey),
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff deriving (Eq)

class MonadQueueStore s m where
  addQueue :: s -> RcvPublicVerifyKey -> (RecipientId, SenderId) -> m (Either ErrorType ())
  addQueue' :: s -> QueueRec -> m (Either ErrorType ())
  getQueue :: s -> SParty (a :: Party) -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SndPublicVerifyKey -> m (Either ErrorType ())
  addQueueNotifier :: s -> RecipientId -> NotifierId -> NtfPublicVerifyKey -> m (Either ErrorType ())
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())

mkQueueRec :: RcvPublicVerifyKey -> (RecipientId, SenderId) -> QueueRec
mkQueueRec recipientKey (recipientId, senderId) =
  QueueRec
    { recipientId,
      senderId,
      recipientKey,
      senderKey = Nothing,
      notifier = Nothing,
      status = QueueActive
    }
