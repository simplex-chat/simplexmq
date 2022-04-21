{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Notifications.Protocol where

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Maybe (isNothing)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Type.Equality
import Data.Word (Word16)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Transport (ntfClientHandshake)
import Simplex.Messaging.Parsers (fromTextField_)
import Simplex.Messaging.Protocol hiding (Command (..), CommandTag (..))
import Simplex.Messaging.Util ((<$?>))

data NtfEntity = Token | Subscription
  deriving (Show)

data SNtfEntity :: NtfEntity -> Type where
  SToken :: SNtfEntity 'Token
  SSubscription :: SNtfEntity 'Subscription

instance TestEquality SNtfEntity where
  testEquality SToken SToken = Just Refl
  testEquality SSubscription SSubscription = Just Refl
  testEquality _ _ = Nothing

deriving instance Show (SNtfEntity e)

class NtfEntityI (e :: NtfEntity) where sNtfEntity :: SNtfEntity e

instance NtfEntityI 'Token where sNtfEntity = SToken

instance NtfEntityI 'Subscription where sNtfEntity = SSubscription

data NtfCommandTag (e :: NtfEntity) where
  TNEW_ :: NtfCommandTag 'Token
  TVFY_ :: NtfCommandTag 'Token
  TCHK_ :: NtfCommandTag 'Token
  TDEL_ :: NtfCommandTag 'Token
  TCRN_ :: NtfCommandTag 'Token
  SNEW_ :: NtfCommandTag 'Subscription
  SCHK_ :: NtfCommandTag 'Subscription
  SDEL_ :: NtfCommandTag 'Subscription
  PING_ :: NtfCommandTag 'Subscription

deriving instance Show (NtfCommandTag e)

data NtfCmdTag = forall e. NtfEntityI e => NCT (SNtfEntity e) (NtfCommandTag e)

instance NtfEntityI e => Encoding (NtfCommandTag e) where
  smpEncode = \case
    TNEW_ -> "TNEW"
    TVFY_ -> "TVFY"
    TCHK_ -> "TCHK"
    TDEL_ -> "TDEL"
    TCRN_ -> "TCRN"
    SNEW_ -> "SNEW"
    SCHK_ -> "SCHK"
    SDEL_ -> "SDEL"
    PING_ -> "PING"
  smpP = messageTagP

instance Encoding NtfCmdTag where
  smpEncode (NCT _ t) = smpEncode t
  smpP = messageTagP

instance ProtocolMsgTag NtfCmdTag where
  decodeTag = \case
    "TNEW" -> Just $ NCT SToken TNEW_
    "TVFY" -> Just $ NCT SToken TVFY_
    "TCHK" -> Just $ NCT SToken TCHK_
    "TDEL" -> Just $ NCT SToken TDEL_
    "TCRN" -> Just $ NCT SToken TCRN_
    "SNEW" -> Just $ NCT SSubscription SNEW_
    "SCHK" -> Just $ NCT SSubscription SCHK_
    "SDEL" -> Just $ NCT SSubscription SDEL_
    "PING" -> Just $ NCT SSubscription PING_
    _ -> Nothing

instance NtfEntityI e => ProtocolMsgTag (NtfCommandTag e) where
  decodeTag s = decodeTag s >>= (\(NCT _ t) -> checkEntity' t)

newtype NtfRegCode = NtfRegCode ByteString
  deriving (Eq, Show)

instance Encoding NtfRegCode where
  smpEncode (NtfRegCode code) = smpEncode code
  smpP = NtfRegCode <$> smpP

instance StrEncoding NtfRegCode where
  strEncode (NtfRegCode m) = strEncode m
  strDecode s = NtfRegCode <$> strDecode s
  strP = NtfRegCode <$> strP

instance FromJSON NtfRegCode where
  parseJSON = strParseJSON "NtfRegCode"

instance ToJSON NtfRegCode where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data NewNtfEntity (e :: NtfEntity) where
  NewNtfTkn :: DeviceToken -> C.APublicVerifyKey -> C.PublicKeyX25519 -> NewNtfEntity 'Token
  NewNtfSub :: NtfTokenId -> SMPQueueNtf -> NewNtfEntity 'Subscription

deriving instance Show (NewNtfEntity e)

data ANewNtfEntity = forall e. NtfEntityI e => ANE (SNtfEntity e) (NewNtfEntity e)

instance NtfEntityI e => Encoding (NewNtfEntity e) where
  smpEncode = \case
    NewNtfTkn tkn verifyKey dhPubKey -> smpEncode ('T', tkn, verifyKey, dhPubKey)
    NewNtfSub tknId smpQueue -> smpEncode ('S', tknId, smpQueue)
  smpP = (\(ANE _ c) -> checkEntity c) <$?> smpP

instance Encoding ANewNtfEntity where
  smpEncode (ANE _ e) = smpEncode e
  smpP =
    A.anyChar >>= \case
      'T' -> ANE SToken <$> (NewNtfTkn <$> smpP <*> smpP <*> smpP)
      'S' -> ANE SSubscription <$> (NewNtfSub <$> smpP <*> smpP)
      _ -> fail "bad ANewNtfEntity"

instance Protocol NtfResponse where
  type ProtocolCommand NtfResponse = NtfCmd
  protocolClientHandshake = ntfClientHandshake
  protocolPing = NtfCmd SSubscription PING
  protocolError = \case
    NRErr e -> Just e
    _ -> Nothing

data NtfCommand (e :: NtfEntity) where
  -- | register new device token for notifications
  TNEW :: NewNtfEntity 'Token -> NtfCommand 'Token
  -- | verify token - uses e2e encrypted random string sent to the device via PN to confirm that the device has the token
  TVFY :: NtfRegCode -> NtfCommand 'Token
  -- | check token status
  TCHK :: NtfCommand 'Token
  -- | delete token - all subscriptions will be removed and no more notifications will be sent
  TDEL :: NtfCommand 'Token
  -- | enable periodic background notification to fetch the new messages - interval is in minutes, minimum is 20, 0 to disable
  TCRN :: Word16 -> NtfCommand 'Token
  -- | create SMP subscription
  SNEW :: NewNtfEntity 'Subscription -> NtfCommand 'Subscription
  -- | check SMP subscription status (response is STAT)
  SCHK :: NtfCommand 'Subscription
  -- | delete SMP subscription
  SDEL :: NtfCommand 'Subscription
  -- | keep-alive command
  PING :: NtfCommand 'Subscription

deriving instance Show (NtfCommand e)

data NtfCmd = forall e. NtfEntityI e => NtfCmd (SNtfEntity e) (NtfCommand e)

deriving instance Show NtfCmd

instance NtfEntityI e => ProtocolEncoding (NtfCommand e) where
  type Tag (NtfCommand e) = NtfCommandTag e
  encodeProtocol = \case
    TNEW newTkn -> e (TNEW_, ' ', newTkn)
    TVFY code -> e (TVFY_, ' ', code)
    TCHK -> e TCHK_
    TDEL -> e TDEL_
    TCRN int -> e (TCRN_, ' ', int)
    SNEW newSub -> e (SNEW_, ' ', newSub)
    SCHK -> e SCHK_
    SDEL -> e SDEL_
    PING -> e PING_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP tag = (\(NtfCmd _ c) -> checkEntity c) <$?> protocolP (NCT (sNtfEntity @e) tag)

  checkCredentials (sig, _, entityId, _) cmd = case cmd of
    -- TNEW and SNEW must have signature but NOT token/subscription IDs
    TNEW {} -> sigNoEntity
    SNEW {} -> sigNoEntity
    PING
      | isNothing sig && B.null entityId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and entity ID
    _
      | isNothing sig || B.null entityId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd
    where
      sigNoEntity
        | isNothing sig = Left $ CMD NO_AUTH
        | not (B.null entityId) = Left $ CMD HAS_AUTH
        | otherwise = Right cmd

instance ProtocolEncoding NtfCmd where
  type Tag NtfCmd = NtfCmdTag
  encodeProtocol (NtfCmd _ c) = encodeProtocol c

  protocolP = \case
    NCT SToken tag ->
      NtfCmd SToken <$> case tag of
        TNEW_ -> TNEW <$> _smpP
        TVFY_ -> TVFY <$> _smpP
        TCHK_ -> pure TCHK
        TDEL_ -> pure TDEL
        TCRN_ -> TCRN <$> _smpP
    NCT SSubscription tag ->
      NtfCmd SSubscription <$> case tag of
        SNEW_ -> SNEW <$> _smpP
        SCHK_ -> pure SCHK
        SDEL_ -> pure SDEL
        PING_ -> pure PING

  checkCredentials t (NtfCmd e c) = NtfCmd e <$> checkCredentials t c

data NtfResponseTag
  = NRId_
  | NROk_
  | NRErr_
  | NRTkn_
  | NRSub_
  | NRPong_
  deriving (Show)

instance Encoding NtfResponseTag where
  smpEncode = \case
    NRId_ -> "ID"
    NROk_ -> "OK"
    NRErr_ -> "ERR"
    NRTkn_ -> "TKN"
    NRSub_ -> "SUB"
    NRPong_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag NtfResponseTag where
  decodeTag = \case
    "ID" -> Just NRId_
    "OK" -> Just NROk_
    "ERR" -> Just NRErr_
    "TKN" -> Just NRTkn_
    "SUB" -> Just NRSub_
    "PONG" -> Just NRPong_
    _ -> Nothing

data NtfResponse
  = NRId NtfEntityId C.PublicKeyX25519
  | NROk
  | NRErr ErrorType
  | NRTkn NtfTknStatus
  | NRSub NtfSubStatus
  | NRPong
  deriving (Show)

instance ProtocolEncoding NtfResponse where
  type Tag NtfResponse = NtfResponseTag
  encodeProtocol = \case
    NRId entId dhKey -> e (NRId_, ' ', entId, dhKey)
    NROk -> e NROk_
    NRErr err -> e (NRErr_, ' ', err)
    NRTkn stat -> e (NRTkn_, ' ', stat)
    NRSub stat -> e (NRSub_, ' ', stat)
    NRPong -> e NRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP = \case
    NRId_ -> NRId <$> _smpP <*> smpP
    NROk_ -> pure NROk
    NRErr_ -> NRErr <$> _smpP
    NRTkn_ -> NRTkn <$> _smpP
    NRSub_ -> NRSub <$> _smpP
    NRPong_ -> pure NRPong

  checkCredentials (_, _, entId, _) cmd = case cmd of
    -- ID response must not have queue ID
    NRId {} -> noEntity
    -- ERR response does not always have entity ID
    NRErr _ -> Right cmd
    -- PONG response must not have queue ID
    NRPong -> noEntity
    -- other server responses must have entity ID
    _
      | B.null entId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd
    where
      noEntity
        | B.null entId = Right cmd
        | otherwise = Left $ CMD HAS_AUTH

data SMPQueueNtf = SMPQueueNtf
  { smpServer :: ProtocolServer,
    notifierId :: NotifierId,
    notifierKey :: NtfPrivateSignKey
  }
  deriving (Show)

instance Encoding SMPQueueNtf where
  smpEncode SMPQueueNtf {smpServer, notifierId, notifierKey} = smpEncode (smpServer, notifierId, notifierKey)
  smpP = do
    (smpServer, notifierId, notifierKey) <- smpP
    pure $ SMPQueueNtf smpServer notifierId notifierKey

data PushProvider = PPApns
  deriving (Eq, Ord, Show)

instance Encoding PushProvider where
  smpEncode = \case
    PPApns -> "A"
  smpP =
    A.anyChar >>= \case
      'A' -> pure PPApns
      _ -> fail "bad PushProvider"

instance TextEncoding PushProvider where
  textEncode = \case
    PPApns -> "apple"
  textDecode = \case
    "apple" -> Just PPApns
    _ -> Nothing

instance FromField PushProvider where fromField = fromTextField_ textDecode

instance ToField PushProvider where toField = toField . textEncode

data DeviceToken = DeviceToken PushProvider ByteString
  deriving (Eq, Ord, Show)

instance Encoding DeviceToken where
  smpEncode (DeviceToken p t) = smpEncode (p, t)
  smpP = DeviceToken <$> smpP <*> smpP

type NtfEntityId = ByteString

type NtfSubscriptionId = NtfEntityId

type NtfTokenId = NtfEntityId

data NtfSubStatus
  = -- | state after SNEW
    NSNew
  | -- | pending connection/subscription to SMP server
    NSPending
  | -- | connected and subscribed to SMP server
    NSActive
  | -- | NEND received (we currently do not support it)
    NSEnd
  | -- | SMP AUTH error
    NSSMPAuth
  deriving (Eq, Show)

instance Encoding NtfSubStatus where
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
      _ -> fail "bad NtfSubStatus"

data NtfTknStatus
  = -- | Token created in DB
    NTNew
  | -- | state after registration (TNEW)
    NTRegistered
  | -- | if initial notification failed (push provider error) or verification failed
    NTInvalid
  | -- | Token confirmed via notification (accepted by push provider or verification code received by client)
    NTConfirmed
  | -- | after successful verification (TVFY)
    NTActive
  | -- | after it is no longer valid (push provider error)
    NTExpired
  deriving (Eq, Show)

instance Encoding NtfTknStatus where
  smpEncode = \case
    NTNew -> "NEW"
    NTRegistered -> "REGISTERED"
    NTInvalid -> "INVALID"
    NTConfirmed -> "CONFIRMED"
    NTActive -> "ACTIVE"
    NTExpired -> "EXPIRED"
  smpP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> pure NTNew
      "REGISTERED" -> pure NTRegistered
      "INVALID" -> pure NTInvalid
      "CONFIRMED" -> pure NTConfirmed
      "ACTIVE" -> pure NTActive
      "EXPIRED" -> pure NTExpired
      _ -> fail "bad NtfTknStatus"

instance FromField NtfTknStatus where fromField = fromTextField_ $ either (const Nothing) Just . smpDecode . encodeUtf8

instance ToField NtfTknStatus where toField = toField . decodeLatin1 . smpEncode

checkEntity :: forall t e e'. (NtfEntityI e, NtfEntityI e') => t e' -> Either String (t e)
checkEntity c = case testEquality (sNtfEntity @e) (sNtfEntity @e') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkEntity' :: forall t p p'. (NtfEntityI p, NtfEntityI p') => t p' -> Maybe (t p)
checkEntity' c = case testEquality (sNtfEntity @p) (sNtfEntity @p') of
  Just Refl -> Just c
  _ -> Nothing
