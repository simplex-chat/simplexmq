{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Protocol where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol

data RawNtfTransmission = RawNtfTransmission
  { signature :: ByteString,
    signed :: ByteString,
    sessId :: ByteString,
    corrId :: ByteString,
    subscriptionId :: ByteString,
    message :: ByteString
  }

data NtfServerCommand
  = NtfCreate DeviceToken SMPQueueNtfUri C.APublicVerifyKey C.PublicKeyX25519
  | NtfCheck
  | NtfToken DeviceToken
  | NtfDelete

instance Encoding NtfServerCommand where
  smpEncode = \case
    NtfCreate token smpQueue verifyKey dhKey -> "CREATE " <> smpEncode (token, smpQueue, verifyKey, dhKey)
    NtfCheck -> "CHECK"
    NtfToken token -> "TOKEN " <> smpEncode token
    NtfDelete -> "DELETE"
  smpP =
    A.takeTill (== ' ') >>= \case
      "CREATE" -> do
        (token, smpQueue, verifyKey, dhKey) <- A.space *> smpP
        pure $ NtfCreate token smpQueue verifyKey dhKey
      "CHECK" -> pure NtfCheck
      "TOKEN" -> NtfToken <$> (A.space *> smpP)
      "DELETE" -> pure NtfDelete
      _ -> fail "bad NtfServerCommand"

data NtfServerResponse
  = NtfSubId NtfSubsciptionId
  | NtfOk
  | NtfErr NtfError
  | NtfStat NtfStatus

instance Encoding NtfServerResponse where
  smpEncode = \case
    NtfSubId subId -> "ID " <> smpEncode subId
    NtfOk -> "OK"
    NtfErr err -> "ERR " <> smpEncode err
    NtfStat stat -> "STAT " <> smpEncode stat
  smpP =
    A.takeTill (== ' ') >>= \case
      "ID" -> NtfSubId <$> (A.space *> smpP)
      "OK" -> pure NtfOk
      "ERR" -> NtfErr <$> (A.space *> smpP)
      "STAT" -> NtfStat <$> (A.space *> smpP)
      _ -> fail "bad NtfServerResponse"

data SMPQueueNtfUri = SMPQueueNtfUri
  { smpServer :: SMPServer,
    notifierId :: NotifierId,
    notifierKey :: NtfPrivateSignKey
  }

instance Encoding SMPQueueNtfUri where
  smpEncode SMPQueueNtfUri {smpServer, notifierId, notifierKey} = smpEncode (smpServer, notifierId, notifierKey)
  smpP = do
    (smpServer, notifierId, notifierKey) <- smpP
    pure $ SMPQueueNtfUri smpServer notifierId notifierKey

newtype DeviceToken = DeviceToken ByteString

instance Encoding DeviceToken where
  smpEncode (DeviceToken t) = smpEncode t
  smpP = DeviceToken <$> smpP

newtype NtfSubsciptionId = NtfSubsciptionId ByteString
  deriving (Eq, Ord)

instance Encoding NtfSubsciptionId where
  smpEncode (NtfSubsciptionId t) = smpEncode t
  smpP = NtfSubsciptionId <$> smpP

data NtfError = NtfErrSyntax | NtfErrAuth

instance Encoding NtfError where
  smpEncode = \case
    NtfErrSyntax -> "SYNTAX"
    NtfErrAuth -> "AUTH"
  smpP =
    A.takeTill (== ' ') >>= \case
      "SYNTAX" -> pure NtfErrSyntax
      "AUTH" -> pure NtfErrAuth
      _ -> fail "bad NtfError"

data NtfStatus = NSPending | NSActive | NSEnd | NSSMPAuth

instance Encoding NtfStatus where
  smpEncode = \case
    NSPending -> "PENDING"
    NSActive -> "ACTIVE"
    NSEnd -> "END"
    NSSMPAuth -> "SMP_AUTH"
  smpP =
    A.takeTill (== ' ') >>= \case
      "PENDING" -> pure NSPending
      "ACTIVE" -> pure NSActive
      "END" -> pure NSEnd
      "SMP_AUTH" -> pure NSSMPAuth
      _ -> fail "bad NtfError"
