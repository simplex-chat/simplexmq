{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
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
    MsgHash,
    MsgMeta (..),
    SMPConfirmation (..),
    AgentMessage (..),
    AHeader (..),
    AMessage (..),
    SMPServer (..),
    SMPQueueUri (..),
    ConnectionMode (..),
    SConnectionMode (..),
    AConnectionMode (..),
    cmInvitation,
    cmContact,
    ConnectionModeI (..),
    ConnectionRequest (..),
    AConnectionRequest (..),
    ConnReqData (..),
    ConnReqScheme (..),
    ConnectionEncryption (..),
    simplexChat,
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
    InvitationId,
    MsgIntegrity (..),
    MsgErrorType (..),
    QueueStatus (..),
    ACorrId,
    AgentMsgId,

    -- * Parse and serialize
    serializeCommand,
    clientToAgentMsg,
    serializeAgentMessage,
    serializeMsgIntegrity,
    serializeSMPQueueUri,
    serializeConnMode,
    serializeConnMode',
    connMode,
    connMode',
    serializeConnReq,
    serializeConnReq',
    serializeAgentError,
    commandP,
    smpServerP,
    smpQueueUriP,
    connModeT,
    connReqP,
    connReqP',
    msgIntegrityP,
    agentErrorTypeP,
    serializeQueueStatus,
    queueStatusT,

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
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind (Type)
import Data.List (find)
import qualified Data.List.NonEmpty as L
import Data.Maybe (isJust)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Network.HTTP.Types (parseSimpleQuery, renderSimpleQuery)
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( ClientMessage (..),
    ErrorType,
    MsgBody,
    MsgId,
    PrivHeader (..),
    SndPublicVerifyKey,
    serializeClientMessage,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (Transport (..), TransportError, serializeTransportError, transportErrorP)
import Simplex.Messaging.Util
import Test.QuickCheck (Arbitrary (..))
import Text.Read
import UnliftIO.Exception (Exception)

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
  NEW :: AConnectionMode -> ACommand Client -- response INV
  INV :: AConnectionRequest -> ACommand Agent
  JOIN :: AConnectionRequest -> ConnInfo -> ACommand Client -- response OK
  CONF :: ConfirmationId -> ConnInfo -> ACommand Agent -- ConnInfo is from sender
  LET :: ConfirmationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  REQ :: InvitationId -> ConnInfo -> ACommand Agent -- ConnInfo is from sender
  ACPT :: InvitationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  RJCT :: InvitationId -> ACommand Client
  INFO :: ConnInfo -> ACommand Agent
  CON :: ACommand Agent -- notification that connection is established
  SUB :: ACommand Client
  END :: ACommand Agent
  DOWN :: ACommand Agent
  UP :: ACommand Agent
  -- QST :: QueueDirection -> ACommand Client
  -- STAT :: QueueDirection -> Maybe QueueStatus -> Maybe SubMode -> ACommand Agent
  SEND :: MsgBody -> ACommand Client
  MID :: AgentMsgId -> ACommand Agent
  SENT :: AgentMsgId -> ACommand Agent
  MERR :: AgentMsgId -> AgentErrorType -> ACommand Agent
  MSG :: MsgMeta -> MsgBody -> ACommand Agent
  ACK :: AgentMsgId -> ACommand Client
  -- RCVD :: AgentMsgId -> ACommand Agent
  OFF :: ACommand Client
  DEL :: ACommand Client
  OK :: ACommand Agent
  ERR :: AgentErrorType -> ACommand Agent

deriving instance Eq (ACommand p)

deriving instance Show (ACommand p)

data ConnectionMode = CMInvitation | CMContact
  deriving (Eq, Show)

data SConnectionMode (m :: ConnectionMode) where
  SCMInvitation :: SConnectionMode CMInvitation
  SCMContact :: SConnectionMode CMContact

deriving instance Eq (SConnectionMode m)

deriving instance Show (SConnectionMode m)

instance TestEquality SConnectionMode where
  testEquality SCMInvitation SCMInvitation = Just Refl
  testEquality SCMContact SCMContact = Just Refl
  testEquality _ _ = Nothing

data AConnectionMode = forall m. ACM (SConnectionMode m)

instance Eq AConnectionMode where
  ACM m == ACM m' = isJust $ testEquality m m'

cmInvitation :: AConnectionMode
cmInvitation = ACM SCMInvitation

cmContact :: AConnectionMode
cmContact = ACM SCMContact

deriving instance Show AConnectionMode

connMode :: SConnectionMode m -> ConnectionMode
connMode SCMInvitation = CMInvitation
connMode SCMContact = CMContact

connMode' :: ConnectionMode -> AConnectionMode
connMode' CMInvitation = cmInvitation
connMode' CMContact = cmContact

class ConnectionModeI (m :: ConnectionMode) where sConnectionMode :: SConnectionMode m

instance ConnectionModeI CMInvitation where sConnectionMode = SCMInvitation

instance ConnectionModeI CMContact where sConnectionMode = SCMContact

type MsgHash = ByteString

-- | Agent message metadata sent to the client
data MsgMeta = MsgMeta
  { integrity :: MsgIntegrity,
    recipient :: (AgentMsgId, UTCTime),
    broker :: (MsgId, UTCTime),
    sndMsgId :: AgentMsgId
  }
  deriving (Eq, Show)

data SMPConfirmation = SMPConfirmation
  { -- | sender's public key to use for authentication of sender's commands at the recepient's server
    senderKey :: SndPublicVerifyKey,
    -- | sender's DH public key for simple per-queue e2e encryption
    e2ePubKey :: C.PublicKeyX25519,
    -- | sender's information to be associated with the connection, e.g. sender's profile information
    connInfo :: ConnInfo
  }
  deriving (Show)

-- SMP agent message formats
data AgentMessage
  = AgentConfirmation C.APublicVerifyKey ConnInfo -- TODO add double ratchet E2E settings
  | AgentInvitation (ConnectionRequest CMInvitation) ConnInfo
  | AgentMessage AHeader AMessage

data AHeader = AHeader
  { -- | sequential ID assigned by the sending agent
    sndMsgId :: AgentMsgId,
    -- | digest of the previous message
    prevMsgHash :: MsgHash
  }

serializeAHeader :: AHeader -> ByteString
serializeAHeader AHeader {sndMsgId, prevMsgHash} =
  bshow sndMsgId <> " " <> encode prevMsgHash <> "\n"

emptyAHeader :: ByteString
emptyAHeader = "\n"

aHeaderP :: Parser AHeader
aHeaderP = AHeader <$> A.decimal <* A.space <*> (base64P <|> pure "") <* A.endOfLine

emptyAHeaderP :: Parser ()
emptyAHeaderP = A.endOfLine $> ()

-- | Messages sent between SMP agents once SMP queue is secured.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents
data AMessage
  = -- | the first message in the queue to validate it is secured
    HELLO
  | -- | reply queue information
    REPLY (ConnectionRequest CMInvitation)
  | -- | agent envelope for the client message
    A_MSG MsgBody
  deriving (Show)

serializeAgentMessage :: AgentMessage -> ByteString
serializeAgentMessage = serializeClientMessage . agentToClientMsg

agentToClientMsg :: AgentMessage -> ClientMessage
agentToClientMsg = \case
  AgentConfirmation senderKey cInfo ->
    ClientMessage (PHConfirmation senderKey) $ emptyAHeader <> cInfo
  AgentInvitation cReq cInfo ->
    ClientMessage PHEmpty $ emptyAHeader <> serializeConnReq' cReq <> "\n" <> cInfo
  AgentMessage header aMsg ->
    ClientMessage PHEmpty $ serializeAHeader header <> serializeAMessage aMsg

clientToAgentMsg :: ClientMessage -> Either AgentErrorType AgentMessage
clientToAgentMsg (ClientMessage header body) = parse parser (AGENT A_MESSAGE) body
  where
    parser = case header of
      PHConfirmation senderKey -> AgentConfirmation senderKey <$> (emptyAHeaderP *> A.takeByteString)
      PHEmpty -> invitationP <|> messageP
    invitationP = AgentInvitation <$> (emptyAHeaderP *> connReqP' <* A.endOfLine) <*> A.takeByteString
    messageP = AgentMessage <$> aHeaderP <*> aMessageP

aMessageP :: Parser AMessage
aMessageP =
  "HELLO" $> HELLO
    <|> "REPLY " *> reply
    <|> "MSG " *> a_msg
  where
    reply = REPLY <$> connReqP'
    a_msg = A_MSG <$> A.takeByteString

-- | SMP server location parser.
smpServerP :: Parser SMPServer
smpServerP = SMPServer <$> server <*> optional port <*> kHash
  where
    server = B.unpack <$> A.takeWhile1 (A.notInClass ":#,; ")
    port = A.char ':' *> (B.unpack <$> A.takeWhile1 A.isDigit)
    kHash = Just . C.KeyHash <$> (A.char '#' *> base64P)

serializeAMessage :: AMessage -> ByteString
serializeAMessage = \case
  HELLO -> "HELLO"
  REPLY cReq -> "REPLY " <> serializeConnReq' cReq
  A_MSG body -> "MSG " <> body

-- | Serialize SMP queue information that is sent out-of-band.
serializeSMPQueueUri :: SMPQueueUri -> ByteString
serializeSMPQueueUri (SMPQueueUri srv qId dhKey) =
  serializeServerUri srv <> "/" <> U.encode qId <> "#" <> C.serializePubKeyUri' dhKey

-- | SMP queue information parser.
smpQueueUriP :: Parser SMPQueueUri
smpQueueUriP =
  SMPQueueUri <$> smpServerUriP <* A.char '/' <*> base64UriP <* A.char '#' <*> C.strPubKeyUriP

serializeConnReq :: AConnectionRequest -> ByteString
serializeConnReq (ACR _ cr) = serializeConnReq' cr

serializeConnReq' :: ConnectionRequest m -> ByteString
serializeConnReq' = \case
  CRInvitation crData -> serialize CMInvitation crData
  CRContact crData -> serialize CMContact crData
  where
    serialize crMode ConnReqData {crScheme, crSmpQueues, crEncryption = _} =
      sch <> "/" <> m <> "#/" <> queryStr
      where
        sch = case crScheme of
          CRSSimplex -> "simplex:"
          CRSAppServer host port -> B.pack $ "https://" <> host <> maybe "" (':' :) port
        m = case crMode of
          CMInvitation -> "invitation"
          CMContact -> "contact"
        queryStr = renderSimpleQuery True [("smp", queues), ("e2e", "")]
        queues = B.intercalate "," . map serializeSMPQueueUri $ L.toList crSmpQueues

connReqP' :: forall m. ConnectionModeI m => Parser (ConnectionRequest m)
connReqP' = do
  ACR m cr <- connReqP
  case testEquality m $ sConnectionMode @m of
    Just Refl -> pure cr
    _ -> fail "bad connection request mode"

connReqP :: Parser AConnectionRequest
connReqP = do
  crScheme <- "simplex:" $> CRSSimplex <|> "https://" *> appServer
  crMode <- "/" *> mode <* "#/?"
  query <- parseSimpleQuery <$> A.takeTill (\c -> c == ' ' || c == '\n')
  crSmpQueues <- paramP "smp" smpQueues query
  let crEncryption = ConnectionEncryption
      cReq = ConnReqData {crScheme, crSmpQueues, crEncryption}
  pure $ case crMode of
    CMInvitation -> ACR SCMInvitation $ CRInvitation cReq
    CMContact -> ACR SCMContact $ CRContact cReq
  where
    appServer = CRSAppServer <$> host <*> optional port
    host = B.unpack <$> A.takeTill (\c -> c == ':' || c == '/')
    port = B.unpack <$> (A.char ':' *> A.takeTill (== '/'))
    mode = "invitation" $> CMInvitation <|> "contact" $> CMContact
    paramP param parser query =
      let p = maybe (fail "") (pure . snd) $ find ((== param) . fst) query
       in parseAll parser <$?> p
    smpQueues =
      maybe (fail "no SMP queues") pure . L.nonEmpty
        =<< (smpQueue `A.sepBy1'` A.char ',')
    smpQueue = parseAll smpQueueUriP <$?> A.takeTill (== ',')

-- | Serialize SMP server URI.
serializeServerUri :: SMPServer -> ByteString
serializeServerUri SMPServer {host, port, keyHash} = "smp://" <> kh <> B.pack host <> p
  where
    kh = maybe "" ((<> "@") . U.encode . C.unKeyHash) keyHash
    p = B.pack $ maybe "" (':' :) port

smpServerUriP :: Parser SMPServer
smpServerUriP = do
  _ <- "smp://"
  keyHash <- C.KeyHash <$> (U.decode <$?> A.takeTill (== '@') <* A.char '@')
  host <- B.unpack <$> A.takeWhile1 (A.notInClass ":#,;/ ")
  port <- optional $ B.unpack <$> (A.char ':' *> A.takeWhile1 A.isDigit)
  pure SMPServer {host, port, keyHash = Just keyHash}

serializeConnMode :: AConnectionMode -> ByteString
serializeConnMode (ACM cMode) = serializeConnMode' $ connMode cMode

serializeConnMode' :: ConnectionMode -> ByteString
serializeConnMode' = \case
  CMInvitation -> "INV"
  CMContact -> "CON"

connModeP' :: Parser ConnectionMode
connModeP' = "INV" $> CMInvitation <|> "CON" $> CMContact

connModeP :: Parser AConnectionMode
connModeP = connMode' <$> connModeP'

connModeT :: Text -> Maybe ConnectionMode
connModeT = \case
  "INV" -> Just CMInvitation
  "CON" -> Just CMContact
  _ -> Nothing

-- | SMP server location and transport key digest (hash).
data SMPServer = SMPServer
  { host :: HostName,
    port :: Maybe ServiceName,
    keyHash :: Maybe C.KeyHash -- TODO make non optional
  }
  deriving (Eq, Ord, Show)

instance IsString SMPServer where
  fromString = parseString $ parseAll smpServerP

-- | SMP agent connection alias.
type ConnId = ByteString

type ConfirmationId = ByteString

type InvitationId = ByteString

-- | SMP queue information sent out-of-band.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#out-of-band-messages
data SMPQueueUri = SMPQueueUri
  { smpServer :: SMPServer,
    senderId :: SMP.SenderId,
    dhPublicKey :: C.PublicKeyX25519
  }
  deriving (Eq, Show)

data ConnectionRequest (m :: ConnectionMode) where
  CRInvitation :: ConnReqData -> ConnectionRequest CMInvitation
  CRContact :: ConnReqData -> ConnectionRequest CMContact

deriving instance Eq (ConnectionRequest m)

deriving instance Show (ConnectionRequest m)

data AConnectionRequest = forall m. ACR (SConnectionMode m) (ConnectionRequest m)

instance Eq AConnectionRequest where
  ACR m cr == ACR m' cr' = case testEquality m m' of
    Just Refl -> cr == cr'
    _ -> False

deriving instance Show AConnectionRequest

data ConnReqData = ConnReqData
  { crScheme :: ConnReqScheme,
    crSmpQueues :: L.NonEmpty SMPQueueUri,
    crEncryption :: ConnectionEncryption
  }
  deriving (Eq, Show)

data ConnReqScheme = CRSSimplex | CRSAppServer HostName (Maybe ServiceName)
  deriving (Eq, Show)

-- TODO this is a stub for double ratchet E2E encryption parameters (2 public DH keys)
data ConnectionEncryption = ConnectionEncryption
  deriving (Eq, Show)

simplexChat :: ConnReqScheme
simplexChat = CRSAppServer "simplex.chat" Nothing

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

serializeQueueStatus :: QueueStatus -> Text
serializeQueueStatus = \case
  New -> "new"
  Confirmed -> "confirmed"
  Secured -> "secured"
  Active -> "active"
  Disabled -> "disabled"

queueStatusT :: Text -> Maybe QueueStatus
queueStatusT = \case
  "new" -> Just New
  "confirmed" -> Just Confirmed
  "secured" -> Just Secured
  "active" -> Just Active
  "disabled" -> Just Disabled
  _ -> Nothing

type AgentMsgId = Int64

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
  = -- | client or agent message that failed to parse
    A_MESSAGE
  | -- | prohibited SMP/agent message
    A_PROHIBITED
  | -- | cannot decrypt message
    A_ENCRYPTION
  deriving (Eq, Generic, Read, Show, Exception)

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

-- | SMP agent command and response parser
commandP :: Parser ACmd
commandP =
  "NEW " *> newCmd
    <|> "INV " *> invResp
    <|> "JOIN " *> joinCmd
    <|> "CONF " *> confMsg
    <|> "LET " *> letCmd
    <|> "REQ " *> reqMsg
    <|> "ACPT " *> acptCmd
    <|> "RJCT " *> rjctCmd
    <|> "INFO " *> infoCmd
    <|> "SUB" $> ACmd SClient SUB
    <|> "END" $> ACmd SAgent END
    <|> "DOWN" $> ACmd SAgent DOWN
    <|> "UP" $> ACmd SAgent UP
    <|> "SEND " *> sendCmd
    <|> "MID " *> msgIdResp
    <|> "SENT " *> sentResp
    <|> "MERR " *> msgErrResp
    <|> "MSG " *> message
    <|> "ACK " *> ackCmd
    <|> "OFF" $> ACmd SClient OFF
    <|> "DEL" $> ACmd SClient DEL
    <|> "ERR " *> agentError
    <|> "CON" $> ACmd SAgent CON
    <|> "OK" $> ACmd SAgent OK
  where
    newCmd = ACmd SClient . NEW <$> connModeP
    invResp = ACmd SAgent . INV <$> connReqP
    joinCmd = ACmd SClient <$> (JOIN <$> connReqP <* A.space <*> A.takeByteString)
    confMsg = ACmd SAgent <$> (CONF <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    letCmd = ACmd SClient <$> (LET <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    reqMsg = ACmd SAgent <$> (REQ <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    acptCmd = ACmd SClient <$> (ACPT <$> A.takeTill (== ' ') <* A.space <*> A.takeByteString)
    rjctCmd = ACmd SClient . RJCT <$> A.takeByteString
    infoCmd = ACmd SAgent . INFO <$> A.takeByteString
    sendCmd = ACmd SClient . SEND <$> A.takeByteString
    msgIdResp = ACmd SAgent . MID <$> A.decimal
    sentResp = ACmd SAgent . SENT <$> A.decimal
    msgErrResp = ACmd SAgent <$> (MERR <$> A.decimal <* A.space <*> agentErrorTypeP)
    message = ACmd SAgent <$> (MSG <$> msgMetaP <* A.space <*> A.takeByteString)
    ackCmd = ACmd SClient . ACK <$> A.decimal
    msgMetaP = do
      integrity <- msgIntegrityP
      recipient <- " R=" *> partyMeta A.decimal
      broker <- " B=" *> partyMeta base64P
      sndMsgId <- " S=" *> A.decimal
      pure MsgMeta {integrity, recipient, broker, sndMsgId}
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
  NEW cMode -> "NEW " <> serializeConnMode cMode
  INV cReq -> "INV " <> serializeConnReq cReq
  JOIN cReq cInfo -> B.unwords ["JOIN", serializeConnReq cReq, serializeBinary cInfo]
  CONF confId cInfo -> B.unwords ["CONF", confId, serializeBinary cInfo]
  LET confId cInfo -> B.unwords ["LET", confId, serializeBinary cInfo]
  REQ invId cInfo -> B.unwords ["REQ", invId, serializeBinary cInfo]
  ACPT invId cInfo -> B.unwords ["ACPT", invId, serializeBinary cInfo]
  RJCT invId -> "RJCT " <> invId
  INFO cInfo -> "INFO " <> serializeBinary cInfo
  SUB -> "SUB"
  END -> "END"
  DOWN -> "DOWN"
  UP -> "UP"
  SEND msgBody -> "SEND " <> serializeBinary msgBody
  MID mId -> "MID " <> bshow mId
  SENT mId -> "SENT " <> bshow mId
  MERR mId e -> B.unwords ["MERR", bshow mId, serializeAgentError e]
  MSG msgMeta msgBody -> B.unwords ["MSG", serializeMsgMeta msgMeta, serializeBinary msgBody]
  ACK mId -> "ACK " <> bshow mId
  OFF -> "OFF"
  DEL -> "DEL"
  CON -> "CON"
  ERR e -> "ERR " <> serializeAgentError e
  OK -> "OK"
  where
    showTs :: UTCTime -> ByteString
    showTs = B.pack . formatISO8601Millis
    serializeMsgMeta :: MsgMeta -> ByteString
    serializeMsgMeta MsgMeta {integrity, recipient = (rmId, rTs), broker = (bmId, bTs), sndMsgId} =
      B.unwords
        [ serializeMsgIntegrity integrity,
          "R=" <> bshow rmId <> "," <> showTs rTs,
          "B=" <> encode bmId <> "," <> showTs bTs,
          "S=" <> bshow sndMsgId
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
      NEW _ -> Right cmd
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
      JOIN qUri cInfo -> JOIN qUri <$$> getBody cInfo
      CONF confId cInfo -> CONF confId <$$> getBody cInfo
      LET confId cInfo -> LET confId <$$> getBody cInfo
      REQ invId cInfo -> REQ invId <$$> getBody cInfo
      ACPT invId cInfo -> ACPT invId <$$> getBody cInfo
      INFO cInfo -> INFO <$$> getBody cInfo
      cmd -> pure $ Right cmd

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
