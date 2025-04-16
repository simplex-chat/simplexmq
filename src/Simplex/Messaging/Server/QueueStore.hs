{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Server.QueueStore where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport.Client (TransportHost)
#if defined(dbServerPostgres)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.Store.Postgres.DB (fromTextField_)
import Simplex.Messaging.Util (eitherToMaybe)
#endif

data QueueRec = QueueRec
  { recipientKeys :: NonEmpty RcvPublicAuthKey,
    rcvDhSecret :: RcvDhSecret,
    senderId :: SenderId,
    senderKey :: Maybe SndPublicAuthKey,
    queueMode :: Maybe QueueMode,
    queueData :: Maybe (LinkId, QueueLinkData),
    notifier :: Maybe NtfCreds,
    status :: ServerEntityStatus,
    updatedAt :: Maybe RoundedSystemTime
  }
  deriving (Show)

data NtfCreds = NtfCreds
  { notifierId :: NotifierId,
    -- `notifierKey` and `ntfServer` are mutually exclusive (and one of them is required),
    -- but for some period of time from switching to `ntfServer`
    -- we will continue storing `notifierKey` to allow ntf/smp server downgrades.
    -- we could use `These NtfPublicAuthKey TransportHost` type here (https://hackage.haskell.org/package/these-1.2.1/docs/Data-These.html)
    notifierKey :: Maybe NtfPublicAuthKey,
    ntfServerHost :: Maybe TransportHost,
    rcvNtfDhSecret :: RcvNtfDhSecret
  }
  deriving (Show)

instance StrEncoding NtfCreds where
  strEncode NtfCreds {notifierId = nId, notifierKey = nKey, ntfServerHost = nsrv, rcvNtfDhSecret} =
    strEncode nId <> opt " nkey=" nKey <> opt " nsrv=" nsrv <> " ndhs=" <> strEncode rcvNtfDhSecret
    where
      opt :: StrEncoding a => ByteString -> Maybe a -> ByteString
      opt param = maybe B.empty ((param <>) . strEncode)
  strP = do
    notifierId <- strP
    (notifierKey, ntfServerHost, rcvNtfDhSecret) <- newP <|> legacyP
    pure NtfCreds {notifierId, notifierKey, ntfServerHost, rcvNtfDhSecret}
    where
      newP = (,,) <$> optional (" nkey=" *> strP) <*> optional (" nsrv=" *> strP) <*> (" ndhs=" *> strP)
      legacyP = do
        (nKey, rcvNtfDhSecret) <- A.space *> strP
        pure (Just nKey, Nothing, rcvNtfDhSecret)

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
