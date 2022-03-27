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

data NewNtfSubscription = NewNtfSubscription
  { smpQueue :: SMPQueueNtf,
    token :: DeviceToken,
    verifyKey :: C.APublicVerifyKey,
    dhPubKey :: C.PublicKeyX25519
  }

instance Encoding NewNtfSubscription where
  smpEncode NewNtfSubscription {smpQueue, token, verifyKey, dhPubKey} = smpEncode (smpQueue, token, verifyKey, dhPubKey)
  smpP = NewNtfSubscription <$> smpP <*> smpP <*> smpP <*> smpP

data NtfCommand
  = NCCreate NewNtfSubscription
  | NCCheck
  | NCToken DeviceToken
  | NCDelete

instance Protocol NtfCommand where
  type Tag NtfCommand = NtfCommandTag
  encodeProtocol = \case
    NCCreate sub -> e (NCCreate_, ' ', sub)
    NCCheck -> e NCCheck_
    NCToken token -> e (NCToken_, ' ', token)
    NCDelete -> e NCDelete_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP = \case
    NCCreate_ -> NCCreate <$> _smpP
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

data SMPQueueNtf = SMPQueueNtf
  { smpServer :: SMPServer,
    notifierId :: NotifierId,
    notifierKey :: NtfPrivateSignKey
  }

instance Encoding SMPQueueNtf where
  smpEncode SMPQueueNtf {smpServer, notifierId, notifierKey} = smpEncode (smpServer, notifierId, notifierKey)
  smpP = do
    (smpServer, notifierId, notifierKey) <- smpP
    pure $ SMPQueueNtf smpServer notifierId notifierKey

data PushPlatform = PPApple

instance Encoding PushPlatform where
  smpEncode = \case
    PPApple -> "A"
  smpP =
    A.anyChar >>= \case
      'A' -> pure PPApple
      _ -> fail "bad PushPlatform"

data DeviceToken = DeviceToken PushPlatform ByteString

instance Encoding DeviceToken where
  smpEncode (DeviceToken p t) = smpEncode (p, t)
  smpP = DeviceToken <$> smpP <*> smpP

type NtfSubsciptionId = ByteString

data NtfStatus = NSNew | NSPending | NSActive | NSEnd | NSSMPAuth
  deriving (Eq)

instance Encoding NtfStatus where
  smpEncode = \case
    NSNew -> "NEW"
    NSPending -> "PENDING" -- e.g. after SMP server disconnect/timeout while ntf server is retrying to connect
    NSActive -> "ACTIVE"
    NSEnd -> "END"
    NSSMPAuth -> "SMP_AUTH"
  smpP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> pure NSNew
      "PENDING" -> pure NSPending
      "ACTIVE" -> pure NSActive
      "END" -> pure NSEnd
      "SMP_AUTH" -> pure NSSMPAuth
      _ -> fail "bad NtfError"
