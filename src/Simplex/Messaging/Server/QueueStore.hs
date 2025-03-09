{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.QueueStore where

import Control.Applicative ((<|>))
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol

data QueueRec = QueueRec
  { recipientKey :: !RcvPublicAuthKey,
    rcvDhSecret :: !RcvDhSecret,
    senderId :: !SenderId,
    senderKey :: !(Maybe SndPublicAuthKey),
    sndSecure :: !SenderCanSecure,
    notifier :: !(Maybe NtfCreds),
    status :: !ServerEntityStatus,
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

data ServerEntityStatus
  = EntityActive
  | EntityBlocked BlockingInfo
  | EntityOff
  deriving (Eq, Show)

instance StrEncoding ServerEntityStatus where
  strEncode = \case
    EntityActive -> "active"
    EntityBlocked info -> "blocked," <> strEncode info
    EntityOff -> "off"
  strP =
    "active" $> EntityActive
      <|> "blocked," *> (EntityBlocked <$> strP)
      <|> "off" $> EntityOff

newtype RoundedSystemTime = RoundedSystemTime Int64
  deriving (Eq, Ord, Show)

instance StrEncoding RoundedSystemTime where
  strEncode (RoundedSystemTime t) = strEncode t
  strP = RoundedSystemTime <$> strP

getRoundedSystemTime :: Int64 -> IO RoundedSystemTime
getRoundedSystemTime prec = (\t -> RoundedSystemTime $ (systemSeconds t `div` prec) * prec) <$> getSystemTime

getSystemDate :: IO RoundedSystemTime
getSystemDate = getRoundedSystemTime 86400
