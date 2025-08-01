{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# HLINT ignore "Use newtype instead of data" #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

-- |
-- Module      : Simplex.Messaging.ProtocolEncoding
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- Types, parsers, serializers and functions to send and receive SMP protocol commands and responses.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Protocol
  ( -- * SMP protocol parameters
    supportedSMPClientVRange,
    maxMessageLength,
    paddedProxiedTLength,
    e2eEncConfirmationLength,
    e2eEncMessageLength,

    -- * SMP protocol types
    SMPClientVersion,
    VersionSMPC,
    VersionRangeSMPC,
    pattern VersionSMPC,
    ProtocolEncoding (..),
    Command (..),
    SubscriptionMode (..),
    NewQueueReq (..),
    QueueReqData (..),
    QueueMode (..),
    QueueLinkData,
    EncFixedDataBytes,
    EncUserDataBytes,
    EncDataBytes (..),
    NewNtfCreds (..),
    ServerNtfCreds (..),
    Party (..),
    Cmd (..),
    QueueParty,
    BatchParty,
    ServiceParty,
    ASubscriberParty (..),
    BrokerMsg (..),
    SParty (..),
    PartyI (..),
    QueueIdsKeys (..),
    ProtocolErrorType (..),
    ErrorType (..),
    CommandError (..),
    ProxyError (..),
    BrokerErrorType (..),
    BlockingInfo (..),
    BlockingReason (..),
    RawTransmission,
    Transmission,
    TAuthorizations,
    TransmissionAuth (..),
    SignedTransmission,
    SignedTransmissionOrError,
    SentRawTransmission,
    ClientMsgEnvelope (..),
    PubHeader (..),
    ClientMessage (..),
    PrivHeader (..),
    Protocol (..),
    ProtocolType (..),
    SProtocolType (..),
    AProtocolType (..),
    ProtocolTypeI (..),
    UserProtocol,
    ProtocolServer (..),
    ProtoServer,
    SMPServer,
    pattern SMPServer,
    SMPServerWithAuth,
    NtfServer,
    pattern NtfServer,
    NtfServerWithAuth,
    XFTPServer,
    pattern XFTPServer,
    XFTPServerWithAuth,
    ProtoServerWithAuth (..),
    AProtoServerWithAuth (..),
    BasicAuth (..),
    SrvLoc (..),
    CorrId (..),
    pattern NoCorrId,
    EntityId (..),
    pattern NoEntity,
    QueueId,
    RecipientId,
    SenderId,
    LinkId,
    NotifierId,
    ServiceId,
    RcvPrivateAuthKey,
    RcvPublicAuthKey,
    RcvPublicDhKey,
    RcvDhSecret,
    SndPrivateAuthKey,
    SndPublicAuthKey,
    NtfPrivateAuthKey,
    NtfPublicAuthKey,
    RcvNtfPublicDhKey,
    RcvNtfDhSecret,
    Message (..),
    RcvMessage (..),
    MsgId,
    MsgBody,
    MaxMessageLen,
    MaxRcvMessageLen,
    EncRcvMsgBody (..),
    RcvMsgBody (..),
    ClientRcvMsgBody (..),
    EncNMsgMeta,
    SMPMsgMeta (..),
    NMsgMeta (..),
    EncFwdResponse (..),
    EncFwdTransmission (..),
    EncResponse (..),
    EncTransmission (..),
    FwdResponse (..),
    FwdTransmission (..),
    MsgFlags (..),
    initialSMPClientVersion,
    currentSMPClientVersion,
    senderCanSecure,
    queueReqMode,
    queueParty,
    batchParty,
    serviceParty,
    partyClientRole,
    partyServiceRole,
    userProtocol,
    rcvMessageMeta,
    noMsgFlags,
    messageId,
    messageTs,

    -- * Parse and serialize
    ProtocolMsgTag (..),
    messageTagP,
    TransmissionForAuth (..),
    encodeTransmissionForAuth,
    encodeTransmission,
    transmissionP,
    _smpP,
    encodeRcvMsgBody,
    clientRcvMsgBodyP,
    legacyEncodeServer,
    legacyServerP,
    legacyStrEncodeServer,
    srvHostnamesSMPClientVersion,
    sndAuthKeySMPClientVersion,
    shortLinksSMPClientVersion,
    sameSrvAddr,
    sameSrvAddr',
    noAuthSrv,
    toMsgInfo,

    -- * TCP transport functions
    TransportBatch (..),
    tPut,
    tPutLog,
    tGetServer,
    tGetClient,
    tParse,
    tDecodeServer,
    tDecodeClient,
    tEncode,
    tEncodeBatch1,
    batchTransmissions,
    batchTransmissions',
    batchTransmissions_,

    -- * exports for tests
    CommandTag (..),
    BrokerMsgTag (..),
  )
where

import Control.Applicative (optional, (<|>))
import Control.Exception (Exception)
import Control.Monad.Except
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson.TH as J
import Data.Attoparsec.ByteString.Char8 (Parser, (<?>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (bimap, first)
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isPrint, isSpace)
import Data.Constraint (Dict (..))
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Maybe (isJust, isNothing)
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock.System (SystemTime (..), systemToUTCTime)
import Data.Type.Equality
import Data.Word (Word16)
import GHC.TypeLits (ErrorMessage (..), TypeError, type (+))
import qualified GHC.TypeLits as TE
import qualified GHC.TypeLits as Type
import Network.Socket (ServiceName)
import Simplex.Messaging.Agent.Store.DB (Binary (..), FromField (..), ToField (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Server.QueueStore.QueueInfo
import Simplex.Messaging.ServiceScheme
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (TransportHost, TransportHosts (..))
import Simplex.Messaging.Util (bshow, eitherToMaybe, safeDecodeUtf8, (<$?>))
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal

-- SMP client protocol version history:
-- 1 - binary protocol encoding (1/1/2022)
-- 2 - multiple server hostnames and versioned queue addresses (8/12/2022)
-- 3 - faster handshake: SKEY command for sender to secure queue (6/30/2024, SMP protocol version 9)
-- 4 - short connection links with stored data (3/30/2025, SMP protocol version 15)

data SMPClientVersion

instance VersionScope SMPClientVersion

type VersionSMPC = Version SMPClientVersion

type VersionRangeSMPC = VersionRange SMPClientVersion

pattern VersionSMPC :: Word16 -> VersionSMPC
pattern VersionSMPC v = Version v

initialSMPClientVersion :: VersionSMPC
initialSMPClientVersion = VersionSMPC 1

srvHostnamesSMPClientVersion :: VersionSMPC
srvHostnamesSMPClientVersion = VersionSMPC 2

sndAuthKeySMPClientVersion :: VersionSMPC
sndAuthKeySMPClientVersion = VersionSMPC 3

shortLinksSMPClientVersion :: VersionSMPC
shortLinksSMPClientVersion = VersionSMPC 4

currentSMPClientVersion :: VersionSMPC
currentSMPClientVersion = VersionSMPC 4

supportedSMPClientVRange :: VersionRangeSMPC
supportedSMPClientVRange = mkVersionRange initialSMPClientVersion currentSMPClientVersion

-- TODO v6.0 remove dependency on version
maxMessageLength :: VersionSMP -> Int
maxMessageLength v
  | v >= encryptedBlockSMPVersion = 16048 -- max 16048
  | v >= sendingProxySMPVersion = 16064 -- max 16067
  | otherwise = 16088 -- 16048 - always use this size to determine allowed ranges

paddedProxiedTLength :: Int
paddedProxiedTLength = 16226 -- 16225 .. 16227

-- TODO v7.0 change to 16048
type MaxMessageLen = 16088

-- 16 extra bytes: 8 for timestamp and 8 for flags (7 flags and the space, only 1 flag is currently used)
type MaxRcvMessageLen = MaxMessageLen + 16 -- 16104, the padded size is 16106

-- it is shorter to allow per-queue e2e encryption DH key in the "public" header
e2eEncConfirmationLength :: Int
e2eEncConfirmationLength = 15904 -- 15865 .. 15960

e2eEncMessageLength :: Int
e2eEncMessageLength = 16000 -- 15988 .. 16005

-- | SMP protocol clients
data Party
  = Creator
  | Recipient
  | RecipientService
  | Sender
  | IdleClient
  | Notifier
  | NotifierService
  | LinkClient
  | ProxiedClient
  | ProxyService
  deriving (Show)

-- | Singleton types for SMP protocol clients
data SParty :: Party -> Type where
  SCreator :: SParty Creator
  SRecipient :: SParty Recipient
  SRecipientService :: SParty RecipientService
  SSender :: SParty Sender
  SIdleClient :: SParty IdleClient
  SNotifier :: SParty Notifier
  SNotifierService :: SParty NotifierService
  SSenderLink :: SParty LinkClient
  SProxiedClient :: SParty ProxiedClient
  SProxyService :: SParty ProxyService

instance TestEquality SParty where
  testEquality SCreator SCreator = Just Refl
  testEquality SRecipient SRecipient = Just Refl
  testEquality SRecipientService SRecipientService = Just Refl
  testEquality SSender SSender = Just Refl
  testEquality SIdleClient SIdleClient = Just Refl
  testEquality SNotifier SNotifier = Just Refl
  testEquality SNotifierService SNotifierService = Just Refl
  testEquality SSenderLink SSenderLink = Just Refl
  testEquality SProxiedClient SProxiedClient = Just Refl
  testEquality SProxyService SProxyService = Just Refl
  testEquality _ _ = Nothing

deriving instance Show (SParty p)

class PartyI (p :: Party) where sParty :: SParty p

instance PartyI Creator where sParty = SCreator

instance PartyI Recipient where sParty = SRecipient

instance PartyI RecipientService where sParty = SRecipientService

instance PartyI Sender where sParty = SSender

instance PartyI IdleClient where sParty = SIdleClient

instance PartyI Notifier where sParty = SNotifier

instance PartyI NotifierService where sParty = SNotifierService

instance PartyI LinkClient where sParty = SSenderLink

instance PartyI ProxiedClient where sParty = SProxiedClient

instance PartyI ProxyService where sParty = SProxyService

-- command parties that can read queues
type family QueueParty (p :: Party) :: Constraint where
  QueueParty Recipient = ()
  QueueParty Sender = ()
  QueueParty Notifier = ()
  QueueParty LinkClient = ()
  QueueParty p =
    (Int ~ Bool, TypeError (Type.Text "Party " :<>: ShowType p :<>: Type.Text " is not QueueParty"))

queueParty :: SParty p -> Maybe (Dict (PartyI p, QueueParty p))
queueParty = \case
  SRecipient -> Just Dict
  SSender -> Just Dict
  SSenderLink -> Just Dict
  SNotifier -> Just Dict
  _ -> Nothing
{-# INLINE queueParty #-}

type family BatchParty (p :: Party) :: Constraint where
  BatchParty Recipient = ()
  BatchParty Notifier = ()
  BatchParty p =
    (Int ~ Bool, TypeError (Type.Text "Party " :<>: ShowType p :<>: Type.Text " is not BatchParty"))

batchParty :: SParty p -> Maybe (Dict (PartyI p, BatchParty p))
batchParty = \case
  SRecipient -> Just Dict
  SNotifier -> Just Dict
  _ -> Nothing
{-# INLINE batchParty #-}

-- command parties that can subscribe to individual queues
type family ServiceParty (p :: Party) :: Constraint where
  ServiceParty RecipientService = ()
  ServiceParty NotifierService = ()
  ServiceParty p =
    (Int ~ Bool, TypeError (Type.Text "Party " :<>: ShowType p :<>: Type.Text " is not ServiceParty"))

serviceParty :: SParty p -> Maybe (Dict (PartyI p, ServiceParty p))
serviceParty = \case
  SRecipientService -> Just Dict
  SNotifierService -> Just Dict
  _ -> Nothing
{-# INLINE serviceParty #-}

data ASubscriberParty = forall p. (PartyI p, ServiceParty p) => ASP (SParty p)

deriving instance Show ASubscriberParty

instance Eq ASubscriberParty where
  ASP p == ASP p' = isJust $ testEquality p p'

instance Encoding ASubscriberParty where
  smpEncode = \case
    ASP SRecipientService -> "R"
    ASP SNotifierService -> "N"
  smpP =
    A.anyChar >>= \case
      'R' -> pure $ ASP SRecipientService
      'N' -> pure $ ASP SNotifierService
      _ -> fail "bad ASubscriberParty"

instance StrEncoding ASubscriberParty where
  strEncode = smpEncode
  strP = smpP

partyClientRole :: SParty p -> Maybe SMPServiceRole
partyClientRole = \case
  SCreator -> Just SRMessaging
  SRecipient -> Just SRMessaging
  SRecipientService -> Just SRMessaging
  SSender -> Just SRMessaging
  SIdleClient -> Nothing
  SNotifier -> Just SRNotifier
  SNotifierService -> Just SRNotifier
  SSenderLink -> Just SRMessaging
  SProxiedClient -> Just SRMessaging
  SProxyService -> Just SRProxy
{-# INLINE partyClientRole #-}

partyServiceRole :: ServiceParty p => SParty p -> SMPServiceRole
partyServiceRole = \case
  SRecipientService -> SRMessaging
  SNotifierService -> SRNotifier
{-# INLINE partyServiceRole #-}

-- | Type for client command of any participant.
data Cmd = forall p. PartyI p => Cmd (SParty p) (Command p)

deriving instance Show Cmd

-- | Parsed SMP transmission without signature, size and session ID.
type Transmission c = (CorrId, EntityId, c)

-- | signed parsed transmission, with original raw bytes and parsing error.
type SignedTransmission c = (Maybe TAuthorizations, Signed, Transmission c)

type SignedTransmissionOrError e c = Either (Transmission e) (SignedTransmission c)

type Signed = ByteString

-- | unparsed SMP transmission with signature.
data RawTransmission = RawTransmission
  { authenticator :: ByteString, -- signature or encrypted transmission hash
    serviceSig :: Maybe (C.Signature 'C.Ed25519), -- optional second signature with the key of the client service
    authorized :: ByteString, -- authorized transmission
    sessId :: SessionId,
    corrId :: CorrId,
    entityId :: EntityId,
    command :: ByteString
  }
  deriving (Show)

type TAuthorizations = (TransmissionAuth, Maybe (C.Signature 'C.Ed25519))

data TransmissionAuth
  = TASignature C.ASignature
  | TAAuthenticator C.CbAuthenticator
  deriving (Show)

-- this encoding is backwards compatible with v6 that used Maybe C.ASignature instead of TransmissionAuth
tEncodeAuth :: Bool -> Maybe TAuthorizations -> ByteString
tEncodeAuth serviceAuth = \case
  Nothing -> smpEncode B.empty
  Just (auth, sig)
    | serviceAuth -> smpEncode (authBytes auth, sig)
    | otherwise -> smpEncode (authBytes auth)
  where
    authBytes = \case
      TASignature s -> C.signatureBytes s
      TAAuthenticator (C.CbAuthenticator s) -> s

decodeTAuthBytes :: ByteString -> Maybe (C.Signature 'C.Ed25519) -> Either String (Maybe TAuthorizations)
decodeTAuthBytes s serviceSig
  | B.null s = Right Nothing
  | B.length s == C.cbAuthenticatorSize = Right $ Just (TAAuthenticator (C.CbAuthenticator s), serviceSig)
  | otherwise = (\sig -> Just (TASignature sig, serviceSig)) <$> C.decodeSignature s

-- | unparsed sent SMP transmission with signature.
type SentRawTransmission = (Maybe TAuthorizations, ByteString)

-- | SMP queue ID for the recipient.
type RecipientId = QueueId

-- | SMP queue ID for the sender.
type SenderId = QueueId

-- | SMP queue ID for notifications.
type NotifierId = QueueId

type LinkId = QueueId

-- | SMP queue ID on the server.
type QueueId = EntityId

-- | Parameterized type for SMP protocol commands from all clients.
data Command (p :: Party) where
  -- SMP recipient commands
  -- RcvPublicAuthKey is the key used for command authorization:
  -- v6 of SMP servers only support signature algorithm for command authorization.
  -- v7 of SMP servers additionally support additional layer of authenticated encryption.
  -- RcvPublicAuthKey is defined as C.APublicKey - it can be either signature or DH public keys.
  NEW :: NewQueueReq -> Command Creator
  SUB :: Command Recipient
  -- | subscribe all associated queues. Service ID must be used as entity ID, and service session key must sign the command.
  SUBS :: Command RecipientService
  KEY :: SndPublicAuthKey -> Command Recipient
  RKEY :: NonEmpty RcvPublicAuthKey -> Command Recipient
  LSET :: LinkId -> QueueLinkData -> Command Recipient
  LDEL :: Command Recipient
  NKEY :: NtfPublicAuthKey -> RcvNtfPublicDhKey -> Command Recipient
  NDEL :: Command Recipient
  GET :: Command Recipient
  ACK :: MsgId -> Command Recipient
  OFF :: Command Recipient
  DEL :: Command Recipient
  QUE :: Command Recipient
  -- SMP sender commands
  SKEY :: SndPublicAuthKey -> Command Sender
  -- SEND v1 has to be supported for encoding/decoding
  -- SEND :: MsgBody -> Command Sender
  SEND :: MsgFlags -> MsgBody -> Command Sender
  PING :: Command IdleClient
  -- Client accessing short links
  LKEY :: SndPublicAuthKey -> Command LinkClient
  LGET :: Command LinkClient
  -- SMP notification subscriber commands
  NSUB :: Command Notifier
  -- | subscribe all associated queues. Service ID must be used as entity ID, and service session key must sign the command.
  NSUBS :: Command NotifierService
  PRXY :: SMPServer -> Maybe BasicAuth -> Command ProxiedClient -- request a relay server connection by URI
  -- Transmission to proxy:
  -- - entity ID: ID of the session with relay returned in PKEY (response to PRXY)
  -- - corrId: also used as a nonce to encrypt transmission to relay, corrId + 1 - from relay
  -- - key (1st param in the command) is used to agree DH secret for this particular transmission and its response
  -- Encrypted transmission should include session ID (tlsunique) from proxy-relay connection.
  PFWD :: VersionSMP -> C.PublicKeyX25519 -> EncTransmission -> Command ProxiedClient -- use CorrId as CbNonce, client to proxy
  -- Transmission forwarded to relay:
  -- - entity ID: empty
  -- - corrId: unique correlation ID between proxy and relay, also used as a nonce to encrypt forwarded transmission
  RFWD :: EncFwdTransmission -> Command ProxyService -- use CorrId as CbNonce, proxy to relay

deriving instance Show (Command p)

data NewQueueReq = NewQueueReq
  { rcvAuthKey :: RcvPublicAuthKey,
    rcvDhKey :: RcvPublicDhKey,
    auth_ :: Maybe BasicAuth,
    subMode :: SubscriptionMode,
    queueReqData :: Maybe QueueReqData,
    ntfCreds :: Maybe NewNtfCreds
  }
  deriving (Show)

data SubscriptionMode = SMSubscribe | SMOnlyCreate
  deriving (Eq, Show)

-- SenderId must be computed client-side as `sha3-256(corr_id)`, `corr_id` - a random transmission ID.
-- The server must verify and reject it if it does not match (and in case of collision).
-- This allows to include SenderId in FixedDataBytes in full connection request,
-- and at the same time prevents the possibility of checking whether a queue with a known ID exists.
data QueueReqData = QRMessaging (Maybe (SenderId, QueueLinkData)) | QRContact (Maybe (LinkId, (SenderId, QueueLinkData)))
  deriving (Show)

queueReqMode :: QueueReqData -> QueueMode
queueReqMode = \case
  QRMessaging _ -> QMMessaging
  QRContact _ -> QMContact

senderCanSecure :: Maybe QueueMode -> Bool
senderCanSecure = \case
  Just QMMessaging -> True
  _ -> False

type QueueLinkData = (EncFixedDataBytes, EncUserDataBytes)

type EncFixedDataBytes = EncDataBytes

type EncUserDataBytes = EncDataBytes

newtype EncDataBytes = EncDataBytes ByteString
  deriving (Eq, Show)
  deriving newtype (FromField, StrEncoding)

instance Encoding EncDataBytes where
  smpEncode (EncDataBytes s) = smpEncode (Large s)
  {-# INLINE smpEncode #-}
  smpP = EncDataBytes . unLarge <$> smpP
  {-# INLINE smpP #-}

instance ToField EncDataBytes where
  toField (EncDataBytes s) = toField (Binary s)
  {-# INLINE toField #-}

data NewNtfCreds = NewNtfCreds NtfPublicAuthKey RcvNtfPublicDhKey deriving (Show)

instance StrEncoding SubscriptionMode where
  strEncode = \case
    SMSubscribe -> "subscribe"
    SMOnlyCreate -> "only-create"
  strP =
    (A.string "subscribe" $> SMSubscribe)
      <|> (A.string "only-create" $> SMOnlyCreate)
        <?> "SubscriptionMode"

instance Encoding SubscriptionMode where
  smpEncode = \case
    SMSubscribe -> "S"
    SMOnlyCreate -> "C"
  smpP =
    A.anyChar >>= \case
      'S' -> pure SMSubscribe
      'C' -> pure SMOnlyCreate
      _ -> fail "bad SubscriptionMode"

instance Encoding QueueReqData where
  smpEncode = \case
    QRMessaging d -> smpEncode ('M', d)
    QRContact d -> smpEncode ('C', d)
  smpP =
    A.anyChar >>= \case
      'M' -> QRMessaging <$> smpP
      'C' -> QRContact <$> smpP
      _ -> fail "bad QueueReqData"

instance Encoding NewNtfCreds where
  smpEncode (NewNtfCreds authKey dhKey) = smpEncode (authKey, dhKey)
  smpP = NewNtfCreds <$> smpP <*> smpP

newtype EncTransmission = EncTransmission ByteString
  deriving (Show)

data FwdTransmission = FwdTransmission
  { fwdCorrId :: CorrId,
    fwdVersion :: VersionSMP,
    fwdKey :: C.PublicKeyX25519,
    fwdTransmission :: EncTransmission
  }

instance Encoding FwdTransmission where
  smpEncode FwdTransmission {fwdCorrId = CorrId corrId, fwdVersion, fwdKey, fwdTransmission = EncTransmission t} =
    smpEncode (corrId, fwdVersion, fwdKey, Tail t)
  smpP = do
    (corrId, fwdVersion, fwdKey, Tail t) <- smpP
    pure FwdTransmission {fwdCorrId = CorrId corrId, fwdVersion, fwdKey, fwdTransmission = EncTransmission t}

newtype EncFwdTransmission = EncFwdTransmission ByteString
  deriving (Show)

data BrokerMsg where
  -- SMP broker messages (responses, client messages, notifications)
  IDS :: QueueIdsKeys -> BrokerMsg
  LNK :: SenderId -> QueueLinkData -> BrokerMsg
  -- | Service subscription success - confirms when queue was associated with the service
  SOK :: Maybe ServiceId -> BrokerMsg
  -- | The number of queues subscribed with SUBS command
  SOKS :: Int64 -> BrokerMsg
  -- MSG v1/2 has to be supported for encoding/decoding
  -- v1: MSG :: MsgId -> SystemTime -> MsgBody -> BrokerMsg
  -- v2: MsgId -> SystemTime -> MsgFlags -> MsgBody -> BrokerMsg
  MSG :: RcvMessage -> BrokerMsg
  NID :: NotifierId -> RcvNtfPublicDhKey -> BrokerMsg
  NMSG :: C.CbNonce -> EncNMsgMeta -> BrokerMsg
  -- Should include certificate chain
  PKEY :: SessionId -> VersionRangeSMP -> CertChainPubKey -> BrokerMsg -- TLS-signed server key for proxy shared secret and initial sender key
  RRES :: EncFwdResponse -> BrokerMsg -- relay to proxy
  PRES :: EncResponse -> BrokerMsg -- proxy to client
  END :: BrokerMsg
  ENDS :: Int64 -> BrokerMsg
  DELD :: BrokerMsg
  INFO :: QueueInfo -> BrokerMsg
  OK :: BrokerMsg
  ERR :: ErrorType -> BrokerMsg
  PONG :: BrokerMsg
  deriving (Eq, Show)

data RcvMessage = RcvMessage
  { msgId :: MsgId,
    msgBody :: EncRcvMsgBody -- e2e encrypted, with extra encryption for recipient
  }
  deriving (Eq, Show)

newtype EncFwdResponse = EncFwdResponse ByteString
  deriving (Eq, Show)

data FwdResponse = FwdResponse
  { fwdCorrId :: CorrId,
    fwdResponse :: EncResponse
  }

instance Encoding FwdResponse where
  smpEncode FwdResponse {fwdCorrId = CorrId corrId, fwdResponse = EncResponse t} =
    smpEncode (corrId, Tail t)
  smpP = do
    (corrId, Tail t) <- smpP
    pure FwdResponse {fwdCorrId = CorrId corrId, fwdResponse = EncResponse t}

newtype EncResponse = EncResponse ByteString
  deriving (Eq, Show)

-- | received message without server/recipient encryption
data Message
  = Message
      { msgId :: MsgId,
        msgTs :: SystemTime,
        msgFlags :: MsgFlags,
        msgBody :: C.MaxLenBS MaxMessageLen
      }
  | MessageQuota
      { msgId :: MsgId,
        msgTs :: SystemTime
      }

toMsgInfo :: Message -> MsgInfo
toMsgInfo = \case
  Message {msgId, msgTs} -> msgInfo msgId msgTs MTMessage
  MessageQuota {msgId, msgTs} -> msgInfo msgId msgTs MTQuota
  where
    msgInfo msgId msgTs msgType = MsgInfo {msgId = decodeLatin1 $ B64.encode msgId, msgTs = systemToUTCTime msgTs, msgType}

messageId :: Message -> MsgId
messageId = \case
  Message {msgId} -> msgId
  MessageQuota {msgId} -> msgId
{-# INLINE messageId #-}

messageTs :: Message -> SystemTime
messageTs = \case
  Message {msgTs} -> msgTs
  MessageQuota {msgTs} -> msgTs
{-# INLINE messageTs #-}

newtype EncRcvMsgBody = EncRcvMsgBody ByteString
  deriving (Eq, Show)

data RcvMsgBody
  = RcvMsgBody
      { msgTs :: SystemTime,
        msgFlags :: MsgFlags,
        msgBody :: C.MaxLenBS MaxMessageLen
      }
  | RcvMsgQuota
      { msgTs :: SystemTime
      }

msgQuotaTag :: ByteString
msgQuotaTag = "QUOTA"

encodeRcvMsgBody :: RcvMsgBody -> C.MaxLenBS MaxRcvMessageLen
encodeRcvMsgBody = \case
  RcvMsgBody {msgTs, msgFlags, msgBody} ->
    let rcvMeta :: C.MaxLenBS 16 = C.unsafeMaxLenBS $ smpEncode (msgTs, msgFlags, ' ')
     in C.appendMaxLenBS rcvMeta msgBody
  RcvMsgQuota {msgTs} ->
    C.unsafeMaxLenBS $ msgQuotaTag <> " " <> smpEncode msgTs

data ClientRcvMsgBody
  = ClientRcvMsgBody
      { msgTs :: SystemTime,
        msgFlags :: MsgFlags,
        msgBody :: ByteString
      }
  | ClientRcvMsgQuota
      { msgTs :: SystemTime
      }

clientRcvMsgBodyP :: Parser ClientRcvMsgBody
clientRcvMsgBodyP = msgQuotaP <|> msgBodyP
  where
    msgQuotaP = A.string msgQuotaTag *> (ClientRcvMsgQuota <$> _smpP)
    msgBodyP = do
      msgTs <- smpP
      msgFlags <- smpP
      Tail msgBody <- _smpP
      pure ClientRcvMsgBody {msgTs, msgFlags, msgBody}

instance StrEncoding Message where
  strEncode = \case
    Message {msgId, msgTs, msgFlags, msgBody} ->
      B.unwords
        [ strEncode msgId,
          strEncode msgTs,
          "flags=" <> strEncode msgFlags,
          strEncode msgBody
        ]
    MessageQuota {msgId, msgTs} ->
      B.unwords
        [ strEncode msgId,
          strEncode msgTs,
          "quota"
        ]
  strP = do
    msgId <- strP_
    msgTs <- strP_
    msgQuotaP msgId msgTs <|> msgP msgId msgTs
    where
      msgQuotaP msgId msgTs = "quota" $> MessageQuota {msgId, msgTs}
      msgP msgId msgTs = do
        msgFlags <- ("flags=" *> strP_) <|> pure noMsgFlags
        msgBody <- strP
        pure Message {msgId, msgTs, msgFlags, msgBody}

type EncNMsgMeta = ByteString

data SMPMsgMeta = SMPMsgMeta
  { msgId :: MsgId,
    msgTs :: SystemTime,
    msgFlags :: MsgFlags
  }
  deriving (Eq, Show)

instance StrEncoding SMPMsgMeta where
  strEncode SMPMsgMeta {msgId, msgTs, msgFlags} =
    strEncode (msgId, msgTs, msgFlags)
  strP = do
    (msgId, msgTs, msgFlags) <- strP
    pure SMPMsgMeta {msgId, msgTs, msgFlags}

rcvMessageMeta :: MsgId -> ClientRcvMsgBody -> SMPMsgMeta
rcvMessageMeta msgId = \case
  ClientRcvMsgBody {msgTs, msgFlags} -> SMPMsgMeta {msgId, msgTs, msgFlags}
  ClientRcvMsgQuota {msgTs} -> SMPMsgMeta {msgId, msgTs, msgFlags = noMsgFlags}

data NMsgMeta = NMsgMeta
  { msgId :: MsgId,
    msgTs :: SystemTime
  }
  deriving (Show)

instance Encoding NMsgMeta where
  smpEncode NMsgMeta {msgId, msgTs} =
    smpEncode (msgId, msgTs)
  smpP = do
    -- Tail here is to allow extension in the future clients/servers
    (msgId, msgTs, Tail _) <- smpP
    pure NMsgMeta {msgId, msgTs}

-- it must be data for correct JSON encoding
data MsgFlags = MsgFlags {notification :: Bool}
  deriving (Eq, Show)

-- this encoding should not become bigger than 7 bytes (currently it is 1 byte)
instance Encoding MsgFlags where
  smpEncode MsgFlags {notification} = smpEncode notification
  smpP = do
    notification <- smpP <* A.takeTill (== ' ')
    pure MsgFlags {notification}

instance StrEncoding MsgFlags where
  strEncode = smpEncode
  {-# INLINE strEncode #-}
  strP = smpP
  {-# INLINE strP #-}

noMsgFlags :: MsgFlags
noMsgFlags = MsgFlags {notification = False}

-- * SMP command tags

data CommandTag (p :: Party) where
  NEW_ :: CommandTag Creator
  SUB_ :: CommandTag Recipient
  SUBS_ :: CommandTag RecipientService
  KEY_ :: CommandTag Recipient
  RKEY_ :: CommandTag Recipient
  LSET_ :: CommandTag Recipient
  LDEL_ :: CommandTag Recipient
  NKEY_ :: CommandTag Recipient
  NDEL_ :: CommandTag Recipient
  GET_ :: CommandTag Recipient
  ACK_ :: CommandTag Recipient
  OFF_ :: CommandTag Recipient
  DEL_ :: CommandTag Recipient
  QUE_ :: CommandTag Recipient
  SKEY_ :: CommandTag Sender
  SEND_ :: CommandTag Sender
  PING_ :: CommandTag IdleClient
  LKEY_ :: CommandTag LinkClient
  LGET_ :: CommandTag LinkClient
  PRXY_ :: CommandTag ProxiedClient
  PFWD_ :: CommandTag ProxiedClient
  RFWD_ :: CommandTag ProxyService
  NSUB_ :: CommandTag Notifier
  NSUBS_ :: CommandTag NotifierService

data CmdTag = forall p. PartyI p => CT (SParty p) (CommandTag p)

deriving instance Show (CommandTag p)

deriving instance Show CmdTag

data BrokerMsgTag
  = IDS_
  | LNK_
  | SOK_
  | SOKS_
  | MSG_
  | NID_
  | NMSG_
  | PKEY_
  | RRES_
  | PRES_
  | END_
  | ENDS_
  | DELD_
  | INFO_
  | OK_
  | ERR_
  | PONG_
  deriving (Show)

class ProtocolMsgTag t where
  decodeTag :: ByteString -> Maybe t

messageTagP :: ProtocolMsgTag t => Parser t
messageTagP =
  maybe (fail "bad message") pure . decodeTag
    =<< (A.takeTill (== ' ') <* optional A.space)

instance PartyI p => Encoding (CommandTag p) where
  smpEncode = \case
    NEW_ -> "NEW"
    SUB_ -> "SUB"
    SUBS_ -> "SUBS"
    KEY_ -> "KEY"
    RKEY_ -> "RKEY"
    LSET_ -> "LSET"
    LDEL_ -> "LDEL"
    NKEY_ -> "NKEY"
    NDEL_ -> "NDEL"
    GET_ -> "GET"
    ACK_ -> "ACK"
    OFF_ -> "OFF"
    DEL_ -> "DEL"
    QUE_ -> "QUE"
    SKEY_ -> "SKEY"
    SEND_ -> "SEND"
    PING_ -> "PING"
    LKEY_ -> "LKEY"
    LGET_ -> "LGET"
    PRXY_ -> "PRXY"
    PFWD_ -> "PFWD"
    RFWD_ -> "RFWD"
    NSUB_ -> "NSUB"
    NSUBS_ -> "NSUBS"
  smpP = messageTagP

instance ProtocolMsgTag CmdTag where
  decodeTag = \case
    "NEW" -> Just $ CT SCreator NEW_
    "SUB" -> Just $ CT SRecipient SUB_
    "SUBS" -> Just $ CT SRecipientService SUBS_
    "KEY" -> Just $ CT SRecipient KEY_
    "RKEY" -> Just $ CT SRecipient RKEY_
    "LSET" -> Just $ CT SRecipient LSET_
    "LDEL" -> Just $ CT SRecipient LDEL_
    "NKEY" -> Just $ CT SRecipient NKEY_
    "NDEL" -> Just $ CT SRecipient NDEL_
    "GET" -> Just $ CT SRecipient GET_
    "ACK" -> Just $ CT SRecipient ACK_
    "OFF" -> Just $ CT SRecipient OFF_
    "DEL" -> Just $ CT SRecipient DEL_
    "QUE" -> Just $ CT SRecipient QUE_
    "SKEY" -> Just $ CT SSender SKEY_
    "SEND" -> Just $ CT SSender SEND_
    "PING" -> Just $ CT SIdleClient PING_
    "LKEY" -> Just $ CT SSenderLink LKEY_
    "LGET" -> Just $ CT SSenderLink LGET_
    "PRXY" -> Just $ CT SProxiedClient PRXY_
    "PFWD" -> Just $ CT SProxiedClient PFWD_
    "RFWD" -> Just $ CT SProxyService RFWD_
    "NSUB" -> Just $ CT SNotifier NSUB_
    "NSUBS" -> Just $ CT SNotifierService NSUBS_
    _ -> Nothing

instance Encoding CmdTag where
  smpEncode (CT _ t) = smpEncode t
  smpP = messageTagP

instance PartyI p => ProtocolMsgTag (CommandTag p) where
  decodeTag s = decodeTag s >>= (\(CT _ t) -> checkParty' t)

instance Encoding BrokerMsgTag where
  smpEncode = \case
    IDS_ -> "IDS"
    LNK_ -> "LNK"
    SOK_ -> "SOK"
    SOKS_ -> "SOKS"
    MSG_ -> "MSG"
    NID_ -> "NID"
    NMSG_ -> "NMSG"
    PKEY_ -> "PKEY"
    RRES_ -> "RRES"
    PRES_ -> "PRES"
    END_ -> "END"
    ENDS_ -> "ENDS"
    DELD_ -> "DELD"
    INFO_ -> "INFO"
    OK_ -> "OK"
    ERR_ -> "ERR"
    PONG_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag BrokerMsgTag where
  decodeTag = \case
    "IDS" -> Just IDS_
    "LNK" -> Just LNK_
    "SOK" -> Just SOK_
    "SOKS" -> Just SOKS_
    "MSG" -> Just MSG_
    "NID" -> Just NID_
    "NMSG" -> Just NMSG_
    "PKEY" -> Just PKEY_
    "RRES" -> Just RRES_
    "PRES" -> Just PRES_
    "END" -> Just END_
    "ENDS" -> Just ENDS_
    "DELD" -> Just DELD_
    "INFO" -> Just INFO_
    "OK" -> Just OK_
    "ERR" -> Just ERR_
    "PONG" -> Just PONG_
    _ -> Nothing

-- | SMP message body format
data ClientMsgEnvelope = ClientMsgEnvelope
  { cmHeader :: PubHeader,
    cmNonce :: C.CbNonce,
    cmEncBody :: ByteString
  }
  deriving (Show)

data PubHeader = PubHeader
  { phVersion :: VersionSMPC,
    phE2ePubDhKey :: Maybe C.PublicKeyX25519
  }
  deriving (Show)

instance Encoding PubHeader where
  smpEncode (PubHeader v k) = smpEncode (v, k)
  smpP = PubHeader <$> smpP <*> smpP

instance Encoding ClientMsgEnvelope where
  smpEncode ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody} =
    smpEncode (cmHeader, cmNonce, Tail cmEncBody)
  smpP = do
    (cmHeader, cmNonce, Tail cmEncBody) <- smpP
    pure ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

data ClientMessage = ClientMessage PrivHeader ByteString

data PrivHeader
  = PHConfirmation C.APublicAuthKey
  | PHEmpty
  deriving (Show)

instance Encoding PrivHeader where
  smpEncode = \case
    PHConfirmation k -> "K" <> smpEncode k
    PHEmpty -> "_"
  smpP =
    A.anyChar >>= \case
      'K' -> PHConfirmation <$> smpP
      '_' -> pure PHEmpty
      _ -> fail "invalid PrivHeader"

instance Encoding ClientMessage where
  smpEncode (ClientMessage h msg) = smpEncode h <> msg
  smpP = ClientMessage <$> smpP <*> A.takeByteString

type SMPServer = ProtocolServer 'PSMP

pattern SMPServer :: NonEmpty TransportHost -> ServiceName -> C.KeyHash -> ProtocolServer 'PSMP
pattern SMPServer host port keyHash = ProtocolServer SPSMP host port keyHash

{-# COMPLETE SMPServer #-}

type SMPServerWithAuth = ProtoServerWithAuth 'PSMP

type NtfServer = ProtocolServer 'PNTF

pattern NtfServer :: NonEmpty TransportHost -> ServiceName -> C.KeyHash -> ProtocolServer 'PNTF
pattern NtfServer host port keyHash = ProtocolServer SPNTF host port keyHash

{-# COMPLETE NtfServer #-}

type NtfServerWithAuth = ProtoServerWithAuth 'PNTF

type XFTPServer = ProtocolServer 'PXFTP

pattern XFTPServer :: NonEmpty TransportHost -> ServiceName -> C.KeyHash -> ProtocolServer 'PXFTP
pattern XFTPServer host port keyHash = ProtocolServer SPXFTP host port keyHash

{-# COMPLETE XFTPServer #-}

type XFTPServerWithAuth = ProtoServerWithAuth 'PXFTP

sameSrvAddr' :: ProtoServerWithAuth p -> ProtoServerWithAuth p -> Bool
sameSrvAddr' (ProtoServerWithAuth srv _) (ProtoServerWithAuth srv' _) = sameSrvAddr srv srv'
{-# INLINE sameSrvAddr' #-}

sameSrvAddr :: ProtocolServer p -> ProtocolServer p -> Bool
sameSrvAddr ProtocolServer {host, port} ProtocolServer {host = h', port = p'} = host == h' && port == p'
{-# INLINE sameSrvAddr #-}

data ProtocolType = PSMP | PNTF | PXFTP
  deriving (Eq, Ord, Show)

instance StrEncoding ProtocolType where
  strEncode = \case
    PSMP -> "smp"
    PNTF -> "ntf"
    PXFTP -> "xftp"
  strP =
    A.takeTill (\c -> c == ':' || c == ' ') >>= \case
      "smp" -> pure PSMP
      "ntf" -> pure PNTF
      "xftp" -> pure PXFTP
      _ -> fail "bad ProtocolType"

data SProtocolType (p :: ProtocolType) where
  SPSMP :: SProtocolType 'PSMP
  SPNTF :: SProtocolType 'PNTF
  SPXFTP :: SProtocolType 'PXFTP

deriving instance Eq (SProtocolType p)

deriving instance Ord (SProtocolType p)

deriving instance Show (SProtocolType p)

data AProtocolType = forall p. ProtocolTypeI p => AProtocolType (SProtocolType p)

instance Eq AProtocolType where
  AProtocolType p == AProtocolType p' = isJust $ testEquality p p'

deriving instance Show AProtocolType

instance TestEquality SProtocolType where
  testEquality SPSMP SPSMP = Just Refl
  testEquality SPNTF SPNTF = Just Refl
  testEquality SPXFTP SPXFTP = Just Refl
  testEquality _ _ = Nothing

protocolType :: SProtocolType p -> ProtocolType
protocolType = \case
  SPSMP -> PSMP
  SPNTF -> PNTF
  SPXFTP -> PXFTP

aProtocolType :: ProtocolType -> AProtocolType
aProtocolType = \case
  PSMP -> AProtocolType SPSMP
  PNTF -> AProtocolType SPNTF
  PXFTP -> AProtocolType SPXFTP

instance ProtocolTypeI p => StrEncoding (SProtocolType p) where
  strEncode = strEncode . protocolType
  strP = (\(AProtocolType p) -> checkProtocolType p) <$?> strP

instance StrEncoding AProtocolType where
  strEncode (AProtocolType p) = strEncode p
  strP = aProtocolType <$> strP

instance ProtocolTypeI p => ToJSON (SProtocolType p) where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance ProtocolTypeI p => FromJSON (SProtocolType p) where
  parseJSON = strParseJSON "SProtocolType"

instance ToJSON AProtocolType where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON AProtocolType where
  parseJSON = strParseJSON "AProtocolType"

checkProtocolType :: forall t p p'. (ProtocolTypeI p, ProtocolTypeI p') => t p' -> Either String (t p)
checkProtocolType p = case testEquality (protocolTypeI @p) (protocolTypeI @p') of
  Just Refl -> Right p
  Nothing -> Left "bad ProtocolType"

class ProtocolTypeI (p :: ProtocolType) where
  protocolTypeI :: SProtocolType p

instance ProtocolTypeI 'PSMP where protocolTypeI = SPSMP

instance ProtocolTypeI 'PNTF where protocolTypeI = SPNTF

instance ProtocolTypeI 'PXFTP where protocolTypeI = SPXFTP

type family UserProtocol (p :: ProtocolType) :: Constraint where
  UserProtocol PSMP = ()
  UserProtocol PXFTP = ()
  UserProtocol a =
    (Int ~ Bool, TypeError (TE.Text "Servers for protocol " :<>: ShowType a :<>: TE.Text " cannot be configured by the users"))

userProtocol :: SProtocolType p -> Maybe (Dict (UserProtocol p))
userProtocol = \case
  SPSMP -> Just Dict
  SPXFTP -> Just Dict
  _ -> Nothing

-- | server location and transport key digest (hash).
data ProtocolServer p = ProtocolServer
  { scheme :: SProtocolType p,
    host :: NonEmpty TransportHost,
    port :: ServiceName,
    keyHash :: C.KeyHash
  }
  deriving (Eq, Ord, Show)

data AProtocolServer = forall p. ProtocolTypeI p => AProtocolServer (SProtocolType p) (ProtocolServer p)

instance ProtocolTypeI p => IsString (ProtocolServer p) where
  fromString = parseString strDecode

instance ProtocolTypeI p => Encoding (ProtocolServer p) where
  smpEncode ProtocolServer {host, port, keyHash} =
    smpEncode (host, port, keyHash)
  smpP = do
    (host, port, keyHash) <- smpP
    pure ProtocolServer {scheme = protocolTypeI @p, host, port, keyHash}

instance ProtocolTypeI p => StrEncoding (ProtocolServer p) where
  strEncode ProtocolServer {scheme, host, port, keyHash} =
    strEncodeServer scheme (strEncode host) port keyHash Nothing
  strP =
    serverStrP >>= \case
      (AProtocolServer _ srv, Nothing) -> either fail pure $ checkProtocolType srv
      _ -> fail "ProtocolServer with basic auth not allowed"

instance ProtocolTypeI p => ToJSON (ProtocolServer p) where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance ProtocolTypeI p => FromJSON (ProtocolServer p) where
  parseJSON = strParseJSON "ProtocolServer"

newtype BasicAuth = BasicAuth {unBasicAuth :: ByteString}
  deriving (Eq, Ord, Show)

instance IsString BasicAuth where fromString = BasicAuth . B.pack

instance Encoding BasicAuth where
  smpEncode (BasicAuth s) = smpEncode s
  smpP = basicAuth <$?> smpP

instance StrEncoding BasicAuth where
  strEncode (BasicAuth s) = s
  strP = basicAuth <$?> A.takeWhile1 (/= '@')

basicAuth :: ByteString -> Either String BasicAuth
basicAuth s
  | B.all valid s = Right $ BasicAuth s
  | otherwise = Left "invalid character in BasicAuth"
  where
    valid c = isPrint c && not (isSpace c) && c /= '@' && c /= ':' && c /= '/'

data ProtoServerWithAuth p = ProtoServerWithAuth {protoServer :: ProtocolServer p, serverBasicAuth :: Maybe BasicAuth}
  deriving (Eq, Ord, Show)

instance ProtocolTypeI p => IsString (ProtoServerWithAuth p) where
  fromString = parseString strDecode

data AProtoServerWithAuth = forall p. ProtocolTypeI p => AProtoServerWithAuth (SProtocolType p) (ProtoServerWithAuth p)

deriving instance Show AProtoServerWithAuth

instance ProtocolTypeI p => StrEncoding (ProtoServerWithAuth p) where
  strEncode (ProtoServerWithAuth ProtocolServer {scheme, host, port, keyHash} auth_) =
    strEncodeServer scheme (strEncode host) port keyHash auth_
  strP = (\(AProtoServerWithAuth _ srv) -> checkProtocolType srv) <$?> strP

instance StrEncoding AProtoServerWithAuth where
  strEncode (AProtoServerWithAuth _ srv) = strEncode srv
  strP =
    serverStrP >>= \(AProtocolServer p srv, auth) ->
      pure $ AProtoServerWithAuth p (ProtoServerWithAuth srv auth)

instance ProtocolTypeI p => ToJSON (ProtoServerWithAuth p) where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance ProtocolTypeI p => FromJSON (ProtoServerWithAuth p) where
  parseJSON = strParseJSON "ProtoServerWithAuth"

instance ToJSON AProtoServerWithAuth where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON AProtoServerWithAuth where
  parseJSON = strParseJSON "AProtoServerWithAuth"

noAuthSrv :: ProtocolServer p -> ProtoServerWithAuth p
noAuthSrv srv = ProtoServerWithAuth srv Nothing

legacyEncodeServer :: ProtocolServer p -> ByteString
legacyEncodeServer ProtocolServer {host, port, keyHash} =
  smpEncode (L.head host, port, keyHash)

legacyServerP :: forall p. ProtocolTypeI p => Parser (ProtocolServer p)
legacyServerP = do
  (h, port, keyHash) <- smpP
  pure ProtocolServer {scheme = protocolTypeI @p, host = [h], port, keyHash}

legacyStrEncodeServer :: ProtocolTypeI p => ProtocolServer p -> ByteString
legacyStrEncodeServer ProtocolServer {scheme, host, port, keyHash} =
  strEncodeServer scheme (strEncode $ L.head host) port keyHash Nothing

strEncodeServer :: ProtocolTypeI p => SProtocolType p -> ByteString -> ServiceName -> C.KeyHash -> Maybe BasicAuth -> ByteString
strEncodeServer scheme host port keyHash auth_ =
  strEncode scheme <> "://" <> strEncode keyHash <> maybe "" ((":" <>) . strEncode) auth_ <> "@" <> host <> portStr
  where
    portStr = B.pack $ if null port then "" else ':' : port

serverStrP :: Parser (AProtocolServer, Maybe BasicAuth)
serverStrP = do
  scheme <- strP <* "://"
  keyHash <- strP
  auth_ <- optional $ A.char ':' *> strP
  TransportHosts host <- A.char '@' *> strP
  port <- portP <|> pure ""
  pure $ case scheme of
    AProtocolType s -> (AProtocolServer s $ ProtocolServer {scheme = s, host, port, keyHash}, auth_)
  where
    portP = show <$> (A.char ':' *> (A.decimal :: Parser Int))

-- | Transmission correlation ID.
newtype CorrId = CorrId {bs :: ByteString}
  deriving (Eq, Ord, Show)
  deriving newtype (Encoding)

pattern NoCorrId :: CorrId
pattern NoCorrId = CorrId ""

instance IsString CorrId where
  fromString = CorrId . fromString
  {-# INLINE fromString #-}

instance StrEncoding CorrId where
  strEncode (CorrId cId) = strEncode cId
  strDecode s = CorrId <$> strDecode s
  strP = CorrId <$> strP

instance ToJSON CorrId where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON CorrId where
  parseJSON = strParseJSON "CorrId"

-- | Queue IDs and keys
data QueueIdsKeys = QIK
  { rcvId :: RecipientId,
    sndId :: SenderId,
    rcvPublicDhKey :: RcvPublicDhKey,
    queueMode :: Maybe QueueMode, -- TODO remove Maybe when min version is 9 (sndAuthKeySMPVersion)
    linkId :: Maybe LinkId,
    serviceId :: Maybe ServiceId,
    serverNtfCreds :: Maybe ServerNtfCreds
  }
  deriving (Eq, Show)

data ServerNtfCreds = ServerNtfCreds NotifierId RcvNtfPublicDhKey
  deriving (Eq, Show)

instance Encoding ServerNtfCreds where
  smpEncode (ServerNtfCreds nId dhKey) = smpEncode (nId, dhKey)
  smpP = ServerNtfCreds <$> smpP <*> smpP

-- | Recipient's private key used by the recipient to authorize (v6: sign, v7: encrypt hash) SMP commands.
--
-- Only used by SMP agent, kept here so its definition is close to respective public key.
type RcvPrivateAuthKey = C.APrivateAuthKey

-- | Recipient's public key used by SMP server to verify authorization of SMP commands.
type RcvPublicAuthKey = C.APublicAuthKey

-- | Public key used for DH exchange to encrypt message bodies from server to recipient
type RcvPublicDhKey = C.PublicKeyX25519

-- | DH Secret used to encrypt message bodies from server to recipient
type RcvDhSecret = C.DhSecretX25519

-- | Sender's private key used by the recipient to authorize (v6: sign, v7: encrypt hash) SMP commands.
--
-- Only used by SMP agent, kept here so its definition is close to respective public key.
type SndPrivateAuthKey = C.APrivateAuthKey

-- | Sender's public key used by SMP server to verify authorization of SMP commands.
type SndPublicAuthKey = C.APublicAuthKey

-- | Private key used by push notifications server to authorize (sign or encrypt hash) NSUB command.
type NtfPrivateAuthKey = C.APrivateAuthKey

-- | Public key used by SMP server to verify authorization of NSUB command sent by push notifications server.
type NtfPublicAuthKey = C.APublicAuthKey

-- | Public key used for DH exchange to encrypt notification metadata from server to recipient
type RcvNtfPublicDhKey = C.PublicKeyX25519

-- | DH Secret used to encrypt notification metadata from server to recipient
type RcvNtfDhSecret = C.DhSecretX25519

-- | SMP message server ID.
type MsgId = ByteString

-- | SMP message body.
type MsgBody = ByteString

data ProtocolErrorType = PECmdSyntax | PECmdUnknown | PESession | PEBlock

-- | Type for protocol errors.
data ErrorType
  = -- | incorrect block format, encoding or signature size
    BLOCK
  | -- | incorrect SMP session ID (TLS Finished message / tls-unique binding RFC5929)
    SESSION
  | -- | SMP command is unknown or has invalid syntax
    CMD {cmdErr :: CommandError}
  | -- | error from proxied relay
    PROXY {proxyErr :: ProxyError}
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | command with the entity that was blocked
    BLOCKED {blockInfo :: BlockingInfo}
  | -- | service signature is not allowed for command or session; service command is sent not in service session
    SERVICE
  | -- | encryption/decryption error in proxy protocol
    CRYPTO
  | -- | SMP queue capacity is exceeded on the server
    QUOTA
  | -- | SMP server storage error
    STORE {storeErr :: Text}
  | -- | ACK command is sent without message to be acknowledged
    NO_MSG
  | -- | sent message is too large (> maxMessageLength = 16088 bytes)
    LARGE_MSG
  | -- | relay public key is expired
    EXPIRED
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- not part of SMP protocol, used internally
  deriving (Eq, Show)

instance StrEncoding ErrorType where
  strEncode = \case
    BLOCK -> "BLOCK"
    SESSION -> "SESSION"
    CMD e -> "CMD " <> bshow e
    PROXY e -> "PROXY " <> strEncode e
    AUTH -> "AUTH"
    BLOCKED info -> "BLOCKED " <> strEncode info
    SERVICE -> "SERVICE"
    CRYPTO -> "CRYPTO"
    QUOTA -> "QUOTA"
    STORE e -> "STORE " <> encodeUtf8 e
    NO_MSG -> "NO_MSG"
    LARGE_MSG -> "LARGE_MSG"
    EXPIRED -> "EXPIRED"
    INTERNAL -> "INTERNAL"
    DUPLICATE_ -> "DUPLICATE_"
  strP =
    A.choice
      [ "BLOCK" $> BLOCK,
        "SESSION" $> SESSION,
        "CMD " *> (CMD <$> parseRead1),
        "PROXY " *> (PROXY <$> strP),
        "AUTH" $> AUTH,
        "BLOCKED " *> strP,
        "SERVICE" $> SERVICE,
        "CRYPTO" $> CRYPTO,
        "QUOTA" $> QUOTA,
        "STORE " *> (STORE . safeDecodeUtf8 <$> A.takeByteString),
        "NO_MSG" $> NO_MSG,
        "LARGE_MSG" $> LARGE_MSG,
        "EXPIRED" $> EXPIRED,
        "INTERNAL" $> INTERNAL,
        "DUPLICATE_" $> DUPLICATE_
      ]

-- | SMP command error type.
data CommandError
  = -- | unknown command
    UNKNOWN
  | -- | error parsing command
    SYNTAX
  | -- | command is not allowed (bad service role, or SUB/GET used with the same queue in the same TCP session)
    PROHIBITED
  | -- | transmission has no required credentials (signature or queue ID)
    NO_AUTH
  | -- | transmission has credentials that are not allowed for this command
    HAS_AUTH
  | -- | transmission has no required entity ID (e.g. SMP queue)
    NO_ENTITY
  deriving (Eq, Read, Show)

data ProxyError
  = -- | Correctly parsed SMP server ERR response.
    -- This error is forwarded to the agent client as AgentErrorType `ERR PROXY PROTOCOL err`.
    PROTOCOL {protocolErr :: ErrorType}
  | -- | destination server error
    BROKER {brokerErr :: BrokerErrorType}
  | -- | basic auth provided to proxy is invalid
    BASIC_AUTH
  | -- no destination server error
    NO_SESSION
  deriving (Eq, Show)

-- | SMP server errors.
data BrokerErrorType
  = -- | invalid server response (failed to parse)
    RESPONSE {respErr :: String}
  | -- | unexpected response
    UNEXPECTED {respErr :: String}
  | -- | network error
    NETWORK
  | -- | no compatible server host (e.g. onion when public is required, or vice versa)
    HOST
  | -- | service unavailable client-side - used in agent errors
    NO_SERVICE
  | -- | handshake or other transport error
    TRANSPORT {transportErr :: TransportError}
  | -- | command response timeout
    TIMEOUT
  deriving (Eq, Read, Show, Exception)

data BlockingInfo = BlockingInfo
  { reason :: BlockingReason
  }
  deriving (Eq, Show)

data BlockingReason = BRSpam | BRContent
  deriving (Eq, Show)

instance StrEncoding BlockingInfo where
  strEncode BlockingInfo {reason} = "reason=" <> strEncode reason
  strP = do
    reason <- "reason=" *> strP
    pure BlockingInfo {reason}

instance Encoding BlockingInfo where
  smpEncode = strEncode
  smpP = strP

instance StrEncoding BlockingReason where
  strEncode = \case
    BRSpam -> "spam"
    BRContent -> "content"
  strP = "spam" $> BRSpam <|> "content" $> BRContent

instance ToJSON BlockingReason where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON BlockingReason where
  parseJSON = strParseJSON "BlockingReason"

-- | SMP transmission parser.
transmissionP :: THandleParams v p -> Parser RawTransmission
transmissionP THandleParams {sessionId, implySessId, serviceAuth} = do
  authenticator <- smpP
  serviceSig <- if serviceAuth && not (B.null authenticator) then smpP else pure Nothing
  authorized <- A.takeByteString
  either fail pure $ parseAll (trn authenticator serviceSig authorized) authorized
  where
    trn authenticator serviceSig authorized = do
      sessId <- if implySessId then pure "" else smpP
      let authorized' = if implySessId then smpEncode sessionId <> authorized else authorized
      corrId <- smpP
      entityId <- smpP
      command <- A.takeByteString
      pure RawTransmission {authenticator, serviceSig, authorized = authorized', sessId, corrId, entityId, command}

class (ProtocolTypeI (ProtoType msg), ProtocolEncoding v err msg, ProtocolEncoding v err (ProtoCommand msg), Show err, Show msg) => Protocol v err msg | msg -> v, msg -> err where
  type ProtoCommand msg = cmd | cmd -> msg
  type ProtoType msg = (sch :: ProtocolType) | sch -> msg
  protocolClientHandshake :: Transport c => c 'TClient -> Maybe C.KeyPairX25519 -> C.KeyHash -> VersionRange v -> Bool -> Maybe (ServiceCredentials, C.KeyPairEd25519) -> ExceptT TransportError IO (THandle v c 'TClient)
  useServiceAuth :: ProtoCommand msg -> Bool
  protocolPing :: ProtoCommand msg
  protocolError :: msg -> Maybe err

type ProtoServer msg = ProtocolServer (ProtoType msg)

instance Protocol SMPVersion ErrorType BrokerMsg where
  type ProtoCommand BrokerMsg = Cmd
  type ProtoType BrokerMsg = 'PSMP
  protocolClientHandshake = smpClientHandshake
  {-# INLINE protocolClientHandshake #-}
  useServiceAuth = \case
    Cmd _ (NEW _) -> True
    Cmd _ SUB -> True
    Cmd _ NSUB -> True
    _ -> False
  {-# INLINE useServiceAuth #-}
  protocolPing = Cmd SIdleClient PING
  {-# INLINE protocolPing #-}
  protocolError = \case
    ERR e -> Just e
    _ -> Nothing
  {-# INLINE protocolError #-}

class ProtocolMsgTag (Tag msg) => ProtocolEncoding v err msg | msg -> err, msg -> v where
  type Tag msg
  encodeProtocol :: Version v -> msg -> ByteString
  protocolP :: Version v -> Tag msg -> Parser msg
  fromProtocolError :: ProtocolErrorType -> err
  checkCredentials :: Maybe TAuthorizations -> EntityId -> msg -> Either err msg

instance PartyI p => ProtocolEncoding SMPVersion ErrorType (Command p) where
  type Tag (Command p) = CommandTag p
  encodeProtocol v = \case
    NEW NewQueueReq {rcvAuthKey = rKey, rcvDhKey = dhKey, auth_, subMode, queueReqData, ntfCreds}
      | v >= newNtfCredsSMPVersion -> new <> e (auth_, subMode, queueReqData, ntfCreds)
      | v >= shortLinksSMPVersion -> new <> e (auth_, subMode, queueReqData)
      | v >= sndAuthKeySMPVersion -> new <> e (auth_, subMode, senderCanSecure (queueReqMode <$> queueReqData))
      | otherwise -> new <> auth <> e subMode
      where
        new = e (NEW_, ' ', rKey, dhKey)
        auth = maybe "" (e . ('A',)) auth_
    SUB -> e SUB_
    SUBS -> e SUBS_
    KEY k -> e (KEY_, ' ', k)
    RKEY ks -> e (RKEY_, ' ', ks)
    LSET lnkId d -> e (LSET_, ' ', lnkId, d)
    LDEL -> e LDEL_
    NKEY k dhKey -> e (NKEY_, ' ', k, dhKey)
    NDEL -> e NDEL_
    GET -> e GET_
    ACK msgId -> e (ACK_, ' ', msgId)
    OFF -> e OFF_
    DEL -> e DEL_
    QUE -> e QUE_
    SKEY k -> e (SKEY_, ' ', k)
    SEND flags msg -> e (SEND_, ' ', flags, ' ', Tail msg)
    PING -> e PING_
    NSUB -> e NSUB_
    NSUBS -> e NSUBS_
    LKEY k -> e (LKEY_, ' ', k)
    LGET -> e LGET_
    PRXY host auth_ -> e (PRXY_, ' ', host, auth_)
    PFWD fwdV pubKey (EncTransmission s) -> e (PFWD_, ' ', fwdV, pubKey, Tail s)
    RFWD (EncFwdTransmission s) -> e (RFWD_, ' ', Tail s)
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v tag = (\(Cmd _ c) -> checkParty c) <$?> protocolP v (CT (sParty @p) tag)

  fromProtocolError = fromProtocolError @SMPVersion @ErrorType @BrokerMsg
  {-# INLINE fromProtocolError #-}

  checkCredentials auth (EntityId entId) cmd = case cmd of
    -- NEW must have signature but NOT queue ID
    NEW {}
      | isNothing auth -> Left $ CMD NO_AUTH
      | not (B.null entId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    -- SEND must have queue ID, signature is not always required
    SEND {}
      | B.null entId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd
    LGET -> entityCmd
    PING -> noAuthCmd
    PRXY {} -> noAuthCmd
    PFWD {} -> entityCmd
    RFWD _ -> noAuthCmd
    SUB -> serviceCmd
    NSUB -> serviceCmd
    -- other client commands must have both signature and queue ID
    _
      | isNothing auth || B.null entId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd
    where
      -- command must not have entity ID (queue or session ID) or signature
      noAuthCmd :: Either ErrorType (Command p)
      noAuthCmd
        | isNothing auth && B.null entId = Right cmd
        | otherwise = Left $ CMD HAS_AUTH
      entityCmd :: Either ErrorType (Command p)
      entityCmd
        | B.null entId = Left $ CMD NO_ENTITY
        | isNothing auth = Right cmd
        | otherwise = Left $ CMD HAS_AUTH
      serviceCmd :: Either ErrorType (Command p)
      serviceCmd
        | isNothing auth || B.null entId = Left $ CMD NO_AUTH
        | otherwise = Right cmd

instance ProtocolEncoding SMPVersion ErrorType Cmd where
  type Tag Cmd = CmdTag
  encodeProtocol v (Cmd _ c) = encodeProtocol v c
  {-# INLINE encodeProtocol #-}

  protocolP v = \case
    CT SCreator NEW_ -> Cmd SCreator <$> newCmd
      where
        newCmd
          | v >= newNtfCredsSMPVersion = new smpP smpP smpP
          | v >= shortLinksSMPVersion = new smpP smpP nothing
          | v >= sndAuthKeySMPVersion = new smpP (qReq <$> smpP) nothing
          | otherwise = new auth nothing nothing
          where
            nothing = pure Nothing
            new p1 p2 p3 = NEW <$> do
              rcvAuthKey <- _smpP
              rcvDhKey <- smpP
              auth_ <- p1
              subMode <- smpP
              queueReqData <- p2
              ntfCreds <- p3
              pure NewQueueReq {rcvAuthKey, rcvDhKey, auth_, subMode, queueReqData, ntfCreds}
            auth = optional (A.char 'A' *> smpP)
            qReq sndSecure = Just $ if sndSecure then QRMessaging Nothing else QRContact Nothing
    CT SRecipient tag ->
      Cmd SRecipient <$> case tag of
        SUB_ -> pure SUB
        KEY_ -> KEY <$> _smpP
        RKEY_ -> RKEY <$> _smpP
        LSET_ -> LSET <$> _smpP <*> smpP
        LDEL_ -> pure LDEL
        NKEY_ -> NKEY <$> _smpP <*> smpP
        NDEL_ -> pure NDEL
        GET_ -> pure GET
        ACK_ -> ACK <$> _smpP
        OFF_ -> pure OFF
        DEL_ -> pure DEL
        QUE_ -> pure QUE
    CT SRecipientService SUBS_ -> pure $ Cmd SRecipientService SUBS
    CT SSender tag ->
      Cmd SSender <$> case tag of
        SKEY_ -> SKEY <$> _smpP
        SEND_ -> SEND <$> _smpP <*> (unTail <$> _smpP)
    CT SIdleClient PING_ -> pure $ Cmd SIdleClient PING
    CT SProxyService RFWD_ ->
      Cmd SProxyService . RFWD . EncFwdTransmission . unTail <$> _smpP
    CT SSenderLink tag ->
      Cmd SSenderLink <$> case tag of
        LKEY_ -> LKEY <$> _smpP
        LGET_ -> pure LGET
    CT SProxiedClient tag ->
      Cmd SProxiedClient <$> case tag of
        PFWD_ -> PFWD <$> _smpP <*> smpP <*> (EncTransmission . unTail <$> smpP)
        PRXY_ -> PRXY <$> _smpP <*> smpP
    CT SNotifier NSUB_ -> pure $ Cmd SNotifier NSUB
    CT SNotifierService NSUBS_ -> pure $ Cmd SNotifierService NSUBS

  fromProtocolError = fromProtocolError @SMPVersion @ErrorType @BrokerMsg
  {-# INLINE fromProtocolError #-}

  checkCredentials tAuth entId (Cmd p c) = Cmd p <$> checkCredentials tAuth entId c
  {-# INLINE checkCredentials #-}

instance ProtocolEncoding SMPVersion ErrorType BrokerMsg where
  type Tag BrokerMsg = BrokerMsgTag
  encodeProtocol v = \case
    IDS QIK {rcvId, sndId, rcvPublicDhKey = srvDh, queueMode, linkId, serviceId, serverNtfCreds}
      | v >= newNtfCredsSMPVersion -> ids <> e queueMode <> e linkId <> e serviceId <> e serverNtfCreds
      | v >= serviceCertsSMPVersion -> ids <> e queueMode <> e linkId <> e serviceId
      | v >= shortLinksSMPVersion -> ids <> e queueMode <> e linkId
      | v >= sndAuthKeySMPVersion -> ids <> e (senderCanSecure queueMode)
      | otherwise -> ids
      where
        ids = e (IDS_, ' ', rcvId, sndId, srvDh)
    LNK sId d -> e (LNK_, ' ', sId, d)
    SOK serviceId_
      | v >= serviceCertsSMPVersion -> e (SOK_, ' ', serviceId_)
      | otherwise -> e OK_ -- won't happen, the association with the service requires v >= serviceCertsSMPVersion
    SOKS n -> e (SOKS_, ' ', n)
    MSG RcvMessage {msgId, msgBody = EncRcvMsgBody body} ->
      e (MSG_, ' ', msgId, Tail body)
    NID nId srvNtfDh -> e (NID_, ' ', nId, srvNtfDh)
    NMSG nmsgNonce encNMsgMeta -> e (NMSG_, ' ', nmsgNonce, encNMsgMeta)
    PKEY sid vr certKey -> e (PKEY_, ' ', sid, vr, certKey)
    RRES (EncFwdResponse encBlock) -> e (RRES_, ' ', Tail encBlock)
    PRES (EncResponse encBlock) -> e (PRES_, ' ', Tail encBlock)
    END -> e END_
    ENDS n -> e (ENDS_, ' ', n)
    DELD
      | v >= deletedEventSMPVersion -> e DELD_
      | otherwise -> e END_
    INFO info -> e (INFO_, ' ', info)
    OK -> e OK_
    ERR err -> case err of
      BLOCKED _ | v < blockedEntitySMPVersion -> e (ERR_, ' ', AUTH)
      _ -> e (ERR_, ' ', err)
    PONG -> e PONG_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v = \case
    MSG_ -> do
      msgId <- _smpP
      MSG . RcvMessage msgId <$> bodyP
      where
        bodyP = EncRcvMsgBody . unTail <$> smpP
    IDS_
      | v >= newNtfCredsSMPVersion -> ids smpP smpP smpP smpP
      | v >= serviceCertsSMPVersion -> ids smpP smpP smpP nothing
      | v >= shortLinksSMPVersion -> ids smpP smpP nothing nothing
      | v >= sndAuthKeySMPVersion -> ids (qm <$> smpP) nothing nothing nothing
      | otherwise -> ids nothing nothing nothing nothing
      where
        qm sndSecure = Just $ if sndSecure then QMMessaging else QMContact
        nothing = pure Nothing
        ids p1 p2 p3 p4 = do
          rcvId <- _smpP
          sndId <- smpP
          rcvPublicDhKey <- smpP
          queueMode <- p1
          linkId <- p2
          serviceId <- p3
          serverNtfCreds <- p4
          pure $ IDS QIK {rcvId, sndId, rcvPublicDhKey, queueMode, linkId, serviceId, serverNtfCreds}
    LNK_ -> LNK <$> _smpP <*> smpP
    SOK_ -> SOK <$> _smpP
    SOKS_ -> SOKS <$> _smpP
    NID_ -> NID <$> _smpP <*> smpP
    NMSG_ -> NMSG <$> _smpP <*> smpP
    PKEY_ -> PKEY <$> _smpP <*> smpP <*> smpP
    RRES_ -> RRES <$> (EncFwdResponse . unTail <$> _smpP)
    PRES_ -> PRES <$> (EncResponse . unTail <$> _smpP)
    END_ -> pure END
    ENDS_ -> ENDS <$> _smpP
    DELD_ -> pure DELD
    INFO_ -> INFO <$> _smpP
    OK_ -> pure OK
    ERR_ -> ERR <$> _smpP
    PONG_ -> pure PONG

  fromProtocolError = \case
    PECmdSyntax -> CMD SYNTAX
    PECmdUnknown -> CMD UNKNOWN
    PESession -> SESSION
    PEBlock -> BLOCK
  {-# INLINE fromProtocolError #-}

  checkCredentials _ (EntityId entId) cmd = case cmd of
    -- IDS response should not have queue ID
    IDS _ -> Right cmd
    -- ERR response does not always have queue ID
    ERR _ -> Right cmd
    -- PONG response must not have queue ID
    PONG -> noEntityMsg
    PKEY {} -> noEntityMsg
    RRES _ -> noEntityMsg
    -- other broker responses must have queue ID
    _
      | B.null entId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd
    where
      noEntityMsg :: Either ErrorType BrokerMsg
      noEntityMsg
        | B.null entId = Right cmd
        | otherwise = Left $ CMD HAS_AUTH

-- | Parse SMP protocol commands and broker messages
parseProtocol :: forall v err msg. ProtocolEncoding v err msg => Version v -> ByteString -> Either err msg
parseProtocol v s =
  let (tag, params) = B.break (== ' ') s
   in case decodeTag tag of
        Just cmd -> parse (protocolP v cmd) (fromProtocolError @v @err @msg $ PECmdSyntax) params
        Nothing -> Left $ fromProtocolError @v @err @msg $ PECmdUnknown

checkParty :: forall t p p'. (PartyI p, PartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sParty @p) (sParty @p') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkParty' :: forall t p p'. (PartyI p, PartyI p') => t p' -> Maybe (t p)
checkParty' = eitherToMaybe . checkParty

instance Encoding ErrorType where
  smpEncode = \case
    BLOCK -> "BLOCK"
    SESSION -> "SESSION"
    CMD err -> "CMD " <> smpEncode err
    PROXY err -> "PROXY " <> smpEncode err
    AUTH -> "AUTH"
    BLOCKED info -> "BLOCKED " <> smpEncode info
    SERVICE -> "SERVICE"
    CRYPTO -> "CRYPTO"
    QUOTA -> "QUOTA"
    STORE err -> "STORE " <> encodeUtf8 err
    EXPIRED -> "EXPIRED"
    NO_MSG -> "NO_MSG"
    LARGE_MSG -> "LARGE_MSG"
    INTERNAL -> "INTERNAL"
    DUPLICATE_ -> "DUPLICATE_"

  smpP =
    A.takeTill (== ' ') >>= \case
      "BLOCK" -> pure BLOCK
      "SESSION" -> pure SESSION
      "CMD" -> CMD <$> _smpP
      "PROXY" -> PROXY <$> _smpP
      "AUTH" -> pure AUTH
      "BLOCKED" -> BLOCKED <$> _smpP
      "SERVICE" -> pure SERVICE
      "CRYPTO" -> pure CRYPTO
      "QUOTA" -> pure QUOTA
      "STORE" -> STORE . safeDecodeUtf8 <$> (A.space *> A.takeByteString)
      "EXPIRED" -> pure EXPIRED
      "NO_MSG" -> pure NO_MSG
      "LARGE_MSG" -> pure LARGE_MSG
      "INTERNAL" -> pure INTERNAL
      "DUPLICATE_" -> pure DUPLICATE_
      _ -> fail "bad ErrorType"

instance Encoding CommandError where
  smpEncode e = case e of
    UNKNOWN -> "UNKNOWN"
    SYNTAX -> "SYNTAX"
    PROHIBITED -> "PROHIBITED"
    NO_AUTH -> "NO_AUTH"
    HAS_AUTH -> "HAS_AUTH"
    NO_ENTITY -> "NO_ENTITY"
  smpP =
    A.takeTill (== ' ') >>= \case
      "UNKNOWN" -> pure UNKNOWN
      "SYNTAX" -> pure SYNTAX
      "PROHIBITED" -> pure PROHIBITED
      "NO_AUTH" -> pure NO_AUTH
      "HAS_AUTH" -> pure HAS_AUTH
      "NO_ENTITY" -> pure NO_ENTITY
      "NO_QUEUE" -> pure NO_ENTITY -- for backward compatibility
      _ -> fail "bad CommandError"

instance Encoding ProxyError where
  smpEncode = \case
    PROTOCOL e -> "PROTOCOL " <> smpEncode e
    BROKER e -> "BROKER " <> smpEncode e
    BASIC_AUTH -> "BASIC_AUTH"
    NO_SESSION -> "NO_SESSION"
  smpP =
    A.takeTill (== ' ') >>= \case
      "PROTOCOL" -> PROTOCOL <$> _smpP
      "BROKER" -> BROKER <$> _smpP
      "BASIC_AUTH" -> pure BASIC_AUTH
      "NO_SESSION" -> pure NO_SESSION
      _ -> fail "bad ProxyError"

instance StrEncoding ProxyError where
  strEncode = \case
    PROTOCOL e -> "PROTOCOL " <> strEncode e
    BROKER e -> "BROKER " <> strEncode e
    BASIC_AUTH -> "BASIC_AUTH"
    NO_SESSION -> "NO_SESSION"
  strP =
    A.takeTill (== ' ') >>= \case
      "PROTOCOL" -> PROTOCOL <$> _strP
      "BROKER" -> BROKER <$> _strP
      "BASIC_AUTH" -> pure BASIC_AUTH
      "NO_SESSION" -> pure NO_SESSION
      _ -> fail "bad ProxyError"

instance Encoding BrokerErrorType where
  smpEncode = \case
    RESPONSE e -> "RESPONSE " <> smpEncode e
    UNEXPECTED e -> "UNEXPECTED " <> smpEncode e
    TRANSPORT e -> "TRANSPORT " <> smpEncode e
    NETWORK -> "NETWORK"
    TIMEOUT -> "TIMEOUT"
    HOST -> "HOST"
    NO_SERVICE -> "NO_SERVICE"
  smpP =
    A.takeTill (== ' ') >>= \case
      "RESPONSE" -> RESPONSE <$> _smpP
      "UNEXPECTED" -> UNEXPECTED <$> _smpP
      "TRANSPORT" -> TRANSPORT <$> _smpP
      "NETWORK" -> pure NETWORK
      "TIMEOUT" -> pure TIMEOUT
      "HOST" -> pure HOST
      "NO_SERVICE" -> pure NO_SERVICE
      _ -> fail "bad BrokerErrorType"

instance StrEncoding BrokerErrorType where
  strEncode = \case
    RESPONSE e -> "RESPONSE " <> encodeUtf8 (T.pack e)
    UNEXPECTED e -> "UNEXPECTED " <> encodeUtf8 (T.pack e)
    TRANSPORT e -> "TRANSPORT " <> smpEncode e
    NETWORK -> "NETWORK"
    TIMEOUT -> "TIMEOUT"
    HOST -> "HOST"
    NO_SERVICE -> "NO_SERVICE"
  strP =
    A.takeTill (== ' ') >>= \case
      "RESPONSE" -> RESPONSE <$> _textP
      "UNEXPECTED" -> UNEXPECTED <$> _textP
      "TRANSPORT" -> TRANSPORT <$> _smpP
      "NETWORK" -> pure NETWORK
      "TIMEOUT" -> pure TIMEOUT
      "HOST" -> pure HOST
      "NO_SERVICE" -> pure NO_SERVICE
      _ -> fail "bad BrokerErrorType"
    where
      _textP = A.space *> (T.unpack . safeDecodeUtf8 <$> A.takeByteString)

-- | Send signed SMP transmission to TCP transport.
tPut :: Transport c => THandle v c p -> NonEmpty (Either TransportError SentRawTransmission) -> IO [Either TransportError ()]
tPut th@THandle {params} = fmap concat . mapM tPutBatch . batchTransmissions params
  where
    tPutBatch :: TransportBatch () -> IO [Either TransportError ()]
    tPutBatch = \case
      TBError e _ -> [Left e] <$ putStrLn "tPut error: large message"
      TBTransmissions s n _ -> replicate n <$> tPutLog th s
      TBTransmission s _ -> (: []) <$> tPutLog th s

tPutLog :: Transport c => THandle v c p -> ByteString -> IO (Either TransportError ())
tPutLog th s = do
  r <- tPutBlock th s
  case r of
    Left e -> putStrLn ("tPut error: " <> show e)
    _ -> pure ()
  pure r

-- ByteString in TBTransmissions includes byte with transmissions count
data TransportBatch r = TBTransmissions ByteString Int [r] | TBTransmission ByteString r | TBError TransportError r

batchTransmissions :: THandleParams v p -> NonEmpty (Either TransportError SentRawTransmission) -> [TransportBatch ()]
batchTransmissions params = batchTransmissions' params . L.map (,())

-- | encodes and batches transmissions into blocks
batchTransmissions' :: forall v p r. THandleParams v p -> NonEmpty (Either TransportError SentRawTransmission, r) -> [TransportBatch r]
batchTransmissions' THandleParams {batch, blockSize = bSize, serviceAuth} ts
  | batch = batchTransmissions_ bSize $ L.map (first $ fmap $ tEncodeForBatch serviceAuth) ts
  | otherwise = map mkBatch1 $ L.toList ts
  where
    mkBatch1 :: (Either TransportError SentRawTransmission, r) -> TransportBatch r
    mkBatch1 (t_, r) = case t_ of
      Left e -> TBError e r
      Right t
        -- 2 bytes are reserved for pad size
        | B.length s <= bSize - 2 -> TBTransmission s r
        | otherwise -> TBError TELargeMsg r
        where
          s = tEncode serviceAuth t

-- | Pack encoded transmissions into batches
batchTransmissions_ :: Int -> NonEmpty (Either TransportError ByteString, r) -> [TransportBatch r]
batchTransmissions_ bSize = addBatch . foldr addTransmission ([], 0, 0, [], [])
  where
    -- 19 = 2 bytes reserved for pad size + 1 for transmission count + 16 auth tag from block encryption
    bSize' = bSize - 19
    addTransmission :: (Either TransportError ByteString, r) -> ([TransportBatch r], Int, Int, [ByteString], [r]) -> ([TransportBatch r], Int, Int, [ByteString], [r])
    addTransmission (t_, r) acc@(bs, !len, !n, ss, rs) = case t_ of
      Left e -> (TBError e r : addBatch acc, 0, 0, [], [])
      Right s
        | len' <= bSize' && n < 255 -> (bs, len', 1 + n, s : ss, r : rs)
        | sLen <= bSize' -> (addBatch acc, sLen, 1, [s], [r])
        | otherwise -> (TBError TELargeMsg r : addBatch acc, 0, 0, [], [])
        where
          sLen = B.length s
          len' = len + sLen
    addBatch :: ([TransportBatch r], Int, Int, [ByteString], [r]) -> [TransportBatch r]
    addBatch (bs, _len, n, ss, rs) = if n == 0 then bs else TBTransmissions b n rs : bs
      where
        b = B.concat $ B.singleton (lenEncode n) : ss

tEncode :: Bool -> SentRawTransmission -> ByteString
tEncode serviceAuth (auth, t) = tEncodeAuth serviceAuth auth <> t
{-# INLINE tEncode #-}

tEncodeForBatch :: Bool -> SentRawTransmission -> ByteString
tEncodeForBatch serviceAuth = smpEncode . Large . tEncode serviceAuth
{-# INLINE tEncodeForBatch #-}

tEncodeBatch1 :: Bool -> SentRawTransmission -> ByteString
tEncodeBatch1 serviceAuth t = lenEncode 1 `B.cons` tEncodeForBatch serviceAuth t
{-# INLINE tEncodeBatch1 #-}

-- tForAuth is lazy to avoid computing it when there is no key to sign
data TransmissionForAuth = TransmissionForAuth {tForAuth :: ~ByteString, tToSend :: ByteString}

encodeTransmissionForAuth :: ProtocolEncoding v e c => THandleParams v p -> Transmission c -> TransmissionForAuth
encodeTransmissionForAuth THandleParams {thVersion = v, sessionId, implySessId} t =
  TransmissionForAuth {tForAuth, tToSend = if implySessId then t' else tForAuth}
  where
    tForAuth = smpEncode sessionId <> t'
    t' = encodeTransmission_ v t
{-# INLINE encodeTransmissionForAuth #-}

encodeTransmission :: ProtocolEncoding v e c => THandleParams v p -> Transmission c -> ByteString
encodeTransmission THandleParams {thVersion = v, sessionId, implySessId} t =
  if implySessId then t' else smpEncode sessionId <> t'
  where
    t' = encodeTransmission_ v t
{-# INLINE encodeTransmission #-}

encodeTransmission_ :: ProtocolEncoding v e c => Version v -> Transmission c -> ByteString
encodeTransmission_ v (CorrId corrId, queueId, command) =
  smpEncode (corrId, queueId) <> encodeProtocol v command
{-# INLINE encodeTransmission_ #-}

-- | Receive and parse transmission from the TCP transport (ignoring any trailing padding).
tGetParse :: Transport c => THandle v c p -> IO (NonEmpty (Either TransportError RawTransmission))
tGetParse th@THandle {params} = eitherList (tParse params) <$> tGetBlock th
{-# INLINE tGetParse #-}

tParse :: THandleParams v p -> ByteString -> NonEmpty (Either TransportError RawTransmission)
tParse thParams@THandleParams {batch} s
  | batch = eitherList (L.map (\(Large t) -> tParse1 t)) ts
  | otherwise = [tParse1 s]
  where
    tParse1 = parse (transmissionP thParams) TEBadBlock
    ts = parse smpP TEBadBlock s

eitherList :: (a -> NonEmpty (Either e b)) -> Either e a -> NonEmpty (Either e b)
eitherList = either (\e -> [Left e])

-- | Receive server transmissions
tGetServer :: (ProtocolEncoding v err cmd, Transport c) => THandle v c 'TServer -> IO (NonEmpty (SignedTransmissionOrError err cmd))
tGetServer = tGet tDecodeServer
{-# INLINE tGetServer #-}

-- | Receive client transmissions
tGetClient :: (ProtocolEncoding v err cmd, Transport c) => THandle v c 'TClient -> IO (NonEmpty (Transmission (Either err cmd)))
tGetClient = tGet tDecodeClient
{-# INLINE tGetClient #-}

tGet ::
  Transport c =>
  (THandleParams v p -> Either TransportError RawTransmission -> r) ->
  THandle v c p ->
  IO (NonEmpty r)
tGet tDecode th@THandle {params} = L.map (tDecode params) <$> tGetParse th
{-# INLINE tGet #-}

tDecodeServer :: forall v err cmd. ProtocolEncoding v err cmd => THandleParams v 'TServer -> Either TransportError RawTransmission -> SignedTransmissionOrError err cmd
tDecodeServer THandleParams {sessionId, thVersion = v, implySessId} = \case
  Right RawTransmission {authenticator, serviceSig, authorized, sessId, corrId, entityId, command}
    | implySessId || sessId == sessionId -> case decodeTAuthBytes authenticator serviceSig of
        Right tAuth -> bimap t ((tAuth,authorized,) . t) cmdOrErr
          where
            cmdOrErr = parseProtocol @v @err @cmd v command >>= checkCredentials tAuth entityId
            t :: a -> (CorrId, EntityId, a)
            t = (corrId,entityId,)
        Left _ -> tError corrId PEBlock
    | otherwise -> tError corrId PESession
  Left _ -> tError "" PEBlock
  where
    tError :: CorrId -> ProtocolErrorType -> SignedTransmissionOrError err cmd
    tError corrId err = Left (corrId, NoEntity, fromProtocolError @v @err @cmd err)

tDecodeClient :: forall v err cmd. ProtocolEncoding v err cmd => THandleParams v 'TClient -> Either TransportError RawTransmission -> Transmission (Either err cmd)
tDecodeClient THandleParams {sessionId, thVersion = v, implySessId} = \case
  Right RawTransmission {sessId, corrId, entityId, command}
    | implySessId || sessId == sessionId -> (corrId, entityId, cmdOrErr)
    | otherwise -> tError corrId PESession
    where
      cmdOrErr = parseProtocol @v @err @cmd v command >>= checkCredentials Nothing entityId
  Left _ -> tError "" PEBlock
  where
    tError :: CorrId -> ProtocolErrorType -> Transmission (Either err cmd)
    tError corrId err = (corrId, NoEntity, Left $ fromProtocolError @v @err @cmd err)

$(J.deriveJSON defaultJSON ''MsgFlags)

$(J.deriveJSON (sumTypeJSON id) ''CommandError)

$(J.deriveJSON (sumTypeJSON id) ''BrokerErrorType)

$(J.deriveJSON defaultJSON ''BlockingInfo)

-- run deriveJSON in one TH splice to allow mutual instance
$(concat <$> mapM @[] (J.deriveJSON (sumTypeJSON id)) [''ProxyError, ''ErrorType])
