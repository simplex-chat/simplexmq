{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
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
  ( -- * Protocol parameters
    supportedSMPAgentVRange,
    e2eEncConnInfoLength,
    e2eEncUserMsgLength,

    -- * SMP agent protocol types
    ConnInfo,
    ACommand (..),
    ACommandTag (..),
    aCommandTag,
    ACmd (..),
    ACmdTag (..),
    AParty (..),
    SAParty (..),
    APartyI (..),
    MsgHash,
    MsgMeta (..),
    ConnectionStats (..),
    SwitchPhase (..),
    QueueDirection (..),
    SMPConfirmation (..),
    AgentMsgEnvelope (..),
    AgentMessage (..),
    AgentMessageType (..),
    APrivHeader (..),
    AMessage (..),
    SndQAddr,
    SMPServer,
    pattern SMPServer,
    pattern ProtoServerWithAuth,
    SMPServerWithAuth,
    SrvLoc (..),
    SMPQueue (..),
    sameQAddress,
    noAuthSrv,
    SMPQueueUri (..),
    SMPQueueInfo (..),
    SMPQueueAddress (..),
    ConnectionMode (..),
    SConnectionMode (..),
    AConnectionMode (..),
    cmInvitation,
    cmContact,
    ConnectionModeI (..),
    ConnectionRequestUri (..),
    AConnectionRequestUri (..),
    ConnReqUriData (..),
    CRClientData,
    ConnReqScheme (..),
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
    NotificationsMode (..),
    NotificationInfo (..),

    -- * Encode/decode
    serializeCommand,
    connMode,
    connMode',
    networkCommandP,
    dbCommandP,
    commandP,
    connModeT,
    serializeQueueStatus,
    queueStatusT,
    agentMessageType,
    extraSMPServerHosts,
    updateSMPServerHosts,
    checkParty,

    -- * TCP transport functions
    tPut,
    tGet,
    tPutRaw,
    tGetRaw,
  )
where

import Control.Applicative (optional, (<|>))
import Control.Monad (unless)
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.IO.Class
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.System (SystemTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Simplex.FileTransfer.Protocol (XFTPErrorType)
import Simplex.Messaging.Agent.QueryString
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (E2ERatchetParams, E2ERatchetParamsUri)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( AProtocolType,
    ErrorType,
    MsgBody,
    MsgFlags,
    MsgId,
    NMsgMeta,
    ProtocolServer (..),
    SMPServer,
    SMPServerWithAuth,
    SndPublicVerifyKey,
    SrvLoc (..),
    legacyEncodeServer,
    legacyServerP,
    legacyStrEncodeServer,
    noAuthSrv,
    sameSrvAddr,
    pattern ProtoServerWithAuth,
    pattern SMPServer,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (Transport (..), TransportError, serializeTransportError, transportErrorP)
import Simplex.Messaging.Transport.Client (TransportHost, TransportHosts_ (..))
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Test.QuickCheck (Arbitrary (..))
import Text.Read
import UnliftIO.Exception (Exception)

currentSMPAgentVersion :: Version
currentSMPAgentVersion = 2

supportedSMPAgentVRange :: VersionRange
supportedSMPAgentVRange = mkVersionRange 1 currentSMPAgentVersion

-- it is shorter to allow all handshake headers,
-- including E2E (double-ratchet) parameters and
-- signing key of the sender for the server
e2eEncConnInfoLength :: Int
e2eEncConnInfoLength = 14848

e2eEncUserMsgLength :: Int
e2eEncUserMsgLength = 15856

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

class APartyI (p :: AParty) where sAParty :: SAParty p

instance APartyI Agent where sAParty = SAgent

instance APartyI Client where sAParty = SClient

data ACmd = forall p. APartyI p => ACmd (SAParty p) (ACommand p)

deriving instance Show ACmd

type ConnInfo = ByteString

-- | Parameterized type for SMP agent protocol commands and responses from all participants.
data ACommand (p :: AParty) where
  NEW :: Bool -> AConnectionMode -> ACommand Client -- response INV
  INV :: AConnectionRequestUri -> ACommand Agent
  JOIN :: Bool -> AConnectionRequestUri -> ConnInfo -> ACommand Client -- response OK
  CONF :: ConfirmationId -> [SMPServer] -> ConnInfo -> ACommand Agent -- ConnInfo is from sender, [SMPServer] will be empty only in v1 handshake
  LET :: ConfirmationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  REQ :: InvitationId -> L.NonEmpty SMPServer -> ConnInfo -> ACommand Agent -- ConnInfo is from sender
  ACPT :: InvitationId -> ConnInfo -> ACommand Client -- ConnInfo is from client
  RJCT :: InvitationId -> ACommand Client
  INFO :: ConnInfo -> ACommand Agent
  CON :: ACommand Agent -- notification that connection is established
  SUB :: ACommand Client
  END :: ACommand Agent
  CONNECT :: AProtocolType -> TransportHost -> ACommand Agent
  DISCONNECT :: AProtocolType -> TransportHost -> ACommand Agent
  DOWN :: SMPServer -> [ConnId] -> ACommand Agent
  UP :: SMPServer -> [ConnId] -> ACommand Agent
  SWITCH :: QueueDirection -> SwitchPhase -> ConnectionStats -> ACommand Agent
  SEND :: MsgFlags -> MsgBody -> ACommand Client
  MID :: AgentMsgId -> ACommand Agent
  SENT :: AgentMsgId -> ACommand Agent
  MERR :: AgentMsgId -> AgentErrorType -> ACommand Agent
  MSG :: MsgMeta -> MsgFlags -> MsgBody -> ACommand Agent
  ACK :: AgentMsgId -> ACommand Client
  SWCH :: ACommand Client
  OFF :: ACommand Client
  DEL :: ACommand Client
  DEL_RCVQ :: SMPServer -> SMP.RecipientId -> Maybe AgentErrorType -> ACommand Agent
  DEL_CONN :: ACommand Agent
  DEL_USER :: Int64 -> ACommand Agent
  CHK :: ACommand Client
  STAT :: ConnectionStats -> ACommand Agent
  OK :: ACommand Agent
  ERR :: AgentErrorType -> ACommand Agent
  SUSPENDED :: ACommand Agent

deriving instance Eq (ACommand p)

deriving instance Show (ACommand p)

data ACmdTag = forall p. APartyI p => ACmdTag (SAParty p) (ACommandTag p)

data ACommandTag (p :: AParty) where
  NEW_ :: ACommandTag Client
  INV_ :: ACommandTag Agent
  JOIN_ :: ACommandTag Client
  CONF_ :: ACommandTag Agent
  LET_ :: ACommandTag Client
  REQ_ :: ACommandTag Agent
  ACPT_ :: ACommandTag Client
  RJCT_ :: ACommandTag Client
  INFO_ :: ACommandTag Agent
  CON_ :: ACommandTag Agent
  SUB_ :: ACommandTag Client
  END_ :: ACommandTag Agent
  CONNECT_ :: ACommandTag Agent
  DISCONNECT_ :: ACommandTag Agent
  DOWN_ :: ACommandTag Agent
  UP_ :: ACommandTag Agent
  SWITCH_ :: ACommandTag Agent
  SEND_ :: ACommandTag Client
  MID_ :: ACommandTag Agent
  SENT_ :: ACommandTag Agent
  MERR_ :: ACommandTag Agent
  MSG_ :: ACommandTag Agent
  ACK_ :: ACommandTag Client
  SWCH_ :: ACommandTag Client
  OFF_ :: ACommandTag Client
  DEL_ :: ACommandTag Client
  DEL_RCVQ_ :: ACommandTag Agent
  DEL_CONN_ :: ACommandTag Agent
  DEL_USER_ :: ACommandTag Agent
  CHK_ :: ACommandTag Client
  STAT_ :: ACommandTag Agent
  OK_ :: ACommandTag Agent
  ERR_ :: ACommandTag Agent
  SUSPENDED_ :: ACommandTag Agent

deriving instance Eq (ACommandTag p)

deriving instance Show (ACommandTag p)

aCommandTag :: ACommand p -> ACommandTag p
aCommandTag = \case
  NEW {} -> NEW_
  INV _ -> INV_
  JOIN {} -> JOIN_
  CONF {} -> CONF_
  LET {} -> LET_
  REQ {} -> REQ_
  ACPT {} -> ACPT_
  RJCT _ -> RJCT_
  INFO _ -> INFO_
  CON -> CON_
  SUB -> SUB_
  END -> END_
  CONNECT {} -> CONNECT_
  DISCONNECT {} -> DISCONNECT_
  DOWN {} -> DOWN_
  UP {} -> UP_
  SWITCH {} -> SWITCH_
  SEND {} -> SEND_
  MID _ -> MID_
  SENT _ -> SENT_
  MERR {} -> MERR_
  MSG {} -> MSG_
  ACK _ -> ACK_
  SWCH -> SWCH_
  OFF -> OFF_
  DEL -> DEL_
  DEL_RCVQ {} -> DEL_RCVQ_
  DEL_CONN -> DEL_CONN_
  DEL_USER _ -> DEL_USER_
  CHK -> CHK_
  STAT _ -> STAT_
  OK -> OK_
  ERR _ -> ERR_
  SUSPENDED -> SUSPENDED_

data QueueDirection = QDRcv | QDSnd
  deriving (Eq, Show)

instance StrEncoding QueueDirection where
  strEncode = \case
    QDRcv -> "rcv"
    QDSnd -> "snd"
  strP =
    A.takeTill (== ' ') >>= \case
      "rcv" -> pure QDRcv
      "snd" -> pure QDSnd
      _ -> fail "bad QueueDirection"

instance ToJSON QueueDirection where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON QueueDirection where
  parseJSON = strParseJSON "QueueDirection"

data SwitchPhase = SPStarted | SPConfirmed | SPCompleted
  deriving (Eq, Show)

instance StrEncoding SwitchPhase where
  strEncode = \case
    SPStarted -> "started"
    SPConfirmed -> "confirmed"
    SPCompleted -> "completed"
  strP =
    A.takeTill (== ' ') >>= \case
      "started" -> pure SPStarted
      "confirmed" -> pure SPConfirmed
      "completed" -> pure SPCompleted
      _ -> fail "bad SwitchPhase"

instance ToJSON SwitchPhase where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON SwitchPhase where
  parseJSON = strParseJSON "SwitchPhase"

data ConnectionStats = ConnectionStats
  { rcvServers :: [SMPServer],
    sndServers :: [SMPServer]
  }
  deriving (Eq, Show, Generic)

instance StrEncoding ConnectionStats where
  strEncode ConnectionStats {rcvServers, sndServers} =
    "rcv=" <> strEncodeList rcvServers <> " snd=" <> strEncodeList sndServers
  strP = do
    rcvServers <- "rcv=" *> strListP
    sndServers <- " snd=" *> strListP
    pure ConnectionStats {rcvServers, sndServers}

instance ToJSON ConnectionStats where toEncoding = J.genericToEncoding J.defaultOptions

data NotificationsMode = NMPeriodic | NMInstant
  deriving (Eq, Show)

instance StrEncoding NotificationsMode where
  strEncode = \case
    NMPeriodic -> "PERIODIC"
    NMInstant -> "INSTANT"
  strP =
    A.takeTill (== ' ') >>= \case
      "PERIODIC" -> pure NMPeriodic
      "INSTANT" -> pure NMInstant
      _ -> fail "bad NotificationsMode"

instance ToJSON NotificationsMode where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance ToField NotificationsMode where toField = toField . strEncode

instance FromField NotificationsMode where fromField = blobFieldDecoder $ parseAll strP

data NotificationInfo = NotificationInfo
  { ntfConnId :: ConnId,
    ntfTs :: SystemTime,
    ntfMsgMeta :: Maybe NMsgMeta
  }
  deriving (Show)

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

data AConnectionMode = forall m. ConnectionModeI m => ACM (SConnectionMode m)

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
    connInfo :: ConnInfo,
    -- | optional reply queues included in confirmation (added in agent protocol v2)
    smpReplyQueues :: [SMPQueueInfo],
    -- | SMP client version
    smpClientVersion :: Version
  }
  deriving (Show)

data AgentMsgEnvelope
  = AgentConfirmation
      { agentVersion :: Version,
        e2eEncryption :: Maybe (E2ERatchetParams 'C.X448),
        encConnInfo :: ByteString
      }
  | AgentMsgEnvelope
      { agentVersion :: Version,
        encAgentMessage :: ByteString
      }
  | AgentInvitation -- the connInfo in contactInvite is only encrypted with per-queue E2E, not with double ratchet,
      { agentVersion :: Version,
        connReq :: ConnectionRequestUri 'CMInvitation,
        connInfo :: ByteString -- this message is only encrypted with per-queue E2E, not with double ratchet,
      }
  deriving (Show)

instance Encoding AgentMsgEnvelope where
  smpEncode = \case
    AgentConfirmation {agentVersion, e2eEncryption, encConnInfo} ->
      smpEncode (agentVersion, 'C', e2eEncryption, Tail encConnInfo)
    AgentMsgEnvelope {agentVersion, encAgentMessage} ->
      smpEncode (agentVersion, 'M', Tail encAgentMessage)
    AgentInvitation {agentVersion, connReq, connInfo} ->
      smpEncode (agentVersion, 'I', Large $ strEncode connReq, Tail connInfo)
  smpP = do
    agentVersion <- smpP
    smpP >>= \case
      'C' -> do
        (e2eEncryption, Tail encConnInfo) <- smpP
        pure AgentConfirmation {agentVersion, e2eEncryption, encConnInfo}
      'M' -> do
        Tail encAgentMessage <- smpP
        pure AgentMsgEnvelope {agentVersion, encAgentMessage}
      'I' -> do
        connReq <- strDecode . unLarge <$?> smpP
        Tail connInfo <- smpP
        pure AgentInvitation {agentVersion, connReq, connInfo}
      _ -> fail "bad AgentMsgEnvelope"

-- SMP agent message formats (after double ratchet decryption,
-- or in case of AgentInvitation - in plain text body)
data AgentMessage
  = AgentConnInfo ConnInfo
  | -- AgentConnInfoReply is only used in duplexHandshake mode (v2), allowing to include reply queue(s) in the initial confirmation.
    -- It makes REPLY message unnecessary.
    AgentConnInfoReply (L.NonEmpty SMPQueueInfo) ConnInfo
  | AgentMessage APrivHeader AMessage
  deriving (Show)

instance Encoding AgentMessage where
  smpEncode = \case
    AgentConnInfo cInfo -> smpEncode ('I', Tail cInfo)
    AgentConnInfoReply smpQueues cInfo -> smpEncode ('D', smpQueues, Tail cInfo) -- 'D' stands for "duplex"
    AgentMessage hdr aMsg -> smpEncode ('M', hdr, aMsg)
  smpP =
    smpP >>= \case
      'I' -> AgentConnInfo . unTail <$> smpP
      'D' -> AgentConnInfoReply <$> smpP <*> (unTail <$> smpP)
      'M' -> AgentMessage <$> smpP <*> smpP
      _ -> fail "bad AgentMessage"

data AgentMessageType
  = AM_CONN_INFO
  | AM_CONN_INFO_REPLY
  | AM_HELLO_
  | AM_REPLY_
  | AM_A_MSG_
  | AM_QCONT_
  | AM_QADD_
  | AM_QKEY_
  | AM_QUSE_
  | AM_QTEST_
  deriving (Eq, Show)

instance Encoding AgentMessageType where
  smpEncode = \case
    AM_CONN_INFO -> "C"
    AM_CONN_INFO_REPLY -> "D"
    AM_HELLO_ -> "H"
    AM_REPLY_ -> "R"
    AM_A_MSG_ -> "M"
    AM_QCONT_ -> "QC"
    AM_QADD_ -> "QA"
    AM_QKEY_ -> "QK"
    AM_QUSE_ -> "QU"
    AM_QTEST_ -> "QT"
  smpP =
    A.anyChar >>= \case
      'C' -> pure AM_CONN_INFO
      'D' -> pure AM_CONN_INFO_REPLY
      'H' -> pure AM_HELLO_
      'R' -> pure AM_REPLY_
      'M' -> pure AM_A_MSG_
      'Q' ->
        A.anyChar >>= \case
          'C' -> pure AM_QCONT_
          'A' -> pure AM_QADD_
          'K' -> pure AM_QKEY_
          'U' -> pure AM_QUSE_
          'T' -> pure AM_QTEST_
          _ -> fail "bad AgentMessageType"
      _ -> fail "bad AgentMessageType"

agentMessageType :: AgentMessage -> AgentMessageType
agentMessageType = \case
  AgentConnInfo _ -> AM_CONN_INFO
  AgentConnInfoReply {} -> AM_CONN_INFO_REPLY
  AgentMessage _ aMsg -> case aMsg of
    -- HELLO is used both in v1 and in v2, but differently.
    -- - in v1 (and, possibly, in v2 for simplex connections) can be sent multiple times,
    --   until the queue is secured - the OK response from the server instead of initial AUTH errors confirms it.
    -- - in v2 duplexHandshake it is sent only once, when it is known that the queue was secured.
    HELLO -> AM_HELLO_
    -- REPLY is only used in v1
    REPLY _ -> AM_REPLY_
    A_MSG _ -> AM_A_MSG_
    QCONT _ -> AM_QCONT_
    QADD _ -> AM_QADD_
    QKEY _ -> AM_QKEY_
    QUSE _ -> AM_QUSE_
    QTEST _ -> AM_QTEST_

data APrivHeader = APrivHeader
  { -- | sequential ID assigned by the sending agent
    sndMsgId :: AgentMsgId,
    -- | digest of the previous message
    prevMsgHash :: MsgHash
  }
  deriving (Show)

instance Encoding APrivHeader where
  smpEncode APrivHeader {sndMsgId, prevMsgHash} =
    smpEncode (sndMsgId, prevMsgHash)
  smpP = APrivHeader <$> smpP <*> smpP

data AMsgType
  = HELLO_
  | REPLY_
  | A_MSG_
  | QCONT_
  | QADD_
  | QKEY_
  | QUSE_
  | QTEST_
  deriving (Eq)

instance Encoding AMsgType where
  smpEncode = \case
    HELLO_ -> "H"
    REPLY_ -> "R"
    A_MSG_ -> "M"
    QCONT_ -> "QC"
    QADD_ -> "QA"
    QKEY_ -> "QK"
    QUSE_ -> "QU"
    QTEST_ -> "QT"
  smpP =
    A.anyChar >>= \case
      'H' -> pure HELLO_
      'R' -> pure REPLY_
      'M' -> pure A_MSG_
      'Q' ->
        A.anyChar >>= \case
          'C' -> pure QCONT_
          'A' -> pure QADD_
          'K' -> pure QKEY_
          'U' -> pure QUSE_
          'T' -> pure QTEST_
          _ -> fail "bad AMsgType"
      _ -> fail "bad AMsgType"

-- | Messages sent between SMP agents once SMP queue is secured.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents
data AMessage
  = -- | the first message in the queue to validate it is secured
    HELLO
  | -- | reply queues information
    REPLY (L.NonEmpty SMPQueueInfo)
  | -- | agent envelope for the client message
    A_MSG MsgBody
  | -- | the message instructing the client to continue sending messages (after ERR QUOTA)
    QCONT SndQAddr
  | -- add queue to connection (sent by recipient), with optional address of the replaced queue
    QADD (L.NonEmpty (SMPQueueUri, Maybe SndQAddr))
  | -- key to secure the added queues and agree e2e encryption key (sent by sender)
    QKEY (L.NonEmpty (SMPQueueInfo, SndPublicVerifyKey))
  | -- inform that the queues are ready to use (sent by recipient)
    QUSE (L.NonEmpty (SndQAddr, Bool))
  | -- sent by the sender to test new queues and to complete switching
    QTEST (L.NonEmpty SndQAddr)
  deriving (Show)

type SndQAddr = (SMPServer, SMP.SenderId)

instance Encoding AMessage where
  smpEncode = \case
    HELLO -> smpEncode HELLO_
    REPLY smpQueues -> smpEncode (REPLY_, smpQueues)
    A_MSG body -> smpEncode (A_MSG_, Tail body)
    QCONT addr -> smpEncode (QCONT_, addr)
    QADD qs -> smpEncode (QADD_, qs)
    QKEY qs -> smpEncode (QKEY_, qs)
    QUSE qs -> smpEncode (QUSE_, qs)
    QTEST qs -> smpEncode (QTEST_, qs)
  smpP =
    smpP
      >>= \case
        HELLO_ -> pure HELLO
        REPLY_ -> REPLY <$> smpP
        A_MSG_ -> A_MSG . unTail <$> smpP
        QCONT_ -> QCONT <$> smpP
        QADD_ -> QADD <$> smpP
        QKEY_ -> QKEY <$> smpP
        QUSE_ -> QUSE <$> smpP
        QTEST_ -> QTEST <$> smpP

instance forall m. ConnectionModeI m => StrEncoding (ConnectionRequestUri m) where
  strEncode = \case
    CRInvitationUri crData e2eParams -> crEncode "invitation" crData (Just e2eParams)
    CRContactUri crData -> crEncode "contact" crData Nothing
    where
      crEncode :: ByteString -> ConnReqUriData -> Maybe (E2ERatchetParamsUri 'C.X448) -> ByteString
      crEncode crMode ConnReqUriData {crScheme, crAgentVRange, crSmpQueues, crClientData} e2eParams =
        strEncode crScheme <> "/" <> crMode <> "#/?" <> queryStr
        where
          queryStr =
            strEncode . QSP QEscape $
              [("v", strEncode crAgentVRange), ("smp", strEncode crSmpQueues)]
                <> maybe [] (\e2e -> [("e2e", strEncode e2e)]) e2eParams
                <> maybe [] (\cd -> [("data", encodeUtf8 cd)]) crClientData
  strP = do
    ACR m cr <- strP
    case testEquality m $ sConnectionMode @m of
      Just Refl -> pure cr
      _ -> fail "bad connection request mode"

instance StrEncoding AConnectionRequestUri where
  strEncode (ACR _ cr) = strEncode cr
  strP = do
    crScheme <- strP
    crMode <- A.char '/' *> crModeP <* optional (A.char '/') <* "#/?"
    query <- strP
    crAgentVRange <- queryParam "v" query
    crSmpQueues <- queryParam "smp" query
    let crClientData = safeDecodeUtf8 <$> queryParamStr "data" query
    let crData = ConnReqUriData {crScheme, crAgentVRange, crSmpQueues, crClientData}
    case crMode of
      CMInvitation -> do
        crE2eParams <- queryParam "e2e" query
        pure . ACR SCMInvitation $ CRInvitationUri crData crE2eParams
      CMContact -> pure . ACR SCMContact $ CRContactUri crData
    where
      crModeP = "invitation" $> CMInvitation <|> "contact" $> CMContact

instance ConnectionModeI m => FromJSON (ConnectionRequestUri m) where
  parseJSON = strParseJSON "ConnectionRequestUri"

instance ConnectionModeI m => ToJSON (ConnectionRequestUri m) where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON AConnectionRequestUri where
  parseJSON = strParseJSON "ConnectionRequestUri"

instance ToJSON AConnectionRequestUri where
  toJSON = strToJSON
  toEncoding = strToJEncoding

-- debug :: Show a => String -> a -> a
-- debug name value = unsafePerformIO (putStrLn $ name <> ": " <> show value) `seq` value
-- {-# INLINE debug #-}

instance StrEncoding ConnectionMode where
  strEncode = \case
    CMInvitation -> "INV"
    CMContact -> "CON"
  strP = "INV" $> CMInvitation <|> "CON" $> CMContact

instance StrEncoding AConnectionMode where
  strEncode (ACM cMode) = strEncode $ connMode cMode
  strP = connMode' <$> strP

connModeT :: Text -> Maybe ConnectionMode
connModeT = \case
  "INV" -> Just CMInvitation
  "CON" -> Just CMContact
  _ -> Nothing

-- | SMP agent connection ID.
type ConnId = ByteString

type ConfirmationId = ByteString

type InvitationId = ByteString

extraSMPServerHosts :: Map TransportHost TransportHost
extraSMPServerHosts =
  M.fromList
    [ ("smp4.simplex.im", "o5vmywmrnaxalvz6wi3zicyftgio6psuvyniis6gco6bp6ekl4cqj4id.onion"),
      ("smp5.simplex.im", "jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion"),
      ("smp6.simplex.im", "bylepyau3ty4czmn77q4fglvperknl4bi2eb2fdy2bh4jxtf32kf73yd.onion"),
      ("smp8.simplex.im", "beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion"),
      ("smp9.simplex.im", "jssqzccmrcws6bhmn77vgmhfjmhwlyr3u7puw4erkyoosywgl67slqqd.onion"),
      ("smp10.simplex.im", "rb2pbttocvnbrngnwziclp2f4ckjq65kebafws6g4hy22cdaiv5dwjqd.onion")
    ]

updateSMPServerHosts :: SMPServer -> SMPServer
updateSMPServerHosts srv@ProtocolServer {host} = case host of
  h :| [] -> case M.lookup h extraSMPServerHosts of
    Just h' -> srv {host = [h, h']}
    _ -> srv
  _ -> srv

class SMPQueue q where
  qServer :: q -> SMPServer
  qAddress :: q -> (SMPServer, SMP.QueueId)
  sameQueue :: (SMPServer, SMP.QueueId) -> q -> Bool

data SMPQueueInfo = SMPQueueInfo {clientVersion :: Version, queueAddress :: SMPQueueAddress}
  deriving (Eq, Show)

instance Encoding SMPQueueInfo where
  smpEncode (SMPQueueInfo clientVersion SMPQueueAddress {smpServer, senderId, dhPublicKey})
    | clientVersion > 1 = smpEncode (clientVersion, smpServer, senderId, dhPublicKey)
    | otherwise = smpEncode clientVersion <> legacyEncodeServer smpServer <> smpEncode (senderId, dhPublicKey)
  smpP = do
    clientVersion <- smpP
    smpServer <- if clientVersion > 1 then smpP else updateSMPServerHosts <$> legacyServerP
    (senderId, dhPublicKey) <- smpP
    pure $ SMPQueueInfo clientVersion SMPQueueAddress {smpServer, senderId, dhPublicKey}

-- This instance seems contrived and there was a temptation to split a common part of both types.
-- But this is created to allow backward and forward compatibility where SMPQueueUri
-- could have more fields to convert to different versions of SMPQueueInfo in a different way,
-- and this instance would become non-trivial.
instance VersionI SMPQueueInfo where
  type VersionRangeT SMPQueueInfo = SMPQueueUri
  version = clientVersion
  toVersionRangeT (SMPQueueInfo _v addr) vr = SMPQueueUri vr addr

instance VersionRangeI SMPQueueUri where
  type VersionT SMPQueueUri = SMPQueueInfo
  versionRange = clientVRange
  toVersionT (SMPQueueUri _vr addr) v = SMPQueueInfo v addr

-- | SMP queue information sent out-of-band.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#out-of-band-messages
data SMPQueueUri = SMPQueueUri {clientVRange :: VersionRange, queueAddress :: SMPQueueAddress}
  deriving (Eq, Show)

data SMPQueueAddress = SMPQueueAddress
  { smpServer :: SMPServer,
    senderId :: SMP.SenderId,
    dhPublicKey :: C.PublicKeyX25519
  }
  deriving (Eq, Show)

instance SMPQueue SMPQueueUri where
  qServer SMPQueueUri {queueAddress} = qServer queueAddress
  {-# INLINE qServer #-}
  qAddress SMPQueueUri {queueAddress} = qAddress queueAddress
  {-# INLINE qAddress #-}
  sameQueue addr q = sameQAddress addr (qAddress q)
  {-# INLINE sameQueue #-}

instance SMPQueue SMPQueueInfo where
  qServer SMPQueueInfo {queueAddress} = qServer queueAddress
  {-# INLINE qServer #-}
  qAddress SMPQueueInfo {queueAddress} = qAddress queueAddress
  {-# INLINE qAddress #-}
  sameQueue addr q = sameQAddress addr (qAddress q)
  {-# INLINE sameQueue #-}

instance SMPQueue SMPQueueAddress where
  qServer SMPQueueAddress {smpServer} = smpServer
  {-# INLINE qServer #-}
  qAddress SMPQueueAddress {smpServer, senderId} = (smpServer, senderId)
  {-# INLINE qAddress #-}
  sameQueue addr q = sameQAddress addr (qAddress q)
  {-# INLINE sameQueue #-}

sameQAddress :: (SMPServer, SMP.QueueId) -> (SMPServer, SMP.QueueId) -> Bool
sameQAddress (srv, qId) (srv', qId') = sameSrvAddr srv srv' && qId == qId'
{-# INLINE sameQAddress #-}

instance StrEncoding SMPQueueUri where
  strEncode (SMPQueueUri vr SMPQueueAddress {smpServer = srv, senderId = qId, dhPublicKey})
    | minVersion vr > 1 = strEncode srv <> "/" <> strEncode qId <> "#/?" <> query queryParams
    | otherwise = legacyStrEncodeServer srv <> "/" <> strEncode qId <> "#/?" <> query (queryParams <> srvParam)
    where
      query = strEncode . QSP QEscape
      queryParams = [("v", strEncode vr), ("dh", strEncode dhPublicKey)]
      srvParam = [("srv", strEncode $ TransportHosts_ hs) | not (null hs)]
      hs = L.tail $ host srv
  strP = do
    srv@ProtocolServer {host = h :| host} <- strP <* A.char '/'
    senderId <- strP <* optional (A.char '/') <* A.char '#'
    (vr, hs, dhPublicKey) <- unversioned <|> versioned
    let srv' = srv {host = h :| host <> hs}
        smpServer = if maxVersion vr == 1 then updateSMPServerHosts srv' else srv'
    pure $ SMPQueueUri vr SMPQueueAddress {smpServer, senderId, dhPublicKey}
    where
      unversioned = (versionToRange 1,[],) <$> strP <* A.endOfInput
      versioned = do
        dhKey_ <- optional strP
        query <- optional (A.char '/') *> A.char '?' *> strP
        vr <- queryParam "v" query
        dhKey <- maybe (queryParam "dh" query) pure dhKey_
        hs_ <- queryParam_ "srv" query
        pure (vr, maybe [] thList_ hs_, dhKey)

instance Encoding SMPQueueUri where
  smpEncode (SMPQueueUri clientVRange SMPQueueAddress {smpServer, senderId, dhPublicKey}) =
    smpEncode (clientVRange, smpServer, senderId, dhPublicKey)
  smpP = do
    (clientVRange, smpServer, senderId, dhPublicKey) <- smpP
    pure $ SMPQueueUri clientVRange SMPQueueAddress {smpServer, senderId, dhPublicKey}

data ConnectionRequestUri (m :: ConnectionMode) where
  CRInvitationUri :: ConnReqUriData -> E2ERatchetParamsUri 'C.X448 -> ConnectionRequestUri CMInvitation
  -- contact connection request does NOT contain E2E encryption parameters -
  -- they are passed in AgentInvitation message
  CRContactUri :: ConnReqUriData -> ConnectionRequestUri CMContact

deriving instance Eq (ConnectionRequestUri m)

deriving instance Show (ConnectionRequestUri m)

data AConnectionRequestUri = forall m. ConnectionModeI m => ACR (SConnectionMode m) (ConnectionRequestUri m)

instance Eq AConnectionRequestUri where
  ACR m cr == ACR m' cr' = case testEquality m m' of
    Just Refl -> cr == cr'
    _ -> False

deriving instance Show AConnectionRequestUri

data ConnReqUriData = ConnReqUriData
  { crScheme :: ConnReqScheme,
    crAgentVRange :: VersionRange,
    crSmpQueues :: L.NonEmpty SMPQueueUri,
    crClientData :: Maybe CRClientData
  }
  deriving (Eq, Show)

type CRClientData = Text

data ConnReqScheme = CRSSimplex | CRSAppServer SrvLoc
  deriving (Eq, Show)

instance StrEncoding ConnReqScheme where
  strEncode = \case
    CRSSimplex -> "simplex:"
    CRSAppServer srv -> "https://" <> strEncode srv
  strP =
    "simplex:" $> CRSSimplex
      <|> "https://" *> (CRSAppServer <$> strP)

simplexChat :: ConnReqScheme
simplexChat = CRSAppServer $ SrvLoc "simplex.chat" ""

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
data MsgIntegrity = MsgOk | MsgError {errorInfo :: MsgErrorType}
  deriving (Eq, Show, Generic)

instance StrEncoding MsgIntegrity where
  strP = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> strP)
  strEncode = \case
    MsgOk -> "OK"
    MsgError e -> "ERR" <> strEncode e

instance ToJSON MsgIntegrity where
  toJSON = J.genericToJSON $ sumTypeJSON fstToLower
  toEncoding = J.genericToEncoding $ sumTypeJSON fstToLower

instance FromJSON MsgIntegrity where
  parseJSON = J.genericParseJSON $ sumTypeJSON fstToLower

-- | Error of message integrity validation.
data MsgErrorType
  = MsgSkipped {fromMsgId :: AgentMsgId, toMsgId :: AgentMsgId}
  | MsgBadId {msgId :: AgentMsgId}
  | MsgBadHash
  | MsgDuplicate
  deriving (Eq, Show, Generic)

instance StrEncoding MsgErrorType where
  strP =
    "ID " *> (MsgBadId <$> A.decimal)
      <|> "IDS " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
      <|> "HASH" $> MsgBadHash
      <|> "DUPLICATE" $> MsgDuplicate
  strEncode = \case
    MsgSkipped fromMsgId toMsgId ->
      B.unwords ["NO_ID", bshow fromMsgId, bshow toMsgId]
    MsgBadId aMsgId -> "ID " <> bshow aMsgId
    MsgBadHash -> "HASH"
    MsgDuplicate -> "DUPLICATE"

instance ToJSON MsgErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON fstToLower
  toEncoding = J.genericToEncoding $ sumTypeJSON fstToLower

instance FromJSON MsgErrorType where
  parseJSON = J.genericParseJSON $ sumTypeJSON fstToLower

-- | Error type used in errors sent to agent clients.
data AgentErrorType
  = -- | command or response error
    CMD {cmdErr :: CommandErrorType}
  | -- | connection errors
    CONN {connErr :: ConnectionErrorType}
  | -- | SMP protocol errors forwarded to agent clients
    SMP {smpErr :: ErrorType}
  | -- | NTF protocol errors forwarded to agent clients
    NTF {ntfErr :: ErrorType}
  | -- | XFTP protocol errors forwarded to agent clients
    XFTP {xftpErr :: XFTPErrorType}
  | -- | SMP server errors
    BROKER {brokerAddress :: String, brokerErr :: BrokerErrorType}
  | -- | errors of other agents
    AGENT {agentErr :: SMPAgentError}
  | -- | agent implementation or dependency errors
    INTERNAL {internalErr :: String}
  deriving (Eq, Generic, Show, Exception)

instance ToJSON AgentErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

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

instance ToJSON CommandErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | Connection error.
data ConnectionErrorType
  = -- | connection is not in the database
    NOT_FOUND
  | -- | connection already exists
    DUPLICATE
  | -- | connection is simplex, but operation requires another queue
    SIMPLEX
  | -- | connection not accepted on join HELLO after timeout
    NOT_ACCEPTED
  | -- | connection not available on reply confirmation/HELLO after timeout
    NOT_AVAILABLE
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON ConnectionErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | SMP server errors.
data BrokerErrorType
  = -- | invalid server response (failed to parse)
    RESPONSE {smpErr :: String}
  | -- | unexpected response
    UNEXPECTED
  | -- | network error
    NETWORK
  | -- | no compatible server host (e.g. onion when public is required, or vice versa)
    HOST
  | -- | handshake or other transport error
    TRANSPORT {transportErr :: TransportError}
  | -- | command response timeout
    TIMEOUT
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON BrokerErrorType where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

-- | Errors of another SMP agent.
data SMPAgentError
  = -- | client or agent message that failed to parse
    A_MESSAGE
  | -- | prohibited SMP/agent message
    A_PROHIBITED
  | -- | incompatible version of SMP client, agent or encryption protocols
    A_VERSION
  | -- | cannot decrypt message
    A_ENCRYPTION
  | -- | duplicate message - this error is detected by ratchet decryption - this message will be ignored and not shown
    A_DUPLICATE
  | -- | error in the message to add/delete/etc queue in connection
    A_QUEUE {queueErr :: String}
  deriving (Eq, Generic, Read, Show, Exception)

instance ToJSON SMPAgentError where
  toJSON = J.genericToJSON $ sumTypeJSON id
  toEncoding = J.genericToEncoding $ sumTypeJSON id

instance StrEncoding AgentErrorType where
  strP =
    "CMD " *> (CMD <$> parseRead1)
      <|> "CONN " *> (CONN <$> parseRead1)
      <|> "SMP " *> (SMP <$> strP)
      <|> "NTF " *> (NTF <$> strP)
      <|> "XFTP " *> (XFTP <$> strP)
      <|> "BROKER " *> (BROKER <$> textP <* " RESPONSE " <*> (RESPONSE <$> textP))
      <|> "BROKER " *> (BROKER <$> textP <* " TRANSPORT " <*> (TRANSPORT <$> transportErrorP))
      <|> "BROKER " *> (BROKER <$> textP <* A.space <*> parseRead1)
      <|> "AGENT QUEUE " *> (AGENT . A_QUEUE <$> parseRead A.takeByteString)
      <|> "AGENT " *> (AGENT <$> parseRead1)
      <|> "INTERNAL " *> (INTERNAL <$> parseRead A.takeByteString)
    where
      textP = T.unpack . safeDecodeUtf8 <$> A.takeTill (== ' ')
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    CONN e -> "CONN " <> bshow e
    SMP e -> "SMP " <> strEncode e
    NTF e -> "NTF " <> strEncode e
    XFTP e -> "XFTP " <> strEncode e
    BROKER srv (RESPONSE e) -> "BROKER " <> text srv <> " RESPONSE " <> text e
    BROKER srv (TRANSPORT e) -> "BROKER " <> text srv <> " TRANSPORT " <> serializeTransportError e
    BROKER srv e -> "BROKER " <> text srv <> " " <> bshow e
    AGENT (A_QUEUE e) -> "AGENT QUEUE " <> bshow e
    AGENT e -> "AGENT " <> bshow e
    INTERNAL e -> "INTERNAL " <> bshow e
    where
      text = encodeUtf8 . T.pack

instance Arbitrary AgentErrorType where arbitrary = genericArbitraryU

instance Arbitrary CommandErrorType where arbitrary = genericArbitraryU

instance Arbitrary ConnectionErrorType where arbitrary = genericArbitraryU

instance Arbitrary BrokerErrorType where arbitrary = genericArbitraryU

instance Arbitrary SMPAgentError where arbitrary = genericArbitraryU

-- | SMP agent command and response parser for commands passed via network (only parses binary length)
networkCommandP :: Parser ACmd
networkCommandP = commandP A.takeByteString

-- | SMP agent command and response parser for commands stored in db (fully parses binary bodies)
dbCommandP :: Parser ACmd
dbCommandP = commandP $ A.take =<< (A.decimal <* "\n")

instance StrEncoding ACmdTag where
  strEncode (ACmdTag _ cmd) = strEncode cmd
  strP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> pure $ ACmdTag SClient NEW_
      "INV" -> pure $ ACmdTag SAgent INV_
      "JOIN" -> pure $ ACmdTag SClient JOIN_
      "CONF" -> pure $ ACmdTag SAgent CONF_
      "LET" -> pure $ ACmdTag SClient LET_
      "REQ" -> pure $ ACmdTag SAgent REQ_
      "ACPT" -> pure $ ACmdTag SClient ACPT_
      "RJCT" -> pure $ ACmdTag SClient RJCT_
      "INFO" -> pure $ ACmdTag SAgent INFO_
      "CON" -> pure $ ACmdTag SAgent CON_
      "SUB" -> pure $ ACmdTag SClient SUB_
      "END" -> pure $ ACmdTag SAgent END_
      "CONNECT" -> pure $ ACmdTag SAgent CONNECT_
      "DISCONNECT" -> pure $ ACmdTag SAgent DISCONNECT_
      "DOWN" -> pure $ ACmdTag SAgent DOWN_
      "UP" -> pure $ ACmdTag SAgent UP_
      "SWITCH" -> pure $ ACmdTag SAgent SWITCH_
      "SEND" -> pure $ ACmdTag SClient SEND_
      "MID" -> pure $ ACmdTag SAgent MID_
      "SENT" -> pure $ ACmdTag SAgent SENT_
      "MERR" -> pure $ ACmdTag SAgent MERR_
      "MSG" -> pure $ ACmdTag SAgent MSG_
      "ACK" -> pure $ ACmdTag SClient ACK_
      "SWCH" -> pure $ ACmdTag SClient SWCH_
      "OFF" -> pure $ ACmdTag SClient OFF_
      "DEL" -> pure $ ACmdTag SClient DEL_
      "DEL_RCVQ" -> pure $ ACmdTag SAgent DEL_RCVQ_
      "DEL_CONN" -> pure $ ACmdTag SAgent DEL_CONN_
      "DEL_USER" -> pure $ ACmdTag SAgent DEL_USER_
      "CHK" -> pure $ ACmdTag SClient CHK_
      "STAT" -> pure $ ACmdTag SAgent STAT_
      "OK" -> pure $ ACmdTag SAgent OK_
      "ERR" -> pure $ ACmdTag SAgent ERR_
      "SUSPENDED" -> pure $ ACmdTag SAgent SUSPENDED_
      _ -> fail "bad ACmdTag"

instance APartyI p => StrEncoding (ACommandTag p) where
  strEncode = \case
    NEW_ -> "NEW"
    INV_ -> "INV"
    JOIN_ -> "JOIN"
    CONF_ -> "CONF"
    LET_ -> "LET"
    REQ_ -> "REQ"
    ACPT_ -> "ACPT"
    RJCT_ -> "RJCT"
    INFO_ -> "INFO"
    CON_ -> "CON"
    SUB_ -> "SUB"
    END_ -> "END"
    CONNECT_ -> "CONNECT"
    DISCONNECT_ -> "DISCONNECT"
    DOWN_ -> "DOWN"
    UP_ -> "UP"
    SWITCH_ -> "SWITCH"
    SEND_ -> "SEND"
    MID_ -> "MID"
    SENT_ -> "SENT"
    MERR_ -> "MERR"
    MSG_ -> "MSG"
    ACK_ -> "ACK"
    SWCH_ -> "SWCH"
    OFF_ -> "OFF"
    DEL_ -> "DEL"
    DEL_RCVQ_ -> "DEL_RCVQ"
    DEL_CONN_ -> "DEL_CONN"
    DEL_USER_ -> "DEL_USER"
    CHK_ -> "CHK"
    STAT_ -> "STAT"
    OK_ -> "OK"
    ERR_ -> "ERR"
    SUSPENDED_ -> "SUSPENDED"
  strP = (\(ACmdTag _ t) -> checkParty t) <$?> strP

checkParty :: forall t p p'. (APartyI p, APartyI p') => t p' -> Either String (t p)
checkParty x = case testEquality (sAParty @p) (sAParty @p') of
  Just Refl -> Right x
  Nothing -> Left "bad party"

-- | SMP agent command and response parser
commandP :: Parser ByteString -> Parser ACmd
commandP binaryP =
  strP
    >>= \case
      ACmdTag SClient cmd ->
        ACmd SClient <$> case cmd of
          NEW_ -> s (NEW <$> strP_ <*> strP)
          JOIN_ -> s (JOIN <$> strP_ <*> strP_ <*> binaryP)
          LET_ -> s (LET <$> A.takeTill (== ' ') <* A.space <*> binaryP)
          ACPT_ -> s (ACPT <$> A.takeTill (== ' ') <* A.space <*> binaryP)
          RJCT_ -> s (RJCT <$> A.takeByteString)
          SUB_ -> pure SUB
          SEND_ -> s (SEND <$> smpP <* A.space <*> binaryP)
          ACK_ -> s (ACK <$> A.decimal)
          SWCH_ -> pure SWCH
          OFF_ -> pure OFF
          DEL_ -> pure DEL
          CHK_ -> pure CHK
      ACmdTag SAgent cmd ->
        ACmd SAgent <$> case cmd of
          INV_ -> s (INV <$> strP)
          CONF_ -> s (CONF <$> A.takeTill (== ' ') <* A.space <*> strListP <* A.space <*> binaryP)
          REQ_ -> s (REQ <$> A.takeTill (== ' ') <* A.space <*> strP_ <*> binaryP)
          INFO_ -> s (INFO <$> binaryP)
          CON_ -> pure CON
          END_ -> pure END
          CONNECT_ -> s (CONNECT <$> strP_ <*> strP)
          DISCONNECT_ -> s (DISCONNECT <$> strP_ <*> strP)
          DOWN_ -> s (DOWN <$> strP_ <*> connections)
          UP_ -> s (UP <$> strP_ <*> connections)
          SWITCH_ -> s (SWITCH <$> strP_ <*> strP_ <*> strP)
          MID_ -> s (MID <$> A.decimal)
          SENT_ -> s (SENT <$> A.decimal)
          MERR_ -> s (MERR <$> A.decimal <* A.space <*> strP)
          MSG_ -> s (MSG <$> msgMetaP <* A.space <*> smpP <* A.space <*> binaryP)
          DEL_RCVQ_ -> s (DEL_RCVQ <$> strP_ <*> strP_ <*> strP)
          DEL_CONN_ -> pure DEL_CONN
          DEL_USER_ -> s (DEL_USER <$> strP)
          STAT_ -> s (STAT <$> strP)
          OK_ -> pure OK
          ERR_ -> s (ERR <$> strP)
          SUSPENDED_ -> pure SUSPENDED
  where
    s :: Parser a -> Parser a
    s p = A.space *> p
    connections :: Parser [ConnId]
    connections = strP `A.sepBy'` A.char ','
    msgMetaP = do
      integrity <- strP
      recipient <- " R=" *> partyMeta A.decimal
      broker <- " B=" *> partyMeta base64P
      sndMsgId <- " S=" *> A.decimal
      pure MsgMeta {integrity, recipient, broker, sndMsgId}
    partyMeta idParser = (,) <$> idParser <* A.char ',' <*> tsISO8601P

parseCommand :: ByteString -> Either AgentErrorType ACmd
parseCommand = parse (commandP A.takeByteString) $ CMD SYNTAX

-- | Serialize SMP agent command.
serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW ntfs cMode -> s (NEW_, ntfs, cMode)
  INV cReq -> s (INV_, cReq)
  JOIN ntfs cReq cInfo -> s (JOIN_, ntfs, cReq, Str $ serializeBinary cInfo)
  CONF confId srvs cInfo -> B.unwords [s CONF_, confId, strEncodeList srvs, serializeBinary cInfo]
  LET confId cInfo -> B.unwords [s LET_, confId, serializeBinary cInfo]
  REQ invId srvs cInfo -> B.unwords [s REQ_, invId, s srvs, serializeBinary cInfo]
  ACPT invId cInfo -> B.unwords [s ACPT_, invId, serializeBinary cInfo]
  RJCT invId -> B.unwords [s RJCT_, invId]
  INFO cInfo -> B.unwords [s INFO_, serializeBinary cInfo]
  SUB -> s SUB_
  END -> s END_
  CONNECT p h -> s (CONNECT_, p, h)
  DISCONNECT p h -> s (DISCONNECT_, p, h)
  DOWN srv conns -> B.unwords [s DOWN_, s srv, connections conns]
  UP srv conns -> B.unwords [s UP_, s srv, connections conns]
  SWITCH dir phase srvs -> s (SWITCH_, dir, phase, srvs)
  SEND msgFlags msgBody -> B.unwords [s SEND_, smpEncode msgFlags, serializeBinary msgBody]
  MID mId -> s (MID_, Str $ bshow mId)
  SENT mId -> s (SENT_, Str $ bshow mId)
  MERR mId e -> s (MERR_, Str $ bshow mId, e)
  MSG msgMeta msgFlags msgBody -> B.unwords [s MSG_, serializeMsgMeta msgMeta, smpEncode msgFlags, serializeBinary msgBody]
  ACK mId -> s (ACK_, Str $ bshow mId)
  SWCH -> s SWCH_
  OFF -> s OFF_
  DEL -> s DEL_
  DEL_RCVQ srv rcvId err_ -> s (DEL_RCVQ_, srv, rcvId, err_)
  DEL_CONN -> s DEL_CONN_
  DEL_USER userId -> s (DEL_USER_, userId)
  CHK -> s CHK_
  STAT srvs -> s (STAT_, srvs)
  CON -> s CON_
  ERR e -> s (ERR_, e)
  OK -> s OK_
  SUSPENDED -> s SUSPENDED_
  where
    s :: StrEncoding a => a -> ByteString
    s = strEncode
    showTs :: UTCTime -> ByteString
    showTs = B.pack . formatISO8601Millis
    connections :: [ConnId] -> ByteString
    connections = B.intercalate "," . map strEncode
    serializeMsgMeta :: MsgMeta -> ByteString
    serializeMsgMeta MsgMeta {integrity, recipient = (rmId, rTs), broker = (bmId, bTs), sndMsgId} =
      B.unwords
        [ strEncode integrity,
          "R=" <> bshow rmId <> "," <> showTs rTs,
          "B=" <> encode bmId <> "," <> showTs bTs,
          "S=" <> bshow sndMsgId
        ]

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
tPut h (corrId, connId, command) =
  liftIO $ tPutRaw h (corrId, connId, serializeCommand command)

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
      NEW {} -> Right cmd
      JOIN {} -> Right cmd
      ACPT {} -> Right cmd
      -- ERROR response does not always have connId
      ERR _ -> Right cmd
      CONNECT {} -> Right cmd
      DISCONNECT {} -> Right cmd
      DOWN {} -> Right cmd
      UP {} -> Right cmd
      -- other responses must have connId
      _
        | B.null connId -> Left $ CMD NO_CONN
        | otherwise -> Right cmd

    cmdWithMsgBody :: ACommand p -> m (Either AgentErrorType (ACommand p))
    cmdWithMsgBody = \case
      SEND msgFlags body -> SEND msgFlags <$$> getBody body
      MSG msgMeta msgFlags body -> MSG msgMeta msgFlags <$$> getBody body
      JOIN ntfs qUri cInfo -> JOIN ntfs qUri <$$> getBody cInfo
      CONF confId srvs cInfo -> CONF confId srvs <$$> getBody cInfo
      LET confId cInfo -> LET confId <$$> getBody cInfo
      REQ invId srvs cInfo -> REQ invId srvs <$$> getBody cInfo
      ACPT invId cInfo -> ACPT invId <$$> getBody cInfo
      INFO cInfo -> INFO <$$> getBody cInfo
      cmd -> pure $ Right cmd

    getBody :: ByteString -> m (Either AgentErrorType ByteString)
    getBody binary =
      case B.unpack binary of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> runExceptT $ do
            body <- liftIO $ cGet h size
            unless (B.length body == size) $ throwError $ CMD SIZE
            s <- liftIO $ getLn h
            unless (B.null s) $ throwError $ CMD SIZE
            pure body
          Nothing -> return . Left $ CMD SYNTAX
