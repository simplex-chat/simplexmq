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
    notifier :: Maybe NtfCreds,
    status :: QueueStatus
  }
  deriving (Eq, Show)

data NtfCreds = NtfCreds
  { notifierId :: NotifierId,
    notifierKey :: NtfPublicVerifyKey,
    rcvNtfDhSecret :: RcvNtfDhSecret
  }
  deriving (Eq, Show)

data QueueStatus = QueueActive | QueueOff deriving (Eq, Show)

class MonadQueueStore s m where
  addQueue :: s -> QueueRec -> m (Either ErrorType ())
  getQueue :: s -> SParty p -> QueueId -> m (Either ErrorType QueueRec)
  secureQueue :: s -> RecipientId -> SndPublicVerifyKey -> m (Either ErrorType QueueRec)
  addQueueNotifier :: s -> RecipientId -> NtfCreds -> m (Either ErrorType QueueRec)
  suspendQueue :: s -> RecipientId -> m (Either ErrorType ())
  deleteQueue :: s -> RecipientId -> m (Either ErrorType ())
