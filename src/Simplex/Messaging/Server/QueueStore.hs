{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: RecipientId,
    senderId :: SenderId,
    recipientKey :: RcvPublicVerifyKey,
    rcvSrvSignKey :: RcvPrivateSignKey,
    rcvDhSecret :: RcvDhSecret,
    senderKey :: Maybe SndPublicVerifyKey,
    sndSrvSignKey :: SndPrivateSignKey,
    notifier :: Maybe (NotifierId, NtfPublicVerifyKey),
    status :: QueueStatus
  }

data QueueStatus = QueueActive | QueueOff deriving (Eq)

class MonadQueueStore s m where
  addQueue :: s -> QueueRec -> m (Either ErrorType ())
  getQueue :: s -> ClientParty -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SndPublicVerifyKey -> m (Either ErrorType ())
  addQueueNotifier :: s -> RecipientId -> NotifierId -> NtfPublicVerifyKey -> m (Either ErrorType ())
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())
