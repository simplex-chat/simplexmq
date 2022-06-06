{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
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
    smpClientVersion,
    smpClientVRange,
    maxMessageLength,
    e2eEncConfirmationLength,
    e2eEncMessageLength,

    -- * SMP protocol types
    ProtocolEncoding (..),
    Command (..),
    Party (..),
    Cmd (..),
    BrokerMsg (..),
    SParty (..),
    PartyI (..),
    QueueIdsKeys (..),
    ErrorType (..),
    CommandError (..),
    Transmission,
    SignedTransmission,
    SentRawTransmission,
    SignedRawTransmission,
    ClientMsgEnvelope (..),
    PubHeader (..),
    ClientMessage (..),
    PrivHeader (..),
    Protocol (..),
    ProtocolServer (..),
    SMPServer,
    pattern SMPServer,
    SrvLoc (..),
    CorrId (..),
    QueueId,
    RecipientId,
    SenderId,
    NotifierId,
    RcvPrivateSignKey,
    RcvPublicVerifyKey,
    RcvPublicDhKey,
    RcvDhSecret,
    SndPrivateSignKey,
    SndPublicVerifyKey,
    NtfPrivateSignKey,
    NtfPublicVerifyKey,
    MsgId,
    MsgBody,
    MsgFlags (..),
    noMsgFlags,

    -- * Parse and serialize
    ProtocolMsgTag (..),
    messageTagP,
    encodeTransmission,
    transmissionP,
    _smpP,

    -- * TCP transport functions
    tPut,
    tGet,

    -- * exports for tests
    CommandTag (..),
    BrokerMsgTag (..),
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad.Except
import Data.Aeson (ToJSON (..))
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Maybe (isNothing)
import Data.String
import Data.Time.Clock.System (SystemTime)
import Data.Type.Equality
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (bshow, (<$?>))
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))

smpClientVersion :: Version
smpClientVersion = 1

smpClientVRange :: VersionRange
smpClientVRange = mkVersionRange 1 smpClientVersion

maxMessageLength :: Int
maxMessageLength = 16088

-- it is shorter to allow per-queue e2e encryption DH key in the "public" header
e2eEncConfirmationLength :: Int
e2eEncConfirmationLength = 15936

e2eEncMessageLength :: Int
e2eEncMessageLength = 16032

-- | SMP protocol clients
data Party = Recipient | Sender | Notifier
  deriving (Show)

-- | Singleton types for SMP protocol clients
data SParty :: Party -> Type where
  SRecipient :: SParty Recipient
  SSender :: SParty Sender
  SNotifier :: SParty Notifier

instance TestEquality SParty where
  testEquality SRecipient SRecipient = Just Refl
  testEquality SSender SSender = Just Refl
  testEquality SNotifier SNotifier = Just Refl
  testEquality _ _ = Nothing

deriving instance Show (SParty p)

class PartyI (p :: Party) where sParty :: SParty p

instance PartyI Recipient where sParty = SRecipient

instance PartyI Sender where sParty = SSender

instance PartyI Notifier where sParty = SNotifier

-- | Type for client command of any participant.
data Cmd = forall p. PartyI p => Cmd (SParty p) (Command p)

deriving instance Show Cmd

-- | Parsed SMP transmission without signature, size and session ID.
type Transmission c = (CorrId, EntityId, c)

-- | signed parsed transmission, with original raw bytes and parsing error.
type SignedTransmission c = (Maybe C.ASignature, Signed, Transmission (Either ErrorType c))

type Signed = ByteString

-- | unparsed SMP transmission with signature.
data RawTransmission = RawTransmission
  { signature :: ByteString,
    signed :: ByteString,
    sessId :: SessionId,
    corrId :: ByteString,
    entityId :: ByteString,
    command :: ByteString
  }
  deriving (Show)

-- | unparsed sent SMP transmission with signature, without session ID.
type SignedRawTransmission = (Maybe C.ASignature, SessionId, ByteString, ByteString)

-- | unparsed sent SMP transmission with signature.
type SentRawTransmission = (Maybe C.ASignature, ByteString)

-- | SMP queue ID for the recipient.
type RecipientId = QueueId

-- | SMP queue ID for the sender.
type SenderId = QueueId

-- | SMP queue ID for notifications.
type NotifierId = QueueId

-- | SMP queue ID on the server.
type QueueId = EntityId

type EntityId = ByteString

-- | Parameterized type for SMP protocol commands from all clients.
data Command (p :: Party) where
  -- SMP recipient commands
  NEW :: RcvPublicVerifyKey -> RcvPublicDhKey -> Command Recipient
  SUB :: Command Recipient
  KEY :: SndPublicVerifyKey -> Command Recipient
  NKEY :: NtfPublicVerifyKey -> Command Recipient
  GET :: Command Recipient
  ACK :: Command Recipient
  OFF :: Command Recipient
  DEL :: Command Recipient
  -- SMP sender commands
  -- SEND v1 has to be supported for encoding/decoding
  -- SEND :: MsgBody -> Command Sender
  SEND :: MsgFlags -> MsgBody -> Command Sender
  PING :: Command Sender
  -- SMP notification subscriber commands
  NSUB :: Command Notifier

deriving instance Show (Command p)

deriving instance Eq (Command p)

data BrokerMsg where
  -- SMP broker messages (responses, client messages, notifications)
  IDS :: QueueIdsKeys -> BrokerMsg
  -- MSG v1 has to be supported for encoding/decoding
  -- MSG :: MsgId -> SystemTime -> MsgBody -> BrokerMsg
  MSG :: MsgId -> SystemTime -> MsgFlags -> MsgBody -> BrokerMsg
  NID :: NotifierId -> BrokerMsg
  NMSG :: BrokerMsg
  END :: BrokerMsg
  OK :: BrokerMsg
  ERR :: ErrorType -> BrokerMsg
  PONG :: BrokerMsg
  deriving (Eq, Show)

newtype MsgFlags = MsgFlags {notification :: Bool}
  deriving (Eq, Show)

instance Encoding MsgFlags where
  smpEncode MsgFlags {notification} = smpEncode notification
  smpP = do
    notification <- smpP <* A.takeTill (== ' ')
    pure MsgFlags {notification}

noMsgFlags :: MsgFlags
noMsgFlags = MsgFlags {notification = False}

-- * SMP command tags

data CommandTag (p :: Party) where
  NEW_ :: CommandTag Recipient
  SUB_ :: CommandTag Recipient
  KEY_ :: CommandTag Recipient
  NKEY_ :: CommandTag Recipient
  GET_ :: CommandTag Recipient
  ACK_ :: CommandTag Recipient
  OFF_ :: CommandTag Recipient
  DEL_ :: CommandTag Recipient
  SEND_ :: CommandTag Sender
  PING_ :: CommandTag Sender
  NSUB_ :: CommandTag Notifier

data CmdTag = forall p. PartyI p => CT (SParty p) (CommandTag p)

deriving instance Show (CommandTag p)

deriving instance Show CmdTag

data BrokerMsgTag
  = IDS_
  | MSG_
  | NID_
  | NMSG_
  | END_
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
    KEY_ -> "KEY"
    NKEY_ -> "NKEY"
    GET_ -> "GET"
    ACK_ -> "ACK"
    OFF_ -> "OFF"
    DEL_ -> "DEL"
    SEND_ -> "SEND"
    PING_ -> "PING"
    NSUB_ -> "NSUB"
  smpP = messageTagP

instance ProtocolMsgTag CmdTag where
  decodeTag = \case
    "NEW" -> Just $ CT SRecipient NEW_
    "SUB" -> Just $ CT SRecipient SUB_
    "KEY" -> Just $ CT SRecipient KEY_
    "NKEY" -> Just $ CT SRecipient NKEY_
    "GET" -> Just $ CT SRecipient GET_
    "ACK" -> Just $ CT SRecipient ACK_
    "OFF" -> Just $ CT SRecipient OFF_
    "DEL" -> Just $ CT SRecipient DEL_
    "SEND" -> Just $ CT SSender SEND_
    "PING" -> Just $ CT SSender PING_
    "NSUB" -> Just $ CT SNotifier NSUB_
    _ -> Nothing

instance Encoding CmdTag where
  smpEncode (CT _ t) = smpEncode t
  smpP = messageTagP

instance PartyI p => ProtocolMsgTag (CommandTag p) where
  decodeTag s = decodeTag s >>= (\(CT _ t) -> checkParty' t)

instance Encoding BrokerMsgTag where
  smpEncode = \case
    IDS_ -> "IDS"
    MSG_ -> "MSG"
    NID_ -> "NID"
    NMSG_ -> "NMSG"
    END_ -> "END"
    OK_ -> "OK"
    ERR_ -> "ERR"
    PONG_ -> "PONG"
  smpP = messageTagP

instance ProtocolMsgTag BrokerMsgTag where
  decodeTag = \case
    "IDS" -> Just IDS_
    "MSG" -> Just MSG_
    "NID" -> Just NID_
    "NMSG" -> Just NMSG_
    "END" -> Just END_
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
  { phVersion :: Version,
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
  = PHConfirmation C.APublicVerifyKey
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

type SMPServer = ProtocolServer

pattern SMPServer :: HostName -> ServiceName -> C.KeyHash -> ProtocolServer
pattern SMPServer host port keyHash = ProtocolServer host port keyHash

{-# COMPLETE SMPServer #-}

-- | SMP server location and transport key digest (hash).
data ProtocolServer = ProtocolServer
  { host :: HostName,
    port :: ServiceName,
    keyHash :: C.KeyHash
  }
  deriving (Eq, Ord, Show)

instance IsString ProtocolServer where
  fromString = parseString strDecode

instance Encoding ProtocolServer where
  smpEncode ProtocolServer {host, port, keyHash} =
    smpEncode (host, port, keyHash)
  smpP = do
    (host, port, keyHash) <- smpP
    pure ProtocolServer {host, port, keyHash}

instance StrEncoding ProtocolServer where
  strEncode ProtocolServer {host, port, keyHash} =
    "smp://" <> strEncode keyHash <> "@" <> strEncode (SrvLoc host port)
  strP = do
    _ <- "smp://"
    keyHash <- strP <* A.char '@'
    SrvLoc host port <- strP
    pure ProtocolServer {host, port, keyHash}

instance ToJSON ProtocolServer where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data SrvLoc = SrvLoc HostName ServiceName
  deriving (Eq, Ord, Show)

instance StrEncoding SrvLoc where
  strEncode (SrvLoc host port) = B.pack $ host <> if null port then "" else ':' : port
  strP = SrvLoc <$> host <*> (port <|> pure "")
    where
      host = B.unpack <$> A.takeWhile1 (A.notInClass ":#,;/ ")
      port = B.unpack <$> (A.char ':' *> A.takeWhile1 A.isDigit)

-- | Transmission correlation ID.
newtype CorrId = CorrId {bs :: ByteString} deriving (Eq, Ord, Show)

instance IsString CorrId where
  fromString = CorrId . fromString

instance StrEncoding CorrId where
  strEncode (CorrId cId) = strEncode cId
  strDecode s = CorrId <$> strDecode s
  strP = CorrId <$> strP

instance ToJSON CorrId where
  toJSON = strToJSON
  toEncoding = strToJEncoding

-- | Queue IDs and keys
data QueueIdsKeys = QIK
  { rcvId :: RecipientId,
    sndId :: SenderId,
    rcvPublicDhKey :: RcvPublicDhKey
  }
  deriving (Eq, Show)

-- | Recipient's private key used by the recipient to authorize (sign) SMP commands.
--
-- Only used by SMP agent, kept here so its definition is close to respective public key.
type RcvPrivateSignKey = C.APrivateSignKey

-- | Recipient's public key used by SMP server to verify authorization of SMP commands.
type RcvPublicVerifyKey = C.APublicVerifyKey

-- | Public key used for DH exchange to encrypt message bodies from server to recipient
type RcvPublicDhKey = C.PublicKeyX25519

-- | DH Secret used to encrypt message bodies from server to recipient
type RcvDhSecret = C.DhSecretX25519

-- | Sender's private key used by the recipient to authorize (sign) SMP commands.
--
-- Only used by SMP agent, kept here so its definition is close to respective public key.
type SndPrivateSignKey = C.APrivateSignKey

-- | Sender's public key used by SMP server to verify authorization of SMP commands.
type SndPublicVerifyKey = C.APublicVerifyKey

-- | Private key used by push notifications server to authorize (sign) LSTN command.
type NtfPrivateSignKey = C.APrivateSignKey

-- | Public key used by SMP server to verify authorization of LSTN command sent by push notifications server.
type NtfPublicVerifyKey = C.APublicVerifyKey

-- | SMP message server ID.
type MsgId = ByteString

-- | SMP message body.
type MsgBody = ByteString

-- | Type for protocol errors.
data ErrorType
  = -- | incorrect block format, encoding or signature size
    BLOCK
  | -- | incorrect SMP session ID (TLS Finished message / tls-unique binding RFC5929)
    SESSION
  | -- | SMP command is unknown or has invalid syntax
    CMD {cmdErr :: CommandError}
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | SMP queue capacity is exceeded on the server
    QUOTA
  | -- | ACK command is sent without message to be acknowledged
    NO_MSG
  | -- | sent message is too large (> maxMessageLength = 16078 bytes)
    LARGE_MSG
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- TODO remove, not part of SMP protocol
  deriving (Eq, Generic, Read, Show)

instance ToJSON ErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

instance StrEncoding ErrorType where
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    e -> bshow e
  strP = "CMD " *> (CMD <$> parseRead1) <|> parseRead1

-- | SMP command error type.
data CommandError
  = -- | unknown command
    UNKNOWN
  | -- | error parsing command
    SYNTAX
  | -- | transmission has no required credentials (signature or queue ID)
    NO_AUTH
  | -- | transmission has credentials that are not allowed for this command
    HAS_AUTH
  | -- | transmission has no required entity ID (e.g. SMP queue)
    NO_ENTITY
  deriving (Eq, Generic, Read, Show)

instance ToJSON CommandError where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

instance Arbitrary ErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandError where arbitrary = genericArbitraryU

-- | SMP transmission parser.
transmissionP :: Parser RawTransmission
transmissionP = do
  signature <- smpP
  signed <- A.takeByteString
  either fail pure $ parseAll (trn signature signed) signed
  where
    trn signature signed = do
      sessId <- smpP
      corrId <- smpP
      entityId <- smpP
      command <- A.takeByteString
      pure RawTransmission {signature, signed, sessId, corrId, entityId, command}

class (ProtocolEncoding msg, ProtocolEncoding (ProtocolCommand msg)) => Protocol msg where
  type ProtocolCommand msg = cmd | cmd -> msg
  protocolClientHandshake :: forall c. Transport c => c -> C.KeyHash -> ExceptT TransportError IO (THandle c)
  protocolPing :: ProtocolCommand msg
  protocolError :: msg -> Maybe ErrorType

instance Protocol BrokerMsg where
  type ProtocolCommand BrokerMsg = Cmd
  protocolClientHandshake = smpClientHandshake
  protocolPing = Cmd SSender PING
  protocolError = \case
    ERR e -> Just e
    _ -> Nothing

class ProtocolMsgTag (Tag msg) => ProtocolEncoding msg where
  type Tag msg
  encodeProtocol :: Version -> msg -> ByteString
  protocolP :: Version -> Tag msg -> Parser msg
  checkCredentials :: SignedRawTransmission -> msg -> Either ErrorType msg

instance PartyI p => ProtocolEncoding (Command p) where
  type Tag (Command p) = CommandTag p
  encodeProtocol v = \case
    NEW rKey dhKey -> e (NEW_, ' ', rKey, dhKey)
    SUB -> e SUB_
    KEY k -> e (KEY_, ' ', k)
    NKEY k -> e (NKEY_, ' ', k)
    GET -> e GET_
    ACK -> e ACK_
    OFF -> e OFF_
    DEL -> e DEL_
    SEND flags msg
      | v == 1 -> e (SEND_, ' ', Tail msg)
      | otherwise -> e (SEND_, ' ', flags, ' ', Tail msg)
    PING -> e PING_
    NSUB -> e NSUB_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v tag = (\(Cmd _ c) -> checkParty c) <$?> protocolP v (CT (sParty @p) tag)

  checkCredentials (sig, _, queueId, _) cmd = case cmd of
    -- NEW must have signature but NOT queue ID
    NEW {}
      | isNothing sig -> Left $ CMD NO_AUTH
      | not (B.null queueId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    -- SEND must have queue ID, signature is not always required
    SEND {}
      | B.null queueId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd
    -- PING must not have queue ID or signature
    PING
      | isNothing sig && B.null queueId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and queue ID
    _
      | isNothing sig || B.null queueId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

instance ProtocolEncoding Cmd where
  type Tag Cmd = CmdTag
  encodeProtocol v (Cmd _ c) = encodeProtocol v c

  protocolP v = \case
    CT SRecipient tag ->
      Cmd SRecipient <$> case tag of
        NEW_ -> NEW <$> _smpP <*> smpP
        SUB_ -> pure SUB
        KEY_ -> KEY <$> _smpP
        NKEY_ -> NKEY <$> _smpP
        GET_ -> pure GET
        ACK_ -> pure ACK
        OFF_ -> pure OFF
        DEL_ -> pure DEL
    CT SSender tag ->
      Cmd SSender <$> case tag of
        SEND_
          | v == 1 -> SEND <$> pure noMsgFlags <*> (unTail <$> _smpP)
          | otherwise -> SEND <$> _smpP <*> (unTail <$> _smpP)
        PING_ -> pure PING
    CT SNotifier NSUB_ -> pure $ Cmd SNotifier NSUB

  checkCredentials t (Cmd p c) = Cmd p <$> checkCredentials t c

instance ProtocolEncoding BrokerMsg where
  type Tag BrokerMsg = BrokerMsgTag
  encodeProtocol v = \case
    IDS (QIK rcvId sndId srvDh) -> e (IDS_, ' ', rcvId, sndId, srvDh)
    MSG msgId ts flags msgBody
      | v == 1 -> e (MSG_, ' ', msgId, ts, Tail msgBody)
      | otherwise -> e (MSG_, ' ', msgId, ts, flags, ' ', Tail msgBody)
    NID nId -> e (NID_, ' ', nId)
    NMSG -> e NMSG_
    END -> e END_
    OK -> e OK_
    ERR err -> e (ERR_, ' ', err)
    PONG -> e PONG_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP v = \case
    MSG_
      | v == 1 -> MSG <$> _smpP <*> smpP <*> pure noMsgFlags <*> (unTail <$> smpP)
      | otherwise -> MSG <$> _smpP <*> smpP <*> smpP <*> (unTail <$> _smpP)
    IDS_ -> IDS <$> (QIK <$> _smpP <*> smpP <*> smpP)
    NID_ -> NID <$> _smpP
    NMSG_ -> pure NMSG
    END_ -> pure END
    OK_ -> pure OK
    ERR_ -> ERR <$> _smpP
    PONG_ -> pure PONG

  checkCredentials (_, _, queueId, _) cmd = case cmd of
    -- IDS response should not have queue ID
    IDS _ -> Right cmd
    -- ERR response does not always have queue ID
    ERR _ -> Right cmd
    -- PONG response must not have queue ID
    PONG
      | B.null queueId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other broker responses must have queue ID
    _
      | B.null queueId -> Left $ CMD NO_ENTITY
      | otherwise -> Right cmd

_smpP :: Encoding a => Parser a
_smpP = A.space *> smpP

-- | Parse SMP protocol commands and broker messages
parseProtocol :: ProtocolEncoding msg => Version -> ByteString -> Either ErrorType msg
parseProtocol v s =
  let (tag, params) = B.break (== ' ') s
   in case decodeTag tag of
        Just cmd -> parse (protocolP v cmd) (CMD SYNTAX) params
        Nothing -> Left $ CMD UNKNOWN

checkParty :: forall t p p'. (PartyI p, PartyI p') => t p' -> Either String (t p)
checkParty c = case testEquality (sParty @p) (sParty @p') of
  Just Refl -> Right c
  Nothing -> Left "bad command party"

checkParty' :: forall t p p'. (PartyI p, PartyI p') => t p' -> Maybe (t p)
checkParty' c = case testEquality (sParty @p) (sParty @p') of
  Just Refl -> Just c
  _ -> Nothing

instance Encoding ErrorType where
  smpEncode = \case
    BLOCK -> "BLOCK"
    SESSION -> "SESSION"
    CMD err -> "CMD " <> smpEncode err
    AUTH -> "AUTH"
    QUOTA -> "QUOTA"
    NO_MSG -> "NO_MSG"
    LARGE_MSG -> "LARGE_MSG"
    INTERNAL -> "INTERNAL"
    DUPLICATE_ -> "DUPLICATE_"

  smpP =
    A.takeTill (== ' ') >>= \case
      "BLOCK" -> pure BLOCK
      "SESSION" -> pure SESSION
      "CMD" -> CMD <$> _smpP
      "AUTH" -> pure AUTH
      "QUOTA" -> pure QUOTA
      "NO_MSG" -> pure NO_MSG
      "LARGE_MSG" -> pure LARGE_MSG
      "INTERNAL" -> pure INTERNAL
      "DUPLICATE_" -> pure DUPLICATE_
      _ -> fail "bad error type"

instance Encoding CommandError where
  smpEncode e = case e of
    UNKNOWN -> "UNKNOWN"
    SYNTAX -> "SYNTAX"
    NO_AUTH -> "NO_AUTH"
    HAS_AUTH -> "HAS_AUTH"
    NO_ENTITY -> "NO_ENTITY"
  smpP =
    A.takeTill (== ' ') >>= \case
      "UNKNOWN" -> pure UNKNOWN
      "SYNTAX" -> pure SYNTAX
      "NO_AUTH" -> pure NO_AUTH
      "HAS_AUTH" -> pure HAS_AUTH
      "NO_ENTITY" -> pure NO_ENTITY
      "NO_QUEUE" -> pure NO_ENTITY
      _ -> fail "bad command error type"

-- | Send signed SMP transmission to TCP transport.
tPut :: Transport c => THandle c -> SentRawTransmission -> IO (Either TransportError ())
tPut th (sig, t) = tPutBlock th $ smpEncode (C.signatureBytes sig) <> t

encodeTransmission :: ProtocolEncoding c => Version -> ByteString -> Transmission c -> ByteString
encodeTransmission v sessionId (CorrId corrId, queueId, command) =
  smpEncode (sessionId, corrId, queueId) <> encodeProtocol v command

-- | Receive and parse transmission from the TCP transport (ignoring any trailing padding).
tGetParse :: Transport c => THandle c -> IO (Either TransportError RawTransmission)
tGetParse th = (parse transmissionP TEBadBlock =<<) <$> tGetBlock th

-- | Receive client and server transmissions (determined by `cmd` type).
tGet :: forall cmd c m. (ProtocolEncoding cmd, Transport c, MonadIO m) => THandle c -> m (SignedTransmission cmd)
tGet th@THandle {sessionId, thVersion = v} = liftIO (tGetParse th) >>= decodeParseValidate
  where
    decodeParseValidate :: Either TransportError RawTransmission -> m (SignedTransmission cmd)
    decodeParseValidate = \case
      Right RawTransmission {signature, signed, sessId, corrId, entityId, command}
        | sessId == sessionId ->
          let decodedTransmission = (,corrId,entityId,command) <$> C.decodeSignature signature
           in either (const $ tError corrId) (tParseValidate signed) decodedTransmission
        | otherwise -> pure (Nothing, "", (CorrId corrId, "", Left SESSION))
      Left _ -> tError ""

    tError :: ByteString -> m (SignedTransmission cmd)
    tError corrId = pure (Nothing, "", (CorrId corrId, "", Left BLOCK))

    tParseValidate :: ByteString -> SignedRawTransmission -> m (SignedTransmission cmd)
    tParseValidate signed t@(sig, corrId, entityId, command) = do
      let cmd = parseProtocol v command >>= checkCredentials t
      pure (sig, signed, (CorrId corrId, entityId, cmd))
