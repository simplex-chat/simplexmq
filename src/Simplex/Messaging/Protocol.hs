{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
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
    Command (..),
    CommandI (..),
    Party (..),
    IsClient,
    Cmd (..),
    ClientCmd (..),
    SParty (..),
    PartyI (..),
    QueueIdsKeys (..),
    ErrorType (..),
    CommandError (..),
    Transmission,
    BrokerTransmission,
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
    Encoded,
    MsgId,
    MsgBody,

    -- * Parse and serialize
    encodeTransmission,
    transmissionP,
    -- below exports are for tests only
    encodeCommand',
    clientParty,
    clientCommandP,
    brokerCommandP,

    -- * TCP transport functions
    tPut,
    tGet,

    -- * Command tags (for tests)
    pattern NEW_,
    pattern KEY_,
    pattern SEND_,
    pattern Recipient_,
    pattern Sender_,
    protocolTags,
  )
where

import Control.Applicative ((<|>))
import Control.Monad.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Maybe (isNothing)
import Data.String
import Data.Time.Clock
import Data.Type.Equality
import Data.Word (Word16)
import GHC.Generics (Generic)
import GHC.TypeLits (ErrorMessage (..), TypeError)
import Generic.Random (genericArbitraryU)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers
import Simplex.Messaging.Transport (THandle (..), Transport, TransportError (..), tGetBlock, tPutBlock)
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))

smpClientVersion :: VersionRange
smpClientVersion = mkVersionRange 1 1

maxMessageLength :: Int
maxMessageLength = 15968

e2eEncMessageLength :: Int
e2eEncMessageLength = 15842

-- | SMP protocol participants.
data Party = Recipient | Sender | Notifier | Broker
  deriving (Show)

-- | Singleton types for SMP protocol participants.
data SParty :: Party -> Type where
  SRecipient :: SParty Recipient
  SSender :: SParty Sender
  SNotifier :: SParty Notifier
  SBroker :: SParty Broker

instance TestEquality SParty where
  testEquality SRecipient SRecipient = Just Refl
  testEquality SSender SSender = Just Refl
  testEquality SNotifier SNotifier = Just Refl
  testEquality SBroker SBroker = Just Refl
  testEquality _ _ = Nothing

deriving instance Show (SParty p)

class PartyI (p :: Party) where sParty :: SParty p

instance PartyI Recipient where sParty = SRecipient

instance PartyI Sender where sParty = SSender

instance PartyI Notifier where sParty = SNotifier

instance PartyI Broker where sParty = SBroker

-- | Type for command or response of any participant.
data Cmd = forall p. PartyI p => Cmd (SParty p) (Command p)

deriving instance Show Cmd

-- | Type for command or response of any participant.
data ClientCmd = forall p. (PartyI p, IsClient p) => ClientCmd (SParty p) (Command p)

class CommandI c where
  toCommand :: (forall p. PartyI p => Command p -> a) -> c -> a

-- | Parsed SMP transmission without signature, size and session ID.
type Transmission c = (CorrId, QueueId, c)

type BrokerTransmission = Transmission (Command Broker)

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
type QueueId = Encoded

-- | Parameterized type for SMP protocol commands from all participants.
data Command (a :: Party) where
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
  -- SMP broker commands (responses, messages, notifications)
  IDS :: QueueIdsKeys -> Command Broker
  MSG :: MsgId -> UTCTime -> MsgBody -> Command Broker
  NID :: NotifierId -> Command Broker
  NMSG :: Command Broker
  END :: Command Broker
  OK :: Command Broker
  ERR :: ErrorType -> Command Broker
  PONG :: Command Broker

deriving instance Show (Command a)

deriving instance Eq (Command a)

-- * SMP command tags

pattern Recipient_ :: Char
pattern Recipient_ = '\x01'

pattern Sender_ :: Char
pattern Sender_ = '\x02'

pattern Notifier_ :: Char
pattern Notifier_ = '\x03'

pattern Broker_ :: Char
pattern Broker_ = '\x04'

pattern NEW_ :: Char
pattern NEW_ = '\x10'

pattern SUB_ :: Char
pattern SUB_ = '\x11'

pattern KEY_ :: Char
pattern KEY_ = '\x12'

pattern NKEY_ :: Char
pattern NKEY_ = '\x13'

pattern ACK_ :: Char
pattern ACK_ = '\x14'

pattern OFF_ :: Char
pattern OFF_ = '\x15'

pattern DEL_ :: Char
pattern DEL_ = '\x16'

pattern SEND_ :: Char
pattern SEND_ = '\x20'

pattern PING_ :: Char
pattern PING_ = '\x21'

pattern NSUB_ :: Char
pattern NSUB_ = '\x30'

pattern IDS_ :: Char
pattern IDS_ = '\x40'

pattern MSG_ :: Char
pattern MSG_ = '\x41'

pattern NID_ :: Char
pattern NID_ = '\x42'

pattern NMSG_ :: Char
pattern NMSG_ = '\x43'

pattern END_ :: Char
pattern END_ = '\x44'

pattern OK_ :: Char
pattern OK_ = '\x45'

pattern ERR_ :: Char
pattern ERR_ = '\x46'

pattern PONG_ :: Char
pattern PONG_ = '\x47'

protocolTags :: [Char]
protocolTags =
  [ Recipient_,
    Sender_,
    Notifier_,
    Broker_,
    NEW_,
    SUB_,
    KEY_,
    NKEY_,
    ACK_,
    OFF_,
    DEL_,
    SEND_,
    PING_,
    NSUB_,
    IDS_,
    MSG_,
    NID_,
    NMSG_,
    END_,
    OK_,
    ERR_,
    PONG_,
    BLOCK_,
    SESSION_,
    CMD_,
    AUTH_,
    QUOTA_,
    NO_MSG_,
    LARGE_MSG_,
    INTERNAL_,
    DUPLICATE__,
    UNKNOWN_,
    PROHIBITED_,
    SYNTAX_,
    NO_AUTH_,
    HAS_AUTH_,
    NO_QUEUE_
  ]

type family IsClient p :: Constraint where
  IsClient Recipient = ()
  IsClient Sender = ()
  IsClient Notifier = ()
  IsClient p =
    (Int ~ Bool, TypeError (Text "Party " :<>: ShowType p :<>: Text " is not a Client"))

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

-- | Base-64 encoded string.
type Encoded = ByteString

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
type MsgId = Encoded

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

pattern BLOCK_ :: Char
pattern BLOCK_ = '\x50'

pattern SESSION_ :: Char
pattern SESSION_ = '\x51'

pattern CMD_ :: Char
pattern CMD_ = '\x52'

pattern AUTH_ :: Char
pattern AUTH_ = '\x53'

pattern QUOTA_ :: Char
pattern QUOTA_ = '\x54'

pattern NO_MSG_ :: Char
pattern NO_MSG_ = '\x55'

pattern LARGE_MSG_ :: Char
pattern LARGE_MSG_ = '\x56'

pattern INTERNAL_ :: Char
pattern INTERNAL_ = '\x57'

pattern DUPLICATE__ :: Char
pattern DUPLICATE__ = '\x58'

-- | SMP command error type.
data CommandError
  = -- | unknown command
    UNKNOWN
  | -- | server response sent from client or vice versa
    PROHIBITED
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
pattern UNKNOWN_ :: Char
pattern UNKNOWN_ = '\x60'

pattern PROHIBITED_ :: Char
pattern PROHIBITED_ = '\x61'

pattern SYNTAX_ :: Char
pattern SYNTAX_ = '\x62'

pattern NO_AUTH_ :: Char
pattern NO_AUTH_ = '\x63'

pattern HAS_AUTH_ :: Char
pattern HAS_AUTH_ = '\x64'

pattern NO_QUEUE_ :: Char
pattern NO_QUEUE_ = '\x65'

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

instance CommandI ClientCmd where
  toCommand f (ClientCmd _ c) = f c

instance PartyI p => CommandI (Command p) where
  toCommand = id

-- TODO these patterns allow to get protocol errors from parser string errors.
-- It would be more efficient to have a parser that uses correct type for errors.
pattern CMD_PROHIBITED :: String
pattern CMD_PROHIBITED <- "Failed reading: PARTY" where CMD_PROHIBITED = "PARTY"

pattern CMD_UNKNOWN :: String
pattern CMD_UNKNOWN <- "Failed reading: UNKNOWN" where CMD_UNKNOWN = "UNKNOWN"

-- | Parse SMP command.
parseCommand :: Encoding cmd => ByteString -> Either ErrorType cmd
parseCommand = first errorType . parseAll smpP
  where
    errorType = \case
      CMD_PROHIBITED -> CMD PROHIBITED
      CMD_UNKNOWN -> CMD UNKNOWN
      _ -> CMD SYNTAX

instance Encoding (Command Broker) where
  smpEncode = encodeCommand'
  smpP = brokerCommandP

instance Encoding ClientCmd where
  smpEncode (ClientCmd _ c) = encodeCommand' c
  smpP = clientCommandP

-- this instance is for tests only
instance Encoding Cmd where
  smpEncode (Cmd _ c) = encodeCommand' c
  smpP = (Cmd SBroker <$> brokerCommandP) <|> ((\(ClientCmd p c) -> Cmd p c) <$> clientCommandP)

clientParty :: forall p. PartyI p => ClientCmd -> Either String (Command p)
clientParty (ClientCmd p c) = case testEquality p (sParty @p) of
  Just Refl -> Right c
  Nothing -> Left CMD_PROHIBITED

encodeCommand' :: Command p -> ByteString
encodeCommand' = \case
  NEW rKey dhKey -> e (Recipient_, NEW_, rKey, dhKey)
  SUB -> e (Recipient_, SUB_)
  KEY k -> e (Recipient_, KEY_, k)
  NKEY k -> e (Recipient_, NKEY_, k)
  ACK -> e (Recipient_, ACK_)
  OFF -> e (Recipient_, OFF_)
  DEL -> e (Recipient_, DEL_)
  SEND msgBody -> e (Sender_, SEND_, LargeBS msgBody)
  PING -> e (Sender_, PING_)
  NSUB -> e (Notifier_, NSUB_)
  IDS (QIK rcvId sndId srvDh) -> e (Broker_, IDS_, rcvId, sndId, srvDh)
  MSG msgId ts msgBody -> e (Broker_, MSG_, msgId, ts, LargeBS msgBody)
  NID nId -> e (Broker_, NID_, nId)
  ERR err -> e (Broker_, ERR_, err)
  NMSG -> e (Broker_, NMSG_)
  END -> e (Broker_, END_)
  OK -> e (Broker_, OK_)
  PONG -> e (Broker_, PONG_)
  where
    e :: Encoding a => a -> ByteString
    e = smpEncode

clientCommandP :: Parser ClientCmd
clientCommandP =
  smpP >>= \case
    Recipient_ -> ClientCmd SRecipient <$> recipient
    Sender_ -> ClientCmd SSender <$> sender
    Notifier_ -> ClientCmd SNotifier <$> notifier
    Broker_ -> fail CMD_PROHIBITED
    _ -> fail CMD_UNKNOWN
  where
    recipient =
      smpP >>= \case
        NEW_ -> NEW <$> smpP <*> smpP
        SUB_ -> pure SUB
        KEY_ -> KEY <$> smpP
        NKEY_ -> NKEY <$> smpP
        ACK_ -> pure ACK
        OFF_ -> pure OFF
        DEL_ -> pure DEL
        _ -> fail CMD_UNKNOWN
    sender =
      smpP >>= \case
        SEND_ -> SEND . unLargeBS <$> smpP
        PING_ -> pure PING
        _ -> fail CMD_UNKNOWN
    notifier =
      smpP >>= \case
        NSUB_ -> pure NSUB
        _ -> fail CMD_UNKNOWN

brokerCommandP :: Parser (Command Broker)
brokerCommandP =
  smpP >>= \case
    Broker_ ->
      smpP >>= \case
        MSG_ -> MSG <$> smpP <*> smpP <*> (unLargeBS <$> smpP)
        IDS_ -> IDS <$> (QIK <$> smpP <*> smpP <*> smpP)
        NID_ -> NID <$> smpP
        ERR_ -> ERR <$> smpP
        NMSG_ -> pure NMSG
        END_ -> pure END
        OK_ -> pure OK
        PONG_ -> pure PONG
        _ -> fail CMD_UNKNOWN
    Recipient_ -> fail CMD_PROHIBITED
    Sender_ -> fail CMD_PROHIBITED
    Notifier_ -> fail CMD_PROHIBITED
    _ -> fail CMD_UNKNOWN

instance Encoding ErrorType where
  smpEncode = \case
    BLOCK -> e BLOCK_
    SESSION -> e SESSION_
    CMD err -> e (CMD_, err)
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
    PROHIBITED -> PROHIBITED_
    SYNTAX -> SYNTAX_
    NO_AUTH -> NO_AUTH_
    HAS_AUTH -> HAS_AUTH_
    NO_QUEUE -> NO_QUEUE_
  smpP =
    A.anyChar >>= \case
      UNKNOWN_ -> pure UNKNOWN
      PROHIBITED_ -> pure PROHIBITED
      SYNTAX_ -> pure SYNTAX
      NO_AUTH_ -> pure NO_AUTH
      HAS_AUTH_ -> pure HAS_AUTH
      NO_QUEUE_ -> pure NO_QUEUE
      _ -> fail "bad command error type"

-- | Send signed SMP transmission to TCP transport.
tPut :: Transport c => THandle c -> SentRawTransmission -> IO (Either TransportError ())
tPut th (sig, t) = tPutBlock th $ smpEncode (C.signatureBytes sig) <> t

encodeTransmission :: Encoding c => ByteString -> Transmission c -> ByteString
encodeTransmission sessionId (CorrId corrId, queueId, command) =
  smpEncode (sessionId, corrId, queueId, command)

-- | Receive and parse transmission from the TCP transport (ignoring any trailing padding).
tGetParse :: Transport c => THandle c -> IO (Either TransportError RawTransmission)
tGetParse th = (parse transmissionP TEBadBlock =<<) <$> tGetBlock th

-- | Receive client and server transmissions.
--
-- The first argument is used to limit allowed senders.
-- 'fromClient' or 'fromServer' should be used here.
tGet ::
  forall cmd c m.
  (Encoding cmd, CommandI cmd, Transport c, MonadIO m) =>
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
      let cmd = parseCommand command >>= tCredentials t
      return (sig, signed, (CorrId corrId, queueId, cmd))

    tCredentials :: SignedRawTransmission -> cmd -> Either ErrorType cmd
    tCredentials (sig, _, queueId, _) cmd = toCommand partyCredentials cmd
      where
        partyCredentials :: forall p. PartyI p => Command p -> Either ErrorType cmd
        partyCredentials c = case sParty @p of
          SBroker -> case c of
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
          _ -> case c of
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
