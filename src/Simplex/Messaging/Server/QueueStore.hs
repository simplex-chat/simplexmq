{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: RecipientId,
    recipientKey :: RcvPublicVerifyKey,
    rcvDhSecret :: RcvDhSecret,
    senderId :: SenderId,
    senderKey :: Maybe SndPublicVerifyKey,
    notifier :: Maybe (NotifierId, NtfPublicVerifyKey),
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff deriving (Eq, Show)

class MonadQueueStore s m where
  addQueue :: s -> QueueRec -> m (Either ErrorType ())
  getQueue :: IsClient p => s -> SParty p -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SndPublicVerifyKey -> m (Either ErrorType QueueRec)
  addQueueNotifier :: s -> RecipientId -> NotifierId -> NtfPublicVerifyKey -> m (Either ErrorType QueueRec)
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())
