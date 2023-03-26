{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: !RecipientId,
    recipientKey :: !RcvPublicVerifyKey,
    rcvDhSecret :: !RcvDhSecret,
    senderId :: !SenderId,
    senderKey :: !(Maybe SndPublicVerifyKey),
    notifier :: !(Maybe NtfCreds),
    status :: !ServerQueueStatus
  }
  deriving (Eq, Show)

data NtfCreds = NtfCreds
  { notifierId :: !NotifierId,
    notifierKey :: !NtfPublicVerifyKey,
    rcvNtfDhSecret :: !RcvNtfDhSecret
  }
  deriving (Eq, Show)

instance StrEncoding NtfCreds where
  strEncode NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} = strEncode (notifierId, notifierKey, rcvNtfDhSecret)
  strP = do
    (notifierId, notifierKey, rcvNtfDhSecret) <- strP
    pure NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}

data ServerQueueStatus = QueueActive | QueueOff deriving (Eq, Show)
