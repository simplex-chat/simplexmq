{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Notifications.Protocol where

import Control.Applicative (optional, (<|>))
import qualified Crypto.PubKey.ECC.Types as ECC
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Kind
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (isNothing)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock.System
import Data.Type.Equality
import Data.Word (Word16)
import Simplex.Messaging.Agent.Protocol (updateSMPServerHosts)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..), fromTextField_)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Transport (NTFVersion, invalidReasonNTFVersion, ntfClientHandshake)
import Simplex.Messaging.Protocol hiding (Command (..), CommandTag (..))
import Simplex.Messaging.Util (eitherToMaybe, (<$?>))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Binary as Bin
import qualified Crypto.Error as CE
import qualified Data.Bits as Bits
import Network.HTTP.Client (Request, parseUrlThrow)

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
  TRPL_ :: NtfCommandTag 'Token
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
    TRPL_ -> "TRPL"
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
    "TRPL" -> Just $ NCT SToken TRPL_
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
  NewNtfTkn :: DeviceToken -> NtfPublicAuthKey -> C.PublicKeyX25519 -> NewNtfEntity 'Token
  NewNtfSub :: NtfTokenId -> SMPQueueNtf -> NtfPrivateAuthKey -> NewNtfEntity 'Subscription

deriving instance Show (NewNtfEntity e)

data ANewNtfEntity = forall e. NtfEntityI e => ANE (SNtfEntity e) (NewNtfEntity e)

deriving instance Show ANewNtfEntity

instance NtfEntityI e => Encoding (NewNtfEntity e) where
  smpEncode = \case
    NewNtfTkn tkn verifyKey dhPubKey -> smpEncode ('T', tkn, verifyKey, dhPubKey)
    NewNtfSub tknId smpQueue notifierKey -> smpEncode ('S', tknId, smpQueue, notifierKey)
  smpP = (\(ANE _ c) -> checkEntity c) <$?> smpP

instance Encoding ANewNtfEntity where
  smpEncode (ANE _ e) = smpEncode e
  smpP =
    A.anyChar >>= \case
      'T' -> ANE SToken <$> (NewNtfTkn <$> smpP <*> smpP <*> smpP)
      'S' -> ANE SSubscription <$> (NewNtfSub <$> smpP <*> smpP <*> smpP)
      _ -> fail "bad ANewNtfEntity"

instance Protocol NTFVersion ErrorType NtfResponse where
  type ProtoCommand NtfResponse = NtfCmd
  type ProtoType NtfResponse = 'PNTF
  protocolClientHandshake c _ks = ntfClientHandshake c
  {-# INLINE protocolClientHandshake #-}
  useServiceAuth _ = False
  {-# INLINE useServiceAuth #-}
  protocolPing = NtfCmd SSubscription PING
  {-# INLINE protocolPing #-}
  protocolError = \case
    NRErr e -> Just e
    _ -> Nothing
  {-# INLINE protocolError #-}

data NtfCommand (e :: NtfEntity) where
  -- | register new device token for notifications
  TNEW :: NewNtfEntity 'Token -> NtfCommand 'Token
  -- | verify token - uses e2e encrypted random string sent to the device via PN to confirm that the device has the token
  TVFY :: NtfRegCode -> NtfCommand 'Token
  -- | check token status
  TCHK :: NtfCommand 'Token
  -- | replace device token (while keeping all existing subscriptions)
  TRPL :: DeviceToken -> NtfCommand 'Token
  -- | delete token - all subscriptions will be removed and no more notifications will be sent
  TDEL :: NtfCommand 'Token
  -- | enable periodic background notification to fetch the new messages - interval is in minutes, minimum is 20, 0 to disable
  TCRN :: Word16 -> NtfCommand 'Token
  -- | create SMP subscription
  SNEW :: NewNtfEntity 'Subscription -> NtfCommand 'Subscription
  -- | check SMP subscription status (response is SUB)
  SCHK :: NtfCommand 'Subscription
  -- | delete SMP subscription
  SDEL :: NtfCommand 'Subscription
  -- | keep-alive command
  PING :: NtfCommand 'Subscription

deriving instance Show (NtfCommand e)

data NtfCmd = forall e. NtfEntityI e => NtfCmd (SNtfEntity e) (NtfCommand e)

deriving instance Show NtfCmd

instance NtfEntityI e => ProtocolEncoding NTFVersion ErrorType (NtfCommand e) where
  type Tag (NtfCommand e) = NtfCommandTag e
  encodeProtocol _v = \case
    TNEW newTkn -> e (TNEW_, ' ', newTkn)
    TVFY code -> e (TVFY_, ' ', code)
    TCHK -> e TCHK_
    TRPL tkn -> e (TRPL_, ' ', tkn)
    TDEL -> e TDEL_
    TCRN int -> e (TCRN_, ' ', int)
    SNEW newSub -> e (SNEW_, ' ', newSub)
    SCHK -> e SCHK_
    SDEL -> e SDEL_
    PING -> e PING_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v tag = (\(NtfCmd _ c) -> checkEntity c) <$?> protocolP _v (NCT (sNtfEntity @e) tag)

  fromProtocolError = fromProtocolError @NTFVersion @ErrorType @NtfResponse
  {-# INLINE fromProtocolError #-}

  checkCredentials auth (EntityId entityId) cmd = case cmd of
    -- TNEW and SNEW must have signature but NOT token/subscription IDs
    TNEW {} -> sigNoEntity
    SNEW {} -> sigNoEntity
    PING
      | isNothing auth && B.null entityId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and entity ID
    _
      | isNothing auth || B.null entityId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd
    where
      sigNoEntity
        | isNothing auth = Left $ CMD NO_AUTH
        | not (B.null entityId) = Left $ CMD HAS_AUTH
        | otherwise = Right cmd

instance ProtocolEncoding NTFVersion ErrorType NtfCmd where
  type Tag NtfCmd = NtfCmdTag
  encodeProtocol _v (NtfCmd _ c) = encodeProtocol _v c

  protocolP _v = \case
    NCT SToken tag ->
      NtfCmd SToken <$> case tag of
        TNEW_ -> TNEW <$> _smpP
        TVFY_ -> TVFY <$> _smpP
        TCHK_ -> pure TCHK
        TRPL_ -> TRPL <$> _smpP
        TDEL_ -> pure TDEL
        TCRN_ -> TCRN <$> _smpP
    NCT SSubscription tag ->
      NtfCmd SSubscription <$> case tag of
        SNEW_ -> SNEW <$> _smpP
        SCHK_ -> pure SCHK
        SDEL_ -> pure SDEL
        PING_ -> pure PING

  fromProtocolError = fromProtocolError @NTFVersion @ErrorType @NtfResponse
  {-# INLINE fromProtocolError #-}

  checkCredentials tAuth entId (NtfCmd e c) = NtfCmd e <$> checkCredentials tAuth entId c

data NtfResponseTag
  = NRTknId_
  | NRSubId_
  | NROk_
  | NRErr_
  | NRTkn_
  | NRSub_
  | NRPong_
  deriving (Show)

instance Encoding NtfResponseTag where
  smpEncode = \case
    NRTknId_ -> "IDTKN" -- it should be "TID", "SID"
    NRSubId_ -> "IDSUB"
    NROk_ -> "OK"
    NRErr_ -> "ERR"
    NRTkn_ -> "TKN"
    NRSub_ -> "SUB"
    NRPong_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag NtfResponseTag where
  decodeTag = \case
    "IDTKN" -> Just NRTknId_
    "IDSUB" -> Just NRSubId_
    "OK" -> Just NROk_
    "ERR" -> Just NRErr_
    "TKN" -> Just NRTkn_
    "SUB" -> Just NRSub_
    "PONG" -> Just NRPong_
    _ -> Nothing

data NtfResponse
  = NRTknId NtfEntityId C.PublicKeyX25519
  | NRSubId NtfEntityId
  | NROk
  | NRErr ErrorType
  | NRTkn NtfTknStatus
  | NRSub NtfSubStatus
  | NRPong
  deriving (Show)

instance ProtocolEncoding NTFVersion ErrorType NtfResponse where
  type Tag NtfResponse = NtfResponseTag
  encodeProtocol v = \case
    NRTknId entId dhKey -> e (NRTknId_, ' ', entId, dhKey)
    NRSubId entId -> e (NRSubId_, ' ', entId)
    NROk -> e NROk_
    NRErr err -> e (NRErr_, ' ', err)
    NRTkn stat -> e (NRTkn_, ' ', stat')
      where
        stat'
          | v >= invalidReasonNTFVersion = stat
          | otherwise = case stat of
              NTInvalid _ -> NTInvalid Nothing
              _ -> stat
    NRSub stat -> e (NRSub_, ' ', stat)
    NRPong -> e NRPong_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP _v = \case
    NRTknId_ -> NRTknId <$> _smpP <*> smpP
    NRSubId_ -> NRSubId <$> _smpP
    NROk_ -> pure NROk
    NRErr_ -> NRErr <$> _smpP
    NRTkn_ -> NRTkn <$> _smpP
    NRSub_ -> NRSub <$> _smpP
    NRPong_ -> pure NRPong

  fromProtocolError = \case
    PECmdSyntax -> CMD SYNTAX
    PECmdUnknown -> CMD UNKNOWN
    PESession -> SESSION
    PEBlock -> BLOCK
  {-# INLINE fromProtocolError #-}

  checkCredentials _ (EntityId entId) cmd = case cmd of
    -- IDTKN response must not have queue ID
    NRTknId {} -> noEntity
    -- IDSUB response must not have queue ID
    NRSubId {} -> noEntity
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
  { smpServer :: SMPServer,
    notifierId :: NotifierId
  }
  deriving (Eq, Ord, Show)

instance Encoding SMPQueueNtf where
  smpEncode SMPQueueNtf {smpServer, notifierId} = smpEncode (smpServer, notifierId)
  smpP = do
    smpServer <- updateSMPServerHosts <$> smpP
    notifierId <- smpP
    pure SMPQueueNtf {smpServer, notifierId}

instance StrEncoding SMPQueueNtf where
  strEncode SMPQueueNtf {smpServer, notifierId} = strEncode smpServer <> "/" <> strEncode notifierId
  strP = do
    smpServer <- updateSMPServerHosts <$> strP
    notifierId <- A.char '/' *> strP
    pure SMPQueueNtf {smpServer, notifierId}

data PushProvider = PPAPNS APNSProvider | PPWP WPProvider
  deriving (Eq, Ord, Show)

data APNSProvider
  = PPApnsDev -- provider for Apple development environment
  | PPApnsProd -- production environment, including TestFlight
  | PPApnsTest -- used for tests, to use APNS mock server
  | PPApnsNull -- used to test servers from the client - does not communicate with APNS
  deriving (Eq, Ord, Show)

newtype WPSrvLoc = WPSrvLoc SrvLoc
  deriving (Eq, Ord, Show)

newtype WPProvider = WPP WPSrvLoc
  deriving (Eq, Ord, Show)

instance Encoding PushProvider where
  smpEncode = \case
    PPAPNS p -> smpEncode p
    PPWP p -> smpEncode p
  smpP =
    A.peekChar' >>= \case
      'A' -> PPAPNS <$> smpP
      _ -> PPWP <$> smpP

instance Encoding APNSProvider where
  smpEncode = \case
    PPApnsDev -> "AD"
    PPApnsProd -> "AP"
    PPApnsTest -> "AT"
    PPApnsNull -> "AN"
  smpP =
    A.take 2 >>= \case
      "AD" -> pure PPApnsDev
      "AP" -> pure PPApnsProd
      "AT" -> pure PPApnsTest
      "AN" -> pure PPApnsNull
      _ -> fail "bad APNSProvider"

instance StrEncoding PushProvider where
  strEncode = \case
    PPAPNS p -> strEncode p
    PPWP p -> strEncode p
  strP =
    A.peekChar' >>= \case
      'a' -> PPAPNS <$> strP
      _ -> PPWP <$> strP

instance StrEncoding APNSProvider where
  strEncode = \case
    PPApnsDev -> "apns_dev"
    PPApnsProd -> "apns_prod"
    PPApnsTest -> "apns_test"
    PPApnsNull -> "apns_null"
  strP =
    A.takeTill (== ' ') >>= \case
      "apns_dev" -> pure PPApnsDev
      "apns_prod" -> pure PPApnsProd
      "apns_test" -> pure PPApnsTest
      "apns_null" -> pure PPApnsNull
      _ -> fail "bad APNSProvider"

instance Encoding WPSrvLoc where
  smpEncode (WPSrvLoc srv) = smpEncode srv
  smpP = WPSrvLoc <$> smpP

instance StrEncoding WPSrvLoc where
  strEncode (WPSrvLoc srv) = "https://" <> strEncode srv
  strP = WPSrvLoc <$> ("https://" *> strP)

instance Encoding WPProvider where
  smpEncode (WPP srv) = "WP" <> smpEncode srv
  smpP = WPP <$> ("WP" *> smpP)

instance StrEncoding WPProvider where
  strEncode (WPP srv) = "webpush " <> strEncode srv
  strP = WPP <$> ("webpush " *> strP)

instance FromField PushProvider where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField PushProvider where toField = toField . decodeLatin1 . strEncode

newtype WPAuth = WPAuth {unWPAuth :: ByteString} deriving (Eq, Ord, Show)

toWPAuth :: ByteString -> Either String WPAuth
toWPAuth s
  | B.length s == 16 = Right $ WPAuth s
  | otherwise = Left "bad WPAuth"

newtype WPP256dh = WPP256dh ECC.PublicPoint
  deriving (Eq, Show)

-- This Ord instance for ECC point is quite arbitrary, it is needed because token is used as Map key
instance Ord WPP256dh where
  compare (WPP256dh p1) (WPP256dh p2) = case (p1, p2) of
    (ECC.PointO, ECC.PointO) -> EQ
    (ECC.PointO, _) -> GT
    (_, ECC.PointO) -> LT
    (ECC.Point x1 y1, ECC.Point x2 y2) -> compare (x1, y1) (x2, y2)

data WPKey = WPKey
  { wpAuth :: WPAuth,
    wpP256dh :: WPP256dh
  }
  deriving (Eq, Ord, Show)

uncompressEncode :: WPP256dh -> BL.ByteString
uncompressEncode (WPP256dh p) = C.uncompressEncodePoint p

uncompressDecode :: BL.ByteString -> Either CE.CryptoError WPP256dh
uncompressDecode bs = WPP256dh <$> C.uncompressDecodePoint bs

data WPTokenParams = WPTokenParams
  { wpPath :: ByteString,
    wpKey :: WPKey
  }
  deriving (Eq, Ord, Show)

instance Encoding WPAuth where
  smpEncode = smpEncode . unWPAuth
  smpP = toWPAuth <$?> smpP

instance StrEncoding WPAuth where
  strEncode = strEncode . unWPAuth
  strP = toWPAuth <$?> strP

instance Encoding WPP256dh where
  smpEncode p = smpEncode . BL.toStrict $ uncompressEncode p
  smpP = smpP >>= \bs ->
    case uncompressDecode (BL.fromStrict bs) of
      Left _ -> fail "Invalid p256dh key"
      Right res -> pure res

instance StrEncoding WPP256dh where
  strEncode p = strEncode . BL.toStrict $ uncompressEncode p
  strP = strP >>= \bs ->
    case uncompressDecode (BL.fromStrict bs) of
      Left _ -> fail "Invalid p256dh key"
      Right res -> pure res

instance Encoding WPKey where
  smpEncode WPKey {wpAuth, wpP256dh} = smpEncode (wpAuth, wpP256dh)
  smpP = do
    wpAuth <- smpP
    wpP256dh <- smpP
    pure WPKey {wpAuth, wpP256dh}

instance StrEncoding WPKey where
  strEncode WPKey {wpAuth, wpP256dh} = strEncode (wpAuth, wpP256dh)
  strP = do
    (wpAuth, wpP256dh) <- strP
    pure WPKey {wpAuth, wpP256dh}

instance Encoding WPTokenParams where
  smpEncode WPTokenParams {wpPath, wpKey} = smpEncode (wpPath, wpKey)
  smpP = do
    wpPath <- smpP
    wpKey <- smpP
    pure WPTokenParams {wpPath, wpKey}

instance StrEncoding WPTokenParams where
  strEncode WPTokenParams {wpPath, wpKey} = wpPath <> " " <> strEncode wpKey
  strP = do
    wpPath <- A.takeWhile (/= ' ')
    _ <- A.char ' '
    wpKey <- strP
    pure WPTokenParams {wpPath, wpKey}

data DeviceToken
  = APNSDeviceToken APNSProvider ByteString
  | WPDeviceToken WPProvider WPTokenParams
  deriving (Eq, Ord, Show)

tokenPushProvider :: DeviceToken -> PushProvider
tokenPushProvider = \case
  APNSDeviceToken pp _ -> PPAPNS pp
  WPDeviceToken pp _ -> PPWP pp

instance Encoding DeviceToken where
  smpEncode token = case token of
    APNSDeviceToken p t -> smpEncode (p, t)
    WPDeviceToken p t -> smpEncode (p, t)
  smpP =
    smpP >>= \case
      PPAPNS p -> APNSDeviceToken p <$> smpP
      PPWP p -> WPDeviceToken p <$> smpP

instance StrEncoding DeviceToken where
  strEncode token = case token of
    APNSDeviceToken p t -> strEncode p <> " " <> t
    -- We don't do strEncode (p, t), because we don't want any space between
    -- p (e.g. webpush https://localhost) and t.wpPath (e.g /random)
    WPDeviceToken p t -> strEncode p <> strEncode t
  strP = nullToken <|> deviceToken
    where
      nullToken = "apns_null test_ntf_token" $> APNSDeviceToken PPApnsNull "test_ntf_token"
      deviceToken =
        strP >>= \case
          PPAPNS p -> APNSDeviceToken p <$> hexStringP
          PPWP p -> do
            t <- WPDeviceToken p <$> strP
            _ <- wpRequest t
            pure t
      hexStringP = do
        _ <- A.space
        A.takeWhile (`B.elem` "0123456789abcdef") >>= \s ->
          if even (B.length s) then pure s else fail "odd number of hex characters"

instance ToJSON DeviceToken where
  toEncoding token = case token of
    APNSDeviceToken p t -> J.pairs $ "pushProvider" .= decodeLatin1 (strEncode p) <> "token" .= decodeLatin1 t
    -- ToJSON/FromJSON isn't used for WPDeviceToken, we just include the pushProvider so it can fail properly if used to decrypt
    WPDeviceToken p _ -> J.pairs $ "pushProvider" .= decodeLatin1 (strEncode p)
    -- WPDeviceToken p t -> J.pairs $ "pushProvider" .= decodeLatin1 (strEncode p) <> "token" .= toJSON t
  toJSON token = case token of
    APNSDeviceToken p t -> J.object ["pushProvider" .= decodeLatin1 (strEncode p), "token" .= decodeLatin1 t]
    -- ToJSON/FromJSON isn't used for WPDeviceToken, we just include the pushProvider so it can fail properly if used to decrypt
    WPDeviceToken p _ -> J.object ["pushProvider" .= decodeLatin1 (strEncode p)]
    -- WPDeviceToken p t -> J.object ["pushProvider" .= decodeLatin1 (strEncode p), "token" .= toJSON t]

instance FromJSON DeviceToken where
  parseJSON = J.withObject "DeviceToken" $ \o ->
    (strDecode . encodeUtf8 <$?> o .: "pushProvider") >>= \case
      PPAPNS p -> APNSDeviceToken p . encodeUtf8 <$> (o .: "token")
      PPWP _ -> fail "FromJSON not implemented for WPDeviceToken"

-- | Returns fields for the device token (pushProvider, token)
-- TODO [webpush] save token as separate fields
deviceTokenFields :: DeviceToken -> (PushProvider, ByteString)
deviceTokenFields dt = case dt of
  APNSDeviceToken p t -> (PPAPNS p, t)
  WPDeviceToken p t -> (PPWP p, strEncode t)

-- | Returns the device token from the fields (pushProvider, token)
deviceToken' :: PushProvider -> ByteString -> DeviceToken
deviceToken' pp t = case pp of
  PPAPNS p -> APNSDeviceToken p t
  PPWP p -> WPDeviceToken p <$> either error id $ strDecode t

wpRequest :: MonadFail m => DeviceToken -> m Request
wpRequest (APNSDeviceToken _ _) = fail "Invalid device token"
wpRequest (WPDeviceToken (WPP s) param) = do
  let endpoint = strEncode s <> wpPath param
  case parseUrlThrow $ B.unpack endpoint of
    Left _ -> fail "Invalid URL"
    Right r -> pure r

-- List of PNMessageData uses semicolon-separated encoding instead of strEncode,
-- because strEncode of NonEmpty list uses comma for separator,
-- and encoding of PNMessageData's smpQueue has comma in list of hosts
encodePNMessages :: NonEmpty PNMessageData -> ByteString
encodePNMessages = B.intercalate ";" . map strEncode . L.toList

pnMessagesP :: A.Parser (NonEmpty PNMessageData)
pnMessagesP = L.fromList <$> strP `A.sepBy1` A.char ';'

data PNMessageData = PNMessageData
  { smpQueue :: SMPQueueNtf,
    ntfTs :: SystemTime,
    nmsgNonce :: C.CbNonce,
    encNMsgMeta :: EncNMsgMeta
  }
  deriving (Show)

instance StrEncoding PNMessageData where
  strEncode PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta} =
    strEncode (smpQueue, ntfTs, nmsgNonce, encNMsgMeta)
  strP = do
    (smpQueue, ntfTs, nmsgNonce, encNMsgMeta) <- strP
    pure PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}

type NtfEntityId = EntityId

type NtfSubscriptionId = NtfEntityId

type NtfTokenId = NtfEntityId

data NtfSubStatus
  = -- | state after SNEW
    NSNew
  | -- | pending connection/subscription to SMP server
    NSPending
  | -- | connected and subscribed to SMP server
    NSActive
  | -- | disconnected/unsubscribed from SMP server
    NSInactive
  | -- | END received
    NSEnd
  | -- | DELD received (connection was deleted)
    NSDeleted
  | -- | SMP AUTH error
    NSAuth
  | -- | SMP SERVICE error - rejected service signature on individual subscriptions
    NSService
  | -- | SMP error other than AUTH
    NSErr ByteString
  deriving (Eq, Ord, Show)

ntfShouldSubscribe :: NtfSubStatus -> Bool
ntfShouldSubscribe = \case
  NSNew -> True
  NSPending -> True
  NSActive -> True
  NSInactive -> True
  NSEnd -> False
  NSDeleted -> False
  NSAuth -> False
  NSService -> True
  NSErr _ -> False

instance Encoding NtfSubStatus where
  smpEncode = \case
    NSNew -> "NEW"
    NSPending -> "PENDING" -- e.g. after SMP server disconnect/timeout while ntf server is retrying to connect
    NSActive -> "ACTIVE"
    NSInactive -> "INACTIVE"
    NSEnd -> "END"
    NSDeleted -> "DELETED"
    NSAuth -> "AUTH"
    NSService -> "SERVICE"
    NSErr err -> "ERR " <> err
  smpP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> pure NSNew
      "PENDING" -> pure NSPending
      "ACTIVE" -> pure NSActive
      "INACTIVE" -> pure NSInactive
      "END" -> pure NSEnd
      "DELETED" -> pure NSDeleted
      "AUTH" -> pure NSAuth
      "SERVICE" -> pure NSService
      "ERR" -> NSErr <$> (A.space *> A.takeByteString)
      _ -> fail "bad NtfSubStatus"

instance StrEncoding NtfSubStatus where
  strEncode = smpEncode
  {-# INLINE strEncode #-}
  strP = smpP
  {-# INLINE strP #-}

data NtfTknStatus
  = -- | Token created in DB
    NTNew
  | -- | state after registration (TNEW)
    NTRegistered
  | -- | if initial notification failed (push provider error) or verification failed
    NTInvalid (Maybe NTInvalidReason)
  | -- | Token confirmed via notification (accepted by push provider or verification code received by client)
    NTConfirmed
  | -- | after successful verification (TVFY)
    NTActive
  | -- | after it is no longer valid (push provider error)
    NTExpired
  deriving (Eq, Show)

allowTokenVerification :: NtfTknStatus -> Bool
allowTokenVerification = \case
  NTNew -> False
  NTRegistered -> True
  NTInvalid _ -> False
  NTConfirmed -> True
  NTActive -> True
  NTExpired -> False

allowNtfSubCommands :: NtfTknStatus -> Bool
allowNtfSubCommands = \case
  NTNew -> False
  NTRegistered -> False
  -- TODO we could have separate statuses to show whether it became invalid
  -- after verification (allow commands) or before (do not allow)
  NTInvalid _ -> True
  NTConfirmed -> False
  NTActive -> True
  NTExpired -> True

instance Encoding NtfTknStatus where
  smpEncode = \case
    NTNew -> "NEW"
    NTRegistered -> "REGISTERED"
    NTInvalid r_ -> "INVALID" <> maybe "" (\r -> ',' `B.cons` strEncode r) r_
    NTConfirmed -> "CONFIRMED"
    NTActive -> "ACTIVE"
    NTExpired -> "EXPIRED"
  smpP =
    A.takeTill (\c -> c == ' ' || c == ',') >>= \case
      "NEW" -> pure NTNew
      "REGISTERED" -> pure NTRegistered
      "INVALID" -> NTInvalid <$> optional (A.char ',' *> strP)
      "CONFIRMED" -> pure NTConfirmed
      "ACTIVE" -> pure NTActive
      "EXPIRED" -> pure NTExpired
      _ -> fail "bad NtfTknStatus"

instance StrEncoding NTInvalidReason where
  strEncode = smpEncode
  strP = smpP

data NTInvalidReason = NTIRBadToken | NTIRTokenNotForTopic | NTIRExpiredToken | NTIRUnregistered
  deriving (Eq, Show)

instance Encoding NTInvalidReason where
  smpEncode = \case
    NTIRBadToken -> "BAD"
    NTIRTokenNotForTopic -> "TOPIC"
    NTIRExpiredToken -> "EXPIRED"
    NTIRUnregistered -> "UNREGISTERED"
  smpP =
    A.takeTill (== ' ') >>= \case
      "BAD" -> pure NTIRBadToken
      "TOPIC" -> pure NTIRTokenNotForTopic
      "EXPIRED" -> pure NTIRExpiredToken
      "UNREGISTERED" -> pure NTIRUnregistered
      _ -> fail "bad NTInvalidReason"

instance StrEncoding NtfTknStatus where
  strEncode = smpEncode
  strP = smpP

instance FromField NtfTknStatus where fromField = fromTextField_ $ either (const Nothing) Just . smpDecode . encodeUtf8

instance ToField NtfTknStatus where toField = toField . decodeLatin1 . smpEncode

instance ToJSON NtfTknStatus where
  toEncoding = JE.text . decodeLatin1 . smpEncode
  toJSON = J.String . decodeLatin1 . smpEncode

instance FromJSON NtfTknStatus where
  parseJSON = J.withText "NtfTknStatus" $ either fail pure . smpDecode . encodeUtf8

checkEntity :: forall t e e'. (NtfEntityI e, NtfEntityI e') => t e' -> Either String (t e)
checkEntity c = case testEquality (sNtfEntity @e) (sNtfEntity @e') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkEntity' :: forall t p p'. (NtfEntityI p, NtfEntityI p') => t p' -> Maybe (t p)
checkEntity' c = case testEquality (sNtfEntity @p) (sNtfEntity @p') of
  Just Refl -> Just c
  _ -> Nothing
