{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
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
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

-- |
-- Module      : Simplex.Messaging.Protocol
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
    maxMessageLength,
    e2eEncMessageLength,

    -- * SMP protocol types
    Protocol,
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
    EncMessage (..),
    PubHeader (..),
    ClientMessage (..),
    PrivHeader (..),
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

    -- * Parse and serialize
    encodeTransmission,
    transmissionP,
    encodeProtocol,

    -- * TCP transport functions
    tPut,
    tGet,

    -- * exports for tests
    CommandTag (..),
    BrokerMsgTag (..),
    ProtocolTag (..),
  )
where

import Control.Applicative (optional)
import Control.Monad.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Maybe (isNothing)
import Data.String
import Data.Time.Clock
import Data.Type.Equality
import Data.Word (Word16)
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers
import Simplex.Messaging.Transport (THandle (..), Transport, TransportError (..), tGetBlock, tPutBlock)
import Simplex.Messaging.Util ((<$?>))
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))

smpClientVersion :: VersionRange
smpClientVersion = mkVersionRange 1 1

maxMessageLength :: Int
maxMessageLength = 15968

e2eEncMessageLength :: Int
e2eEncMessageLength = 15842

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
type Transmission c = (CorrId, QueueId, c)

-- | signed parsed transmission, with original raw bytes and parsing error.
type SignedTransmission c = (Maybe C.ASignature, Signed, Transmission (Either ErrorType c))

type Signed = ByteString

-- | unparsed SMP transmission with signature.
data RawTransmission = RawTransmission
  { signature :: ByteString,
    signed :: ByteString,
    sessId :: ByteString,
    corrId :: ByteString,
    queueId :: ByteString,
    command :: ByteString
  }

-- | unparsed sent SMP transmission with signature, without session ID.
type SignedRawTransmission = (Maybe C.ASignature, ByteString, ByteString, ByteString)

-- | unparsed sent SMP transmission with signature.
type SentRawTransmission = (Maybe C.ASignature, ByteString)

-- | SMP queue ID for the recipient.
type RecipientId = QueueId

-- | SMP queue ID for the sender.
type SenderId = QueueId

-- | SMP queue ID for notifications.
type NotifierId = QueueId

-- | SMP queue ID on the server.
type QueueId = ByteString

-- | Parameterized type for SMP protocol commands from all clients.
data Command (p :: Party) where
  -- SMP recipient commands
  NEW :: RcvPublicVerifyKey -> RcvPublicDhKey -> Command Recipient
  SUB :: Command Recipient
  KEY :: SndPublicVerifyKey -> Command Recipient
  NKEY :: NtfPublicVerifyKey -> Command Recipient
  ACK :: Command Recipient
  OFF :: Command Recipient
  DEL :: Command Recipient
  -- SMP sender commands
  SEND :: MsgBody -> Command Sender
  PING :: Command Sender
  -- SMP notification subscriber commands
  NSUB :: Command Notifier

deriving instance Show (Command p)

deriving instance Eq (Command p)

data BrokerMsg where
  -- SMP broker messages (responses, client messages, notifications)
  IDS :: QueueIdsKeys -> BrokerMsg
  MSG :: MsgId -> UTCTime -> MsgBody -> BrokerMsg
  NID :: NotifierId -> BrokerMsg
  NMSG :: BrokerMsg
  END :: BrokerMsg
  OK :: BrokerMsg
  ERR :: ErrorType -> BrokerMsg
  PONG :: BrokerMsg
  deriving (Eq, Show)

-- * SMP command tags

newtype ProtocolTag = ProtocolTag {unProtocolTag :: ByteString} deriving (Eq, Show)

instance IsString ProtocolTag where fromString = ProtocolTag . B.pack

instance Encoding ProtocolTag where
  smpEncode (ProtocolTag t) = t
  smpP = ProtocolTag <$> A.takeWhile (/= ' ') <* optional A.space

data CommandTag (p :: Party) where
  NEW_ :: CommandTag Recipient
  SUB_ :: CommandTag Recipient
  KEY_ :: CommandTag Recipient
  NKEY_ :: CommandTag Recipient
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
messageTagP = maybe (fail "bad command") pure . decodeTag . unProtocolTag =<< smpP

instance PartyI p => Encoding (CommandTag p) where
  smpEncode = \case
    NEW_ -> "NEW"
    SUB_ -> "SUB"
    KEY_ -> "KEY"
    NKEY_ -> "NKEY"
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
data EncMessage = EncMessage
  { emHeader :: PubHeader,
    emNonce :: C.CbNonce,
    emBody :: ByteString
  }

data PubHeader = PubHeader
  { phVersion :: Word16,
    phE2ePubDhKey :: C.PublicKeyX25519
  }

instance Encoding PubHeader where
  smpEncode (PubHeader v k) = smpEncode (v, k)
  smpP = PubHeader <$> smpP <*> smpP

instance Encoding EncMessage where
  smpEncode EncMessage {emHeader, emNonce, emBody} =
    smpEncode emHeader <> smpEncode emNonce <> emBody
  smpP = do
    emHeader <- smpP
    emNonce <- smpP
    emBody <- A.takeByteString
    pure EncMessage {emHeader, emNonce, emBody}

data ClientMessage = ClientMessage PrivHeader ByteString

data PrivHeader
  = PHConfirmation C.APublicVerifyKey
  | PHEmpty

instance Encoding PrivHeader where
  smpEncode = \case
    PHConfirmation k -> "K" <> smpEncode k
    PHEmpty -> " "
  smpP =
    A.anyChar >>= \case
      'K' -> PHConfirmation <$> smpP
      ' ' -> pure PHEmpty
      _ -> fail "invalid PrivHeader"

instance Encoding ClientMessage where
  smpEncode (ClientMessage h msg) = smpEncode h <> msg
  smpP = ClientMessage <$> smpP <*> A.takeByteString

-- | Transmission correlation ID.
newtype CorrId = CorrId {bs :: ByteString} deriving (Eq, Ord, Show)

instance IsString CorrId where
  fromString = CorrId . fromString

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
    CMD CommandError
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | SMP queue capacity is exceeded on the server
    QUOTA
  | -- | ACK command is sent without message to be acknowledged
    NO_MSG
  | -- | sent message is too large (> maxMessageLength = 15968 bytes)
    LARGE_MSG
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- TODO remove, not part of SMP protocol
  deriving (Eq, Generic, Read, Show)

-- * ErrorType tags

pattern BLOCK_ :: ProtocolTag
pattern BLOCK_ = "BLOCK"

pattern SESSION_ :: ProtocolTag
pattern SESSION_ = "SESSION"

pattern CMD_ :: ProtocolTag
pattern CMD_ = "CMD"

pattern AUTH_ :: ProtocolTag
pattern AUTH_ = "AUTH"

pattern QUOTA_ :: ProtocolTag
pattern QUOTA_ = "QUOTA"

pattern NO_MSG_ :: ProtocolTag
pattern NO_MSG_ = "NO_MSG"

pattern LARGE_MSG_ :: ProtocolTag
pattern LARGE_MSG_ = "LARGE_MSG"

pattern INTERNAL_ :: ProtocolTag
pattern INTERNAL_ = "INTERNAL"

pattern DUPLICATE__ :: ProtocolTag
pattern DUPLICATE__ = "DUPLICATE_"

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
  | -- | transmission has no required queue ID
    NO_QUEUE
  deriving (Eq, Generic, Read, Show)

-- CommandError tags
pattern UNKNOWN_ :: ProtocolTag
pattern UNKNOWN_ = "UNKNOWN"

pattern SYNTAX_ :: ProtocolTag
pattern SYNTAX_ = "SYNTAX"

pattern NO_AUTH_ :: ProtocolTag
pattern NO_AUTH_ = "NO_AUTH"

pattern HAS_AUTH_ :: ProtocolTag
pattern HAS_AUTH_ = "HAS_AUTH"

pattern NO_QUEUE_ :: ProtocolTag
pattern NO_QUEUE_ = "NO_QUEUE"

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
      queueId <- smpP
      command <- A.takeByteString
      pure RawTransmission {signature, signed, sessId, corrId, queueId, command}

class Protocol msg where
  type Tag msg
  encodeProtocol :: msg -> ByteString
  protocolP :: Tag msg -> Parser msg
  checkCredentials :: SignedRawTransmission -> msg -> Either ErrorType msg

instance PartyI p => Protocol (Command p) where
  type Tag (Command p) = CommandTag p
  encodeProtocol = \case
    NEW rKey dhKey -> e (NEW_, ' ', rKey, dhKey)
    SUB -> e SUB_
    KEY k -> e (KEY_, ' ', k)
    NKEY k -> e (NKEY_, ' ', k)
    ACK -> e ACK_
    OFF -> e OFF_
    DEL -> e DEL_
    SEND msg -> e (SEND_, ' ', Tail msg)
    PING -> e PING_
    NSUB -> e NSUB_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP tag = (\(Cmd _ c) -> checkParty c) <$?> protocolP (CT (sParty @p) tag)

  checkCredentials (sig, _, queueId, _) cmd = case cmd of
    -- NEW must have signature but NOT queue ID
    NEW {}
      | isNothing sig -> Left $ CMD NO_AUTH
      | not (B.null queueId) -> Left $ CMD HAS_AUTH
      | otherwise -> Right cmd
    -- SEND must have queue ID, signature is not always required
    SEND _
      | B.null queueId -> Left $ CMD NO_QUEUE
      | otherwise -> Right cmd
    -- PING must not have queue ID or signature
    PING
      | isNothing sig && B.null queueId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other client commands must have both signature and queue ID
    _
      | isNothing sig || B.null queueId -> Left $ CMD NO_AUTH
      | otherwise -> Right cmd

instance Protocol Cmd where
  type Tag Cmd = CmdTag
  encodeProtocol (Cmd _ c) = encodeProtocol c

  protocolP = \case
    CT SRecipient tag ->
      Cmd SRecipient <$> case tag of
        NEW_ -> NEW <$> _smpP <*> smpP
        SUB_ -> pure SUB
        KEY_ -> KEY <$> _smpP
        NKEY_ -> NKEY <$> _smpP
        ACK_ -> pure ACK
        OFF_ -> pure OFF
        DEL_ -> pure DEL
    CT SSender tag ->
      Cmd SSender <$> case tag of
        SEND_ -> SEND . unTail <$> _smpP
        PING_ -> pure PING
    CT SNotifier NSUB_ -> pure $ Cmd SNotifier NSUB

  checkCredentials t (Cmd p c) = Cmd p <$> checkCredentials t c

instance Protocol BrokerMsg where
  type Tag BrokerMsg = BrokerMsgTag
  encodeProtocol = \case
    IDS (QIK rcvId sndId srvDh) -> e (IDS_, ' ', rcvId, sndId, srvDh)
    MSG msgId ts msgBody -> e (MSG_, ' ', msgId, ts, Tail msgBody)
    NID nId -> e (NID_, ' ', nId)
    NMSG -> e NMSG_
    END -> e END_
    OK -> e OK_
    ERR err -> e (ERR_, ' ', err)
    PONG -> e PONG_
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  protocolP = \case
    MSG_ -> MSG <$> _smpP <*> smpP <*> (unTail <$> smpP)
    IDS_ -> IDS <$> (QIK <$> _smpP <*> smpP <*> smpP)
    NID_ -> NID <$> _smpP
    NMSG_ -> pure NMSG
    END_ -> pure END
    OK_ -> pure OK
    ERR_ -> ERR <$> _smpP
    PONG_ -> pure PONG

  checkCredentials (_, _, queueId, _) cmd = case cmd of
    -- IDS response must not have queue ID
    IDS _ -> Right cmd
    -- ERR response does not always have queue ID
    ERR _ -> Right cmd
    -- PONG response must not have queue ID
    PONG
      | B.null queueId -> Right cmd
      | otherwise -> Left $ CMD HAS_AUTH
    -- other broker responses must have queue ID
    _
      | B.null queueId -> Left $ CMD NO_QUEUE
      | otherwise -> Right cmd

_smpP :: Encoding a => Parser a
_smpP = A.space *> smpP

-- | Parse SMP protocol commands and broker messages
parseProtocol :: (Protocol msg, ProtocolMsgTag (Tag msg)) => ByteString -> Either ErrorType msg
parseProtocol s =
  let (tag, params) = B.break (== ' ') s
   in case decodeTag tag of
        Just cmd -> parse (protocolP cmd) (CMD SYNTAX) params
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
    BLOCK -> e BLOCK_
    SESSION -> e SESSION_
    CMD err -> e (CMD_, ' ', err)
    AUTH -> e AUTH_
    QUOTA -> e QUOTA_
    NO_MSG -> e NO_MSG_
    LARGE_MSG -> e LARGE_MSG_
    INTERNAL -> e INTERNAL_
    DUPLICATE_ -> e DUPLICATE__
    where
      e :: Encoding a => a -> ByteString
      e = smpEncode

  smpP =
    smpP >>= \case
      BLOCK_ -> pure BLOCK
      SESSION_ -> pure SESSION
      CMD_ -> CMD <$> smpP
      AUTH_ -> pure AUTH
      QUOTA_ -> pure QUOTA
      NO_MSG_ -> pure NO_MSG
      LARGE_MSG_ -> pure LARGE_MSG
      INTERNAL_ -> pure INTERNAL
      DUPLICATE__ -> pure DUPLICATE_
      _ -> fail "bad error type"

instance Encoding CommandError where
  smpEncode e = smpEncode $ case e of
    UNKNOWN -> UNKNOWN_
    SYNTAX -> SYNTAX_
    NO_AUTH -> NO_AUTH_
    HAS_AUTH -> HAS_AUTH_
    NO_QUEUE -> NO_QUEUE_
  smpP =
    smpP >>= \case
      UNKNOWN_ -> pure UNKNOWN
      SYNTAX_ -> pure SYNTAX
      NO_AUTH_ -> pure NO_AUTH
      HAS_AUTH_ -> pure HAS_AUTH
      NO_QUEUE_ -> pure NO_QUEUE
      _ -> fail "bad command error type"

-- | Send signed SMP transmission to TCP transport.
tPut :: Transport c => THandle c -> SentRawTransmission -> IO (Either TransportError ())
tPut th (sig, t) = tPutBlock th $ smpEncode (C.signatureBytes sig) <> t

encodeTransmission :: Protocol c => ByteString -> Transmission c -> ByteString
encodeTransmission sessionId (CorrId corrId, queueId, command) =
  smpEncode (sessionId, corrId, queueId) <> encodeProtocol command

-- | Receive and parse transmission from the TCP transport (ignoring any trailing padding).
tGetParse :: Transport c => THandle c -> IO (Either TransportError RawTransmission)
tGetParse th = (parse transmissionP TEBadBlock =<<) <$> tGetBlock th

-- | Receive client and server transmissions (determined by `cmd` type).
tGet ::
  forall cmd c m.
  (Protocol cmd, ProtocolMsgTag (Tag cmd), Transport c, MonadIO m) =>
  THandle c ->
  m (SignedTransmission cmd)
tGet th@THandle {sessionId} = liftIO (tGetParse th) >>= decodeParseValidate
  where
    decodeParseValidate :: Either TransportError RawTransmission -> m (SignedTransmission cmd)
    decodeParseValidate = \case
      Right RawTransmission {signature, signed, sessId, corrId, queueId, command}
        | sessId == sessionId ->
          let decodedTransmission = (,corrId,queueId,command) <$> C.decodeSignature signature
           in either (const $ tError corrId) (tParseValidate signed) decodedTransmission
        | otherwise -> pure (Nothing, "", (CorrId corrId, "", Left SESSION))
      Left _ -> tError ""

    tError :: ByteString -> m (SignedTransmission cmd)
    tError corrId = pure (Nothing, "", (CorrId corrId, "", Left BLOCK))

    tParseValidate :: ByteString -> SignedRawTransmission -> m (SignedTransmission cmd)
    tParseValidate signed t@(sig, corrId, queueId, command) = do
      let cmd = parseProtocol command >>= checkCredentials t
      pure (sig, signed, (CorrId corrId, queueId, cmd))
