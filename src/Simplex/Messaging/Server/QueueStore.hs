{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
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
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport (SMPServiceRole)
#if defined(dbServerPostgres)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Store.Postgres.DB (fromTextField_)
import Simplex.Messaging.Util (eitherToMaybe)
#endif

data ServiceRec = ServiceRec
  { serviceId :: ServiceId,
    serviceRole :: SMPServiceRole,
    serviceCert :: X.CertificateChain,
    serviceCertHash :: XV.Fingerprint -- SHA512 hash of long-term service client certificate. See comment for ClientHandshake.
  }

data QueueRec = QueueRec
  { recipientKeys :: NonEmpty RcvPublicAuthKey,
    rcvDhSecret :: RcvDhSecret,
    senderId :: SenderId,
    senderKey :: Maybe SndPublicAuthKey,
    queueMode :: Maybe QueueMode,
    queueData :: Maybe (LinkId, QueueLinkData),
    notifier :: Maybe NtfCreds,
    status :: ServerEntityStatus,
    updatedAt :: Maybe RoundedSystemTime,
    rcvServiceId :: Maybe ServiceId,
    ntfServiceId :: Maybe ServiceId
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

#if defined(dbServerPostgres)
instance FromField ServerEntityStatus where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField ServerEntityStatus where toField = toField . decodeLatin1 . strEncode
#endif

newtype RoundedSystemTime = RoundedSystemTime Int64
  deriving (Eq, Ord, Show)
#if defined(dbServerPostgres)
  deriving newtype (FromField, ToField)
#endif

instance StrEncoding RoundedSystemTime where
  strEncode (RoundedSystemTime t) = strEncode t
  strP = RoundedSystemTime <$> strP

getRoundedSystemTime :: Int64 -> IO RoundedSystemTime
getRoundedSystemTime prec = (\t -> RoundedSystemTime $ (systemSeconds t `div` prec) * prec) <$> getSystemTime

getSystemDate :: IO RoundedSystemTime
getSystemDate = getRoundedSystemTime 86400
