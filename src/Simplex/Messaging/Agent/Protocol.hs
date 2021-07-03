{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

-- |
-- Module      : Simplex.Messaging.Agent.Protocol
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- Types, parsers, serializers and functions to send and receive SMP agent protocol commands and responses.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md
module Simplex.Messaging.Agent.Protocol
  ( -- * SMP agent protocol types
    ConnInfo,
    ACommand (..),
    AParty (..),
    SAParty (..),
    MsgMeta (..),
    SMPMessage (..),
    AMessage (..),
    SMPServer (..),
    SMPQueueInfo (..),
    AgentErrorType (..),
    CommandErrorType (..),
    ConnectionErrorType (..),
    BrokerErrorType (..),
    SMPAgentError (..),
    ATransmission,
    ATransmissionOrError,
    ARawTransmission,
    ConnId,
    ConfirmationId,
    IntroId,
    InvitationId,
    AckMode (..),
    OnOff (..),
    MsgIntegrity (..),
    MsgErrorType (..),
    QueueStatus (..),
    SignatureKey,
    VerificationKey,
    EncryptionKey,
    DecryptionKey,
    ACorrId,
    AgentMsgId,

    -- * Parse and serialize
    serializeCommand,
    serializeSMPMessage,
    serializeMsgIntegrity,
    serializeServer,
    serializeSmpQueueInfo,
    serializeAgentError,
    commandP,
    parseSMPMessage,
    smpServerP,
    smpQueueInfoP,
    msgIntegrityP,
    agentErrorTypeP,

    -- * TCP transport functions
    tPut,
    tGet,
    tPutRaw,
    tGetRaw,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad.IO.Class
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind (Type)
import Data.String (IsString (..))
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( ErrorType,
    MsgBody,
    MsgId,
    SenderPublicKey,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (Transport (..), TransportError, serializeTransportError, transportErrorP)
import Simplex.Messaging.Util
import Test.QuickCheck (Arbitrary (..))
import Text.Read
import UnliftIO.Exception

-- | Raw (unparsed) SMP agent protocol transmission.
type ARawTransmission = (ByteString, ByteString, ByteString)

-- | Parsed SMP agent protocol transmission.
type ATransmission p = (ACorrId, ConnId, ACommand p)

-- | SMP agent protocol transmission or transmission error.
type ATransmissionOrError p = (ACorrId, ConnId, Either AgentErrorType (ACommand p))

type ACorrId = ByteString

-- | SMP agent protocol participants.
data AParty = Agent | Client
  deriving (Eq, Show)

-- | Singleton types for SMP agent protocol participants.
data SAParty :: AParty -> Type where
  SAgent :: SAParty Agent
  SClient :: SAParty Client

deriving instance Show (SAParty p)

deriving instance Eq (SAParty p)

instance TestEquality SAParty where
  testEquality SAgent SAgent = Just Refl
  testEquality SClient SClient = Just Refl
  testEquality _ _ = Nothing

data ACmd = forall p. ACmd (SAParty p) (ACommand p)

deriving instance Show ACmd

type ConnInfo = ByteString

-- | Parameterized type for SMP agent protocol commands and responses from all participants.
data ACommand (p :: AParty) where
  NEW :: ACommand Client -- response INV
  INV :: SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> ConnInfo -> ACommand Client -- response OK
  CONF :: ConfirmationId -> ConnInfo -> ACommand Agent -- ConnInfo is from sender
  LET :: ConfirmationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  INTRO :: ConnId -> ConnInfo -> ACommand Client
  REQ :: InvitationId -> ConnInfo -> ACommand Agent
  ACPT :: InvitationId -> ConnInfo -> ACommand Client
  INFO :: ConnInfo -> ACommand Agent
  CON :: ACommand Agent -- notification that connection is established
  ICON :: ConnId -> ACommand Agent
  SUB :: ACommand Client
  END :: ACommand Agent
  -- QST :: QueueDirection -> ACommand Client
  -- STAT :: QueueDirection -> Maybe QueueStatus -> Maybe SubMode -> ACommand Agent
  SEND :: MsgBody -> ACommand Client
  SENT :: AgentMsgId -> ACommand Agent
  MSG :: MsgMeta -> MsgBody -> ACommand Agent
  -- ACK :: AgentMsgId -> ACommand Client
  -- RCVD :: AgentMsgId -> ACommand Agent
  OFF :: ACommand Client
  DEL :: ACommand Client
  OK :: ACommand Agent
  ERR :: AgentErrorType -> ACommand Agent

deriving instance Eq (ACommand p)

deriving instance Show (ACommand p)

-- | Agent message metadata sent to the client
data MsgMeta = MsgMeta
  { integrity :: MsgIntegrity,
    recipient :: (AgentMsgId, UTCTime),
    broker :: (MsgId, UTCTime),
    sender :: (AgentMsgId, UTCTime)
  }
  deriving (Eq, Show)

-- | SMP message formats.
data SMPMessage
  = -- | SMP confirmation
    -- (see <https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#send-message SMP protocol>)
    SMPConfirmation
      { -- | sender's public key to use for authentication of sender's commands at the recepient's server
        senderKey :: SenderPublicKey,
        -- | sender's information to be associated with the connection, e.g. sender's profile information
        connInfo :: ConnInfo
      }
  | -- | Agent message header and envelope for client messages
    -- (see <https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents SMP agent protocol>)
    SMPMessage
      { -- | sequential ID assigned by the sending agent
        senderMsgId :: AgentMsgId,
        -- | timestamp from the sending agent
        senderTimestamp :: SenderTimestamp,
        -- | digest of the previous message
        previousMsgHash :: ByteString,
        -- | messages sent between agents once queue is secured
        agentMessage :: AMessage
      }
  deriving (Show)

-- | Messages sent between SMP agents once SMP queue is secured.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents
data AMessage where
  -- | the first message in the queue to validate it is secured
  HELLO :: VerificationKey -> AckMode -> AMessage
  -- | reply queue information
  REPLY :: SMPQueueInfo -> AMessage
  -- | agent envelope for the client message
  A_MSG :: MsgBody -> AMessage
  -- | agent message for introduction
  A_INTRO :: IntroId -> ConnInfo -> AMessage
  -- | agent envelope for the sent invitation
  A_INV :: IntroId -> SMPQueueInfo -> ConnInfo -> AMessage
  -- | agent envelope for the forwarded invitation
  A_REQ :: IntroId -> SMPQueueInfo -> ConnInfo -> AMessage
  -- | agent message for intro/group request
  A_CON :: IntroId -> AMessage
  deriving (Show)

-- | Parse SMP message.
parseSMPMessage :: ByteString -> Either AgentErrorType SMPMessage
parseSMPMessage = parse (smpMessageP <* A.endOfLine) $ AGENT A_MESSAGE
  where
    smpMessageP :: Parser SMPMessage
    smpMessageP = A.endOfLine *> smpClientMessageP <|> smpConfirmationP

    smpConfirmationP :: Parser SMPMessage
    smpConfirmationP = "KEY " *> (SMPConfirmation <$> C.pubKeyP <* A.endOfLine <* A.endOfLine <*> binaryBodyP <* A.endOfLine)

    smpClientMessageP :: Parser SMPMessage
    smpClientMessageP =
      SMPMessage
        <$> A.decimal <* A.space
        <*> tsISO8601P <* A.space
        -- TODO previous message hash should become mandatory when we support HELLO and REPLY
        -- (for HELLO it would be the hash of SMPConfirmation)
        <*> (base64P <|> pure "") <* A.endOfLine
        <*> agentMessageP

-- | Serialize SMP message.
serializeSMPMessage :: SMPMessage -> ByteString
serializeSMPMessage = \case
  SMPConfirmation sKey cInfo -> smpMessage ("KEY " <> C.serializePubKey sKey) "" (serializeBinary cInfo) <> "\n"
  SMPMessage {senderMsgId, senderTimestamp, previousMsgHash, agentMessage} ->
    let header = messageHeader senderMsgId senderTimestamp previousMsgHash
        body = serializeAgentMessage agentMessage
     in smpMessage "" header body
  where
    messageHeader msgId ts prevMsgHash =
      B.unwords [bshow msgId, B.pack $ formatISO8601Millis ts, encode prevMsgHash]
    smpMessage smpHeader aHeader aBody = B.intercalate "\n" [smpHeader, aHeader, aBody, ""]

agentMessageP :: Parser AMessage
agentMessageP =
  "HELLO " *> hello
    <|> "REPLY " *> reply
    <|> "MSG " *> a_msg
    <|> "INTRO " *> a_intro
    <|> "INV " *> a_inv
    <|> "REQ " *> a_req
    <|> "CON " *> a_con
  where
    hello = HELLO <$> C.pubKeyP <*> ackMode
    reply = REPLY <$> smpQueueInfoP
    a_msg = A_MSG <$> binaryBodyP <* A.endOfLine
    a_intro = A_INTRO <$> A.takeTill (== ' ') <* A.space <*> binaryBodyP <* A.endOfLine
    a_inv = invP A_INV
    a_req = invP A_REQ
    a_con = A_CON <$> A.takeTill wordEnd
    invP f = f <$> A.takeTill (== ' ') <* A.space <*> smpQueueInfoP <* A.space <*> binaryBodyP <* A.endOfLine
    ackMode = AckMode <$> (" NO_ACK" $> Off <|> pure On)

-- | SMP queue information parser.
smpQueueInfoP :: Parser SMPQueueInfo
smpQueueInfoP =
  "smp::" *> (SMPQueueInfo <$> smpServerP <* "::" <*> base64P <* "::" <*> C.pubKeyP)

-- | SMP server location parser.
smpServerP :: Parser SMPServer
smpServerP = SMPServer <$> server <*> optional port <*> optional kHash
  where
    server = B.unpack <$> A.takeWhile1 (A.notInClass ":# ")
    port = A.char ':' *> (B.unpack <$> A.takeWhile1 A.isDigit)
    kHash = C.KeyHash <$> (A.char '#' *> base64P)

serializeAgentMessage :: AMessage -> ByteString
serializeAgentMessage = \case
  HELLO verifyKey ackMode -> "HELLO " <> C.serializePubKey verifyKey <> if ackMode == AckMode Off then " NO_ACK" else ""
  REPLY qInfo -> "REPLY " <> serializeSmpQueueInfo qInfo
  A_MSG body -> "MSG " <> serializeBinary body <> "\n"
  A_INTRO introId cInfo -> "INTRO " <> introId <> " " <> serializeBinary cInfo <> "\n"
  A_INV introId qInfo cInfo -> "INV " <> serializeInv introId qInfo cInfo
  A_REQ introId qInfo cInfo -> "REQ " <> serializeInv introId qInfo cInfo
  A_CON introId -> "CON " <> introId
  where
    serializeInv introId qInfo cInfo =
      B.intercalate " " [introId, serializeSmpQueueInfo qInfo, serializeBinary cInfo] <> "\n"

-- | Serialize SMP queue information that is sent out-of-band.
serializeSmpQueueInfo :: SMPQueueInfo -> ByteString
serializeSmpQueueInfo (SMPQueueInfo srv qId ek) =
  B.intercalate "::" ["smp", serializeServer srv, encode qId, C.serializePubKey ek]

-- | Serialize SMP server location.
serializeServer :: SMPServer -> ByteString
serializeServer SMPServer {host, port, keyHash} =
  B.pack $ host <> maybe "" (':' :) port <> maybe "" (('#' :) . B.unpack . encode . C.unKeyHash) keyHash

-- | SMP server location and transport key digest (hash).
data SMPServer = SMPServer
  { host :: HostName,
    port :: Maybe ServiceName,
    keyHash :: Maybe C.KeyHash
  }
  deriving (Eq, Ord, Show)

instance IsString SMPServer where
  fromString = parseString . parseAll $ smpServerP

-- | SMP agent connection alias.
type ConnId = ByteString

type ConfirmationId = ByteString

type IntroId = ByteString

type InvitationId = ByteString

-- | Connection modes.
data OnOff = On | Off deriving (Eq, Show, Read)

-- | Message acknowledgement mode of the connection.
newtype AckMode = AckMode OnOff deriving (Eq, Show)

-- | SMP queue information sent out-of-band.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#out-of-band-messages
data SMPQueueInfo = SMPQueueInfo SMPServer SMP.SenderId EncryptionKey
  deriving (Eq, Show)

-- | Public key used to E2E encrypt SMP messages.
type EncryptionKey = C.PublicKey

-- | Private key used to E2E decrypt SMP messages.
type DecryptionKey = C.SafePrivateKey

-- | Private key used to sign SMP commands
type SignatureKey = C.APrivateKey

-- | Public key used by SMP server to authorize (verify) SMP commands.
type VerificationKey = C.PublicKey

data QueueDirection = SND | RCV deriving (Show)

-- | SMP queue status.
data QueueStatus
  = -- | queue is created
    New
  | -- | queue is confirmed by the sender
    Confirmed
  | -- | queue is secured with sender key (only used by the queue recipient)
    Secured
  | -- | queue is active
    Active
  | -- | queue is disabled (only used by the queue recipient)
    Disabled
  deriving (Eq, Show, Read)

type AgentMsgId = Int64

type SenderTimestamp = UTCTime

-- | Result of received message integrity validation.
data MsgIntegrity = MsgOk | MsgError MsgErrorType
  deriving (Eq, Show)

-- | Error of message integrity validation.
data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash | MsgDuplicate
  deriving (Eq, Show)

-- | Error type used in errors sent to agent clients.
data AgentErrorType
  = -- | command or response error
    CMD CommandErrorType
  | -- | connection errors
    CONN ConnectionErrorType
  | -- | SMP protocol errors forwarded to agent clients
    SMP ErrorType
  | -- | SMP server errors
    BROKER BrokerErrorType
  | -- | errors of other agents
    AGENT SMPAgentError
  | -- | agent implementation or dependency errors
    INTERNAL String
  deriving (Eq, Generic, Read, Show, Exception)

-- | SMP agent protocol command or response error.
data CommandErrorType
  = -- | command is prohibited in this context
    PROHIBITED
  | -- | command syntax is invalid
    SYNTAX
  | -- | entity ID is required with this command
    NO_CONN
  | -- | message size is not correct (no terminating space)
    SIZE
  | -- | message does not fit in SMP block
    LARGE
  deriving (Eq, Generic, Read, Show, Exception)

-- | Connection error.
data ConnectionErrorType
  = -- | connection alias is not in the database
    NOT_FOUND
  | -- | connection alias already exists
    DUPLICATE
  | -- | connection is simplex, but operation requires another queue
    SIMPLEX
  deriving (Eq, Generic, Read, Show, Exception)

-- | SMP server errors.
data BrokerErrorType
  = -- | invalid server response (failed to parse)
    RESPONSE ErrorType
  | -- | unexpected response
    UNEXPECTED
  | -- | network error
    NETWORK
  | -- | handshake or other transport error
    TRANSPORT TransportError
  | -- | command response timeout
    TIMEOUT
  deriving (Eq, Generic, Read, Show, Exception)

-- | Errors of another SMP agent.
data SMPAgentError
  = -- | possibly should include bytestring that failed to parse
    A_MESSAGE
  | -- | possibly should include the prohibited SMP/agent message
    A_PROHIBITED
  | -- | cannot RSA/AES-decrypt or parse decrypted header
    A_ENCRYPTION
  | -- | invalid RSA signature
    A_SIGNATURE
  deriving (Eq, Generic, Read, Show, Exception)

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

-- | SMP agent command and response parser
commandP :: Parser ACmd
commandP =
  "NEW" $> ACmd SClient NEW
    <|> "INV " *> invResp
    <|> "JOIN " *> joinCmd
    <|> "CONF " *> confCmd
    <|> "LET " *> letCmd
    <|> "INTRO " *> introCmd
    <|> "REQ " *> reqCmd
    <|> "ACPT " *> acptCmd
    <|> "INFO " *> infoCmd
    <|> "SUB" $> ACmd SClient SUB
    <|> "END" $> ACmd SAgent END
    <|> "SEND " *> sendCmd
    <|> "SENT " *> sentResp
    <|> "MSG " *> message
    <|> "OFF" $> ACmd SClient OFF
    <|> "DEL" $> ACmd SClient DEL
    <|> "ERR " *> agentError
    <|> "ICON " *> iconMsg
    <|> "CON" $> ACmd SAgent CON
    <|> "OK" $> ACmd SAgent OK
  where
    invResp = ACmd SAgent . INV <$> smpQueueInfoP
    joinCmd = ACmd SClient <$> (JOIN <$> smpQueueInfoP <* A.space <*> A.takeByteString)
    confCmd = ACmd SAgent <$> (CONF <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    letCmd = ACmd SClient <$> (LET <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    introCmd = ACmd SClient <$> introP INTRO
    reqCmd = ACmd SAgent <$> introP REQ
    acptCmd = ACmd SClient <$> introP ACPT
    infoCmd = ACmd SAgent . INFO <$> A.takeByteString
    sendCmd = ACmd SClient . SEND <$> A.takeByteString
    sentResp = ACmd SAgent . SENT <$> A.decimal
    iconMsg = ACmd SAgent . ICON <$> A.takeTill wordEnd
    message = ACmd SAgent <$> (MSG <$> msgMetaP <* A.space <*> A.takeByteString)
    msgMetaP = do
      integrity <- msgIntegrityP
      recipient <- " R=" *> partyMeta A.decimal
      broker <- " B=" *> partyMeta base64P
      sender <- " S=" *> partyMeta A.decimal
      pure MsgMeta {integrity, recipient, broker, sender}
    introP f = f <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString
    partyMeta idParser = (,) <$> idParser <* "," <*> tsISO8601P
    agentError = ACmd SAgent . ERR <$> agentErrorTypeP

-- | Message integrity validation result parser.
msgIntegrityP :: Parser MsgIntegrity
msgIntegrityP = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> msgErrorType)
  where
    msgErrorType =
      "ID " *> (MsgBadId <$> A.decimal)
        <|> "IDS " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
        <|> "HASH" $> MsgBadHash
        <|> "DUPLICATE" $> MsgDuplicate

parseCommand :: ByteString -> Either AgentErrorType ACmd
parseCommand = parse commandP $ CMD SYNTAX

-- | Serialize SMP agent command.
serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW -> "NEW"
  INV qInfo -> "INV " <> serializeSmpQueueInfo qInfo
  JOIN qInfo cInfo -> "JOIN " <> serializeSmpQueueInfo qInfo <> " " <> serializeBinary cInfo
  CONF confId cInfo -> "CONF " <> confId <> " " <> serializeBinary cInfo
  LET confId cInfo -> "LET " <> confId <> " " <> serializeBinary cInfo
  INTRO connId cInfo -> "INTRO " <> connId <> " " <> serializeBinary cInfo
  REQ invId cInfo -> "REQ " <> invId <> " " <> serializeBinary cInfo
  ACPT invId cInfo -> "ACPT " <> invId <> " " <> serializeBinary cInfo
  INFO cInfo -> "INFO " <> serializeBinary cInfo
  SUB -> "SUB"
  END -> "END"
  SEND msgBody -> "SEND " <> serializeBinary msgBody
  SENT mId -> "SENT " <> bshow mId
  MSG msgMeta msgBody ->
    "MSG " <> serializeMsgMeta msgMeta <> " " <> serializeBinary msgBody
  OFF -> "OFF"
  DEL -> "DEL"
  CON -> "CON"
  ICON connId -> "ICON " <> connId
  ERR e -> "ERR " <> serializeAgentError e
  OK -> "OK"
  where
    showTs :: UTCTime -> ByteString
    showTs = B.pack . formatISO8601Millis
    serializeMsgMeta :: MsgMeta -> ByteString
    serializeMsgMeta MsgMeta {integrity, recipient = (rmId, rTs), broker = (bmId, bTs), sender = (smId, sTs)} =
      B.unwords
        [ serializeMsgIntegrity integrity,
          "R=" <> bshow rmId <> "," <> showTs rTs,
          "B=" <> encode bmId <> "," <> showTs bTs,
          "S=" <> bshow smId <> "," <> showTs sTs
        ]

-- | Serialize message integrity validation result.
serializeMsgIntegrity :: MsgIntegrity -> ByteString
serializeMsgIntegrity = \case
  MsgOk -> "OK"
  MsgError e ->
    "ERR " <> case e of
      MsgSkipped fromMsgId toMsgId ->
        B.unwords ["NO_ID", bshow fromMsgId, bshow toMsgId]
      MsgBadId aMsgId -> "ID " <> bshow aMsgId
      MsgBadHash -> "HASH"
      MsgDuplicate -> "DUPLICATE"

-- | SMP agent protocol error parser.
agentErrorTypeP :: Parser AgentErrorType
agentErrorTypeP =
  "SMP " *> (SMP <$> SMP.errorTypeP)
    <|> "BROKER RESPONSE " *> (BROKER . RESPONSE <$> SMP.errorTypeP)
    <|> "BROKER TRANSPORT " *> (BROKER . TRANSPORT <$> transportErrorP)
    <|> "INTERNAL " *> (INTERNAL <$> parseRead A.takeByteString)
    <|> parseRead2

-- | Serialize SMP agent protocol error.
serializeAgentError :: AgentErrorType -> ByteString
serializeAgentError = \case
  SMP e -> "SMP " <> SMP.serializeErrorType e
  BROKER (RESPONSE e) -> "BROKER RESPONSE " <> SMP.serializeErrorType e
  BROKER (TRANSPORT e) -> "BROKER TRANSPORT " <> serializeTransportError e
  e -> bshow e

binaryBodyP :: Parser ByteString
binaryBodyP = do
  size :: Int <- A.decimal <* A.endOfLine
  A.take size

serializeBinary :: ByteString -> ByteString
serializeBinary body = bshow (B.length body) <> "\n" <> body

-- | Send raw (unparsed) SMP agent protocol transmission to TCP connection.
tPutRaw :: Transport c => c -> ARawTransmission -> IO ()
tPutRaw h (corrId, entity, command) = do
  putLn h corrId
  putLn h entity
  putLn h command

-- | Receive raw (unparsed) SMP agent protocol transmission from TCP connection.
tGetRaw :: Transport c => c -> IO ARawTransmission
tGetRaw h = (,,) <$> getLn h <*> getLn h <*> getLn h

-- | Send SMP agent protocol command (or response) to TCP connection.
tPut :: (Transport c, MonadIO m) => c -> ATransmission p -> m ()
tPut h (corrId, connAlias, command) =
  liftIO $ tPutRaw h (corrId, connAlias, serializeCommand command)

-- | Receive client and agent transmissions from TCP connection.
tGet :: forall c m p. (Transport c, MonadIO m) => SAParty p -> c -> m (ATransmissionOrError p)
tGet party h = liftIO (tGetRaw h) >>= tParseLoadBody
  where
    tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
    tParseLoadBody t@(corrId, connId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tConnId t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (corrId, connId, fullCmd)

    fromParty :: ACmd -> Either AgentErrorType (ACommand p)
    fromParty (ACmd (p :: p1) cmd) = case testEquality party p of
      Just Refl -> Right cmd
      _ -> Left $ CMD PROHIBITED

    tConnId :: ARawTransmission -> ACommand p -> Either AgentErrorType (ACommand p)
    tConnId (_, connId, _) cmd = case cmd of
      -- NEW, JOIN and ACPT have optional connId
      NEW -> Right cmd
      JOIN {} -> Right cmd
      ACPT {} -> Right cmd
      -- ERROR response does not always have connId
      ERR _ -> Right cmd
      -- other responses must have connId
      _
        | B.null connId -> Left $ CMD NO_CONN
        | otherwise -> Right cmd

    cmdWithMsgBody :: ACommand p -> m (Either AgentErrorType (ACommand p))
    cmdWithMsgBody = \case
      SEND body -> SEND <$$> getBody body
      MSG msgMeta body -> MSG msgMeta <$$> getBody body
      INTRO introId cInfo -> INTRO introId <$$> getBody cInfo
      REQ introId cInfo -> REQ introId <$$> getBody cInfo
      ACPT introId cInfo -> ACPT introId <$$> getBody cInfo
      JOIN qInfo cInfo -> JOIN qInfo <$$> getBody cInfo
      CONF confId cInfo -> CONF confId <$$> getBody cInfo
      LET confId cInfo -> LET confId <$$> getBody cInfo
      INFO cInfo -> INFO <$$> getBody cInfo
      cmd -> pure $ Right cmd

    -- TODO refactor with server
    getBody :: ByteString -> m (Either AgentErrorType ByteString)
    getBody binary =
      case B.unpack binary of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> liftIO $ do
            body <- cGet h size
            s <- getLn h
            return $ if B.null s then Right body else Left $ CMD SIZE
          Nothing -> return . Left $ CMD SYNTAX
