{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Notifications.Protocol where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (isNothing)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol

data NtfCommandTag
  = NCCreate_
  | NCCheck_
  | NCToken_
  | NCDelete_
  deriving (Show)

instance Encoding NtfCommandTag where
  smpEncode = \case
    NCCreate_ -> "CREATE"
    NCCheck_ -> "CHECK"
    NCToken_ -> "TOKEN"
    NCDelete_ -> "DELETE"
  smpP = messageTagP

instance ProtocolMsgTag NtfCommandTag where
  decodeTag = \case
    "CREATE" -> Just NCCreate_
    "CHECK" -> Just NCCheck_
    "TOKEN" -> Just NCToken_
    "DELETE" -> Just NCDelete_
    _ -> Nothing

data NtfCommand
  = NCCreate DeviceToken SMPQueueNtfUri C.APublicVerifyKey C.PublicKeyX25519
  | NCCheck
  | NCToken DeviceToken
  | NCDelete

instance Protocol NtfCommand where
  type Tag NtfCommand = NtfCommandTag
  encodeProtocol = \case
    NCCreate token smpQueue verifyKey dhKey -> e (NCCreate_, ' ', token, smpQueue, verifyKey, dhKey)
    NCCheck -> e NCCheck_
    NCToken token -> e (NCToken_, ' ', token)
    NCDelete -> e NCDelete_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP = \case
    NCCreate_ -> NCCreate <$> _smpP <*> smpP <*> smpP <*> smpP
    NCCheck_ -> pure NCCheck
    NCToken_ -> NCToken <$> _smpP
    NCDelete_ -> pure NCDelete

  checkCredentials (sig, _, subId, _) cmd = case cmd of
    -- CREATE must have signature but NOT subscription ID
    NCCreate {}
      | isNothing sig -> Left $ CMD NO_AUTH
      | not (B.null subId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    -- other client commands must have both signature and subscription ID
    _
      | isNothing sig || B.null subId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

data NtfResponseTag
  = NRSubId_
  | NROk_
  | NRErr_
  | NRStat_
  deriving (Show)

instance Encoding NtfResponseTag where
  smpEncode = \case
    NRSubId_ -> "ID"
    NROk_ -> "OK"
    NRErr_ -> "ERR"
    NRStat_ -> "STAT"
  smpP = messageTagP

instance ProtocolMsgTag NtfResponseTag where
  decodeTag = \case
    "ID" -> Just NRSubId_
    "OK" -> Just NROk_
    "ERR" -> Just NRErr_
    "STAT" -> Just NRStat_
    _ -> Nothing

data NtfResponse
  = NRSubId C.PublicKeyX25519
  | NROk
  | NRErr ErrorType
  | NRStat NtfStatus

instance Protocol NtfResponse where
  type Tag NtfResponse = NtfResponseTag
  encodeProtocol = \case
    NRSubId dhKey -> e (NRSubId_, ' ', dhKey)
    NROk -> e NROk_
    NRErr err -> e (NRErr_, ' ', err)
    NRStat stat -> e (NRStat_, ' ', stat)
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP = \case
    NRSubId_ -> NRSubId <$> _smpP
    NROk_ -> pure NROk
    NRErr_ -> NRErr <$> _smpP
    NRStat_ -> NRStat <$> _smpP

  checkCredentials (_, _, subId, _) cmd = case cmd of
    -- ERR response does not always have subscription ID
    NRErr _ -> Right cmd
    -- other server responses must have subscription ID
    _
      | B.null subId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd

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

type NtfSubsciptionId = ByteString

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
