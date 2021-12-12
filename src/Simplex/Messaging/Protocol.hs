{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
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
  ( -- * SMP protocol types
    Command (..),
    Party (..),
    Cmd (..),
    SParty (..),
    QueueIdsKeys (..),
    ErrorType (..),
    CommandError (..),
    Transmission,
    SignedTransmission,
    SignedTransmissionOrError,
    RawTransmission,
    SentRawTransmission,
    SignedRawTransmission,
    CorrId (..),
    QueueId,
    RecipientId,
    SenderId,
    NotifierId,
    RcvPrivateSignKey,
    RcvPublicVerifyKey,
    RcvPublicDHKey,
    RcvDHSecret,
    SndPrivateSignKey,
    SndPublicVerifyKey,
    NtfPrivateSignKey,
    NtfPublicVerifyKey,
    Encoded,
    MsgId,
    MsgBody,

    -- * Parse and serialize
    serializeTransmission,
    serializeCommand,
    serializeErrorType,
    transmissionP,
    commandP,
    errorTypeP,

    -- * TCP transport functions
    tPut,
    tGet,
    fromClient,
    fromServer,
  )
where

import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.Except
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Kind
import Data.Maybe (isNothing)
import Data.String
import Data.Time.Clock
import Data.Time.ISO8601
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers
import Simplex.Messaging.Transport (THandle, Transport, TransportError (..), tGetEncrypted, tPutEncrypted)
import Simplex.Messaging.Util
import Test.QuickCheck (Arbitrary (..))

-- | SMP protocol participants.
data Party = Broker | Recipient | Sender | Notifier
  deriving (Show)

-- | Singleton types for SMP protocol participants.
data SParty :: Party -> Type where
  SBroker :: SParty Broker
  SRecipient :: SParty Recipient
  SSender :: SParty Sender
  SNotifier :: SParty Notifier

deriving instance Show (SParty a)

-- | Type for command or response of any participant.
data Cmd = forall a. Cmd (SParty a) (Command a)

deriving instance Show Cmd

-- | SMP transmission without signature.
type Transmission = (CorrId, QueueId, Cmd)

-- | SMP transmission with signature.
type SignedTransmission = (Maybe C.ASignature, Transmission)

type TransmissionOrError = (CorrId, QueueId, Either ErrorType Cmd)

-- | signed parsed transmission, with parsing error.
type SignedTransmissionOrError = (Maybe C.ASignature, TransmissionOrError)

-- | unparsed SMP transmission with signature.
type RawTransmission = (ByteString, ByteString, ByteString, ByteString)

-- | unparsed sent SMP transmission with signature.
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
  NEW :: RcvPublicVerifyKey -> RcvPublicDHKey -> Command Recipient
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

-- | Base-64 encoded string.
type Encoded = ByteString

-- | Transmission correlation ID.
--
-- A newtype to avoid accidentally changing order of transmission parts.
newtype CorrId = CorrId {bs :: ByteString} deriving (Eq, Ord, Show)

instance IsString CorrId where
  fromString = CorrId . fromString

-- | Queue IDs and keys
data QueueIdsKeys = QIK
  { rcvId :: RecipientId,
    rcvSrvVerifyKey :: RcvPublicVerifyKey,
    rcvPublicDHKey :: RcvPublicDHKey,
    sndId :: SenderId,
    sndSrvVerifyKey :: SndPublicVerifyKey
  }
  deriving (Eq, Show)

-- | Recipient's private key used by the recipient to authorize (sign) SMP commands.
--
-- Only used by SMP agent, kept here so its definition is close to respective public key.
type RcvPrivateSignKey = C.APrivateSignKey

-- | Recipient's public key used by SMP server to verify authorization of SMP commands.
type RcvPublicVerifyKey = C.APublicVerifyKey

-- | Public key used for DH exchange to encrypt message bodies from server to recipient
type RcvPublicDHKey = C.PublicKey C.X25519

-- | DH Secret used to encrypt message bodies from server to recipient
type RcvDHSecret = C.DhSecret C.X25519

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
  | -- | SMP command is unknown or has invalid syntax
    CMD CommandError
  | -- | command authorization error - bad signature or non-existing SMP queue
    AUTH
  | -- | SMP queue capacity is exceeded on the server
    QUOTA
  | -- | ACK command is sent without message to be acknowledged
    NO_MSG
  | -- | internal server error
    INTERNAL
  | -- | used internally, never returned by the server (to be removed)
    DUPLICATE_ -- TODO remove, not part of SMP protocol
  deriving (Eq, Generic, Read, Show)

-- | SMP command error type.
data CommandError
  = -- | server response sent from client or vice versa
    PROHIBITED
  | -- | bad RSA key size in NEW or KEY commands (only 1024, 2048 and 4096 bits keys are allowed)
    KEY_SIZE
  | -- | error parsing command
    SYNTAX
  | -- | transmission has no required credentials (signature or queue ID)
    NO_AUTH
  | -- | transmission has credentials that are not allowed for this command
    HAS_AUTH
  | -- | transmission has no required queue ID
    NO_QUEUE
  deriving (Eq, Generic, Read, Show)

instance Arbitrary ErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandError where arbitrary = genericArbitraryU

-- | SMP transmission parser.
transmissionP :: Parser RawTransmission
transmissionP = do
  sig <- segment
  corrId <- segment
  queueId <- segment
  command <- A.takeByteString
  return (sig, corrId, queueId, command)
  where
    segment = A.takeTill (== ' ') <* " "

-- | SMP command parser.
commandP :: Parser Cmd
commandP =
  "NEW " *> newCmd
    <|> "IDS " *> idsResp
    <|> "SUB" $> Cmd SRecipient SUB
    <|> "KEY " *> keyCmd
    <|> "NKEY " *> nKeyCmd
    <|> "NID " *> nIdsResp
    <|> "ACK" $> Cmd SRecipient ACK
    <|> "OFF" $> Cmd SRecipient OFF
    <|> "DEL" $> Cmd SRecipient DEL
    <|> "SEND " *> sendCmd
    <|> "PING" $> Cmd SSender PING
    <|> "NSUB" $> Cmd SNotifier NSUB
    <|> "MSG " *> message
    <|> "NMSG" $> Cmd SBroker NMSG
    <|> "END" $> Cmd SBroker END
    <|> "OK" $> Cmd SBroker OK
    <|> "ERR " *> serverError
    <|> "PONG" $> Cmd SBroker PONG
  where
    newCmd = Cmd SRecipient <$> (NEW <$> C.strKeyP <* A.space <*> C.strKeyP)
    idsResp = Cmd SBroker . IDS <$> qik
    qik = do
      rcvId <- base64P <* A.space
      rcvSrvVerifyKey <- C.strKeyP <* A.space
      rcvPublicDHKey <- C.strKeyP <* A.space
      sndId <- base64P <* A.space
      sndSrvVerifyKey <- C.strKeyP
      pure QIK {rcvId, rcvSrvVerifyKey, rcvPublicDHKey, sndId, sndSrvVerifyKey}
    nIdsResp = Cmd SBroker . NID <$> base64P
    keyCmd = Cmd SRecipient . KEY <$> C.strKeyP
    nKeyCmd = Cmd SRecipient . NKEY <$> C.strKeyP
    sendCmd = do
      size <- A.decimal <* A.space
      Cmd SSender . SEND <$> A.take size <* A.space
    message = do
      msgId <- base64P <* A.space
      ts <- tsISO8601P <* A.space
      size <- A.decimal <* A.space
      Cmd SBroker . MSG msgId ts <$> A.take size <* A.space
    serverError = Cmd SBroker . ERR <$> errorTypeP

-- TODO ignore the end of block, no need to parse it

-- | Parse SMP command.
parseCommand :: ByteString -> Either ErrorType Cmd
parseCommand = parse (commandP <* " " <* A.takeByteString) $ CMD SYNTAX

-- | Serialize SMP command.
serializeCommand :: Cmd -> ByteString
serializeCommand = \case
  Cmd SRecipient (NEW rKey dhKey) -> B.unwords ["NEW", C.serializeKey rKey, C.serializeKey dhKey]
  Cmd SRecipient (KEY sKey) -> "KEY " <> C.serializeKey sKey
  Cmd SRecipient (NKEY nKey) -> "NKEY " <> C.serializeKey nKey
  Cmd SRecipient SUB -> "SUB"
  Cmd SRecipient ACK -> "ACK"
  Cmd SRecipient OFF -> "OFF"
  Cmd SRecipient DEL -> "DEL"
  Cmd SSender (SEND msgBody) -> "SEND " <> serializeMsg msgBody
  Cmd SSender PING -> "PING"
  Cmd SNotifier NSUB -> "NSUB"
  Cmd SBroker (MSG msgId ts msgBody) ->
    B.unwords ["MSG", encode msgId, B.pack $ formatISO8601Millis ts, serializeMsg msgBody]
  Cmd SBroker (IDS QIK {rcvId, rcvSrvVerifyKey = rsKey, rcvPublicDHKey = dhKey, sndId, sndSrvVerifyKey = ssKey}) ->
    B.unwords ["IDS", encode rcvId, C.serializeKey rsKey, C.serializeKey dhKey, encode sndId, C.serializeKey ssKey]
  Cmd SBroker (NID nId) -> "NID " <> encode nId
  Cmd SBroker (ERR err) -> "ERR " <> serializeErrorType err
  Cmd SBroker NMSG -> "NMSG"
  Cmd SBroker END -> "END"
  Cmd SBroker OK -> "OK"
  Cmd SBroker PONG -> "PONG"
  where
    serializeMsg msgBody = bshow (B.length msgBody) <> " " <> msgBody <> " "

-- | SMP error parser.
errorTypeP :: Parser ErrorType
errorTypeP = "CMD " *> (CMD <$> parseRead1) <|> parseRead1

-- | Serialize SMP error.
serializeErrorType :: ErrorType -> ByteString
serializeErrorType = bshow

-- | Send signed SMP transmission to TCP transport.
tPut :: Transport c => THandle c -> SentRawTransmission -> IO (Either TransportError ())
tPut th (sig, t) =
  tPutEncrypted th $ C.serializeSignature sig <> " " <> t <> " "

-- | Serialize SMP transmission.
serializeTransmission :: Transmission -> ByteString
serializeTransmission (CorrId corrId, queueId, command) =
  B.intercalate " " [corrId, encode queueId, serializeCommand command]

-- | Validate that it is an SMP client command, used with 'tGet' by 'Simplex.Messaging.Server'.
fromClient :: Cmd -> Either ErrorType Cmd
fromClient = \case
  Cmd SBroker _ -> Left $ CMD PROHIBITED
  cmd -> Right cmd

-- | Validate that it is an SMP server command, used with 'tGet' by 'Simplex.Messaging.Client'.
fromServer :: Cmd -> Either ErrorType Cmd
fromServer = \case
  cmd@(Cmd SBroker _) -> Right cmd
  _ -> Left $ CMD PROHIBITED

-- | Receive and parse transmission from the TCP transport.
tGetParse :: Transport c => THandle c -> IO (Either TransportError RawTransmission)
tGetParse th = (>>= parse transmissionP TEBadBlock) <$> tGetEncrypted th

-- | Receive client and server transmissions.
--
-- The first argument is used to limit allowed senders.
-- 'fromClient' or 'fromServer' should be used here.
tGet :: forall c m. (Transport c, MonadIO m) => (Cmd -> Either ErrorType Cmd) -> THandle c -> m SignedTransmissionOrError
tGet fromParty th = liftIO (tGetParse th) >>= decodeParseValidate
  where
    decodeParseValidate :: Either TransportError RawTransmission -> m SignedTransmissionOrError
    decodeParseValidate = \case
      Right (sig, corrId, queueId, command) ->
        let decodedTransmission = liftM2 (,corrId,,command) (C.decodeSignature =<< decode sig) (decode queueId)
         in either (const $ tError corrId) tParseValidate decodedTransmission
      Left _ -> tError ""

    tError :: ByteString -> m SignedTransmissionOrError
    tError corrId = return (Nothing, (CorrId corrId, "", Left BLOCK))

    tParseValidate :: SignedRawTransmission -> m SignedTransmissionOrError
    tParseValidate t@(sig, corrId, queueId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tCredentials t
      return (sig, (CorrId corrId, queueId, cmd))

    tCredentials :: SignedRawTransmission -> Cmd -> Either ErrorType Cmd
    tCredentials (sig, _, queueId, _) cmd = case cmd of
      -- IDS response must not have queue ID
      Cmd SBroker IDS {} -> Right cmd
      -- ERR response does not always have queue ID
      Cmd SBroker (ERR _) -> Right cmd
      -- PONG response must not have queue ID
      Cmd SBroker PONG
        | B.null queueId -> Right cmd
        | otherwise -> Left $ CMD HAS_AUTH
      -- other responses must have queue ID
      Cmd SBroker _
        | B.null queueId -> Left $ CMD NO_QUEUE
        | otherwise -> Right cmd
      -- NEW must have signature but NOT queue ID
      Cmd SRecipient NEW {}
        | isNothing sig -> Left $ CMD NO_AUTH
        | not (B.null queueId) -> Left $ CMD HAS_AUTH
        | otherwise -> Right cmd
      -- SEND must have queue ID, signature is not always required
      Cmd SSender (SEND _)
        | B.null queueId -> Left $ CMD NO_QUEUE
        | otherwise -> Right cmd
      -- PING must not have queue ID or signature
      Cmd SSender PING
        | isNothing sig && B.null queueId -> Right cmd
        | otherwise -> Left $ CMD HAS_AUTH
      -- other client commands must have both signature and queue ID
      Cmd _ _
        | isNothing sig || B.null queueId -> Left $ CMD NO_AUTH
        | otherwise -> Right cmd
