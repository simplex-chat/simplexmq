{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Server.QueueStore where

import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientId :: !RecipientId,
    recipientKey :: !RcvPublicAuthKey,
    rcvDhSecret :: !RcvDhSecret,
    senderId :: !SenderId,
    senderKey :: !(Maybe SndPublicAuthKey),
    sndSecure :: !SenderCanSecure,
    notifier :: !(Maybe NtfCreds),
    status :: !ServerQueueStatus,
    updatedAt :: !(Maybe RoundedSystemTime)
  }
  deriving (Show)

data NtfCreds = NtfCreds
  { notifierId :: !NotifierId,
    notifierKey :: !NtfPublicAuthKey,
    rcvNtfDhSecret :: !RcvNtfDhSecret
  }
  deriving (Show)

instance StrEncoding NtfCreds where
  strEncode NtfCreds {notifierId, notifierKey, rcvNtfDhSecret} = strEncode (notifierId, notifierKey, rcvNtfDhSecret)
  strP = do
    (notifierId, notifierKey, rcvNtfDhSecret) <- strP
    pure NtfCreds {notifierId, notifierKey, rcvNtfDhSecret}

data ServerQueueStatus = QueueActive | QueueOff deriving (Eq, Show)

data RoundedSystemTime = RoundedSystemTime {precision :: Int64, seconds :: Int64}
  deriving (Eq, Ord, Show)

instance StrEncoding RoundedSystemTime where
  strEncode RoundedSystemTime {precision, seconds} = strEncode (precision, seconds)
  strP = do
    (precision, seconds) <- strP
    pure RoundedSystemTime {precision, seconds}

getRoundedSystemTime :: Int64 -> IO RoundedSystemTime
getRoundedSystemTime precision =
  (\t -> RoundedSystemTime precision $ (systemSeconds t `div` precision) * precision) <$> getSystemTime

getSystemDate :: IO RoundedSystemTime
getSystemDate = getRoundedSystemTime 86400
