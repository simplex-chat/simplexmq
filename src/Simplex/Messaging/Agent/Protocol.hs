{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
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
{-# LANGUAGE TemplateHaskell #-}
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
    APartyCmd (..),
    ACommandTag (..),
    aCommandTag,
    aPartyCmdTag,
    ACmd (..),
    APartyCmdTag (..),
    ACmdTag (..),
    AParty (..),
    AEntity (..),
    SAParty (..),
    SAEntity (..),
    APartyI (..),
    AEntityI (..),
    MsgHash,
    MsgMeta (..),
    RcvQueueInfo (..),
    SndQueueInfo (..),
    ConnectionStats (..),
    SwitchPhase (..),
    RcvSwitchStatus (..),
    SndSwitchStatus (..),
    QueueDirection (..),
    RatchetSyncState (..),
    SMPConfirmation (..),
    AgentMsgEnvelope (..),
    AgentMessage (..),
    AgentMessageType (..),
    APrivHeader (..),
    AMessage (..),
    AMessageReceipt (..),
    MsgReceipt (..),
    MsgReceiptInfo,
    MsgReceiptStatus (..),
    SndQAddr,
    SMPServer,
    pattern SMPServer,
    pattern ProtoServerWithAuth,
    SMPServerWithAuth,
    SrvLoc (..),
    SMPQueue (..),
    qAddress,
    sameQueue,
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
    AgentCryptoError (..),
    cryptoErrToSyncState,
    ATransmission,
    ATransmissionOrError,
    ARawTransmission,
    ConnId,
    RcvFileId,
    SndFileId,
    ConfirmationId,
    InvitationId,
    MsgIntegrity (..),
    MsgErrorType (..),
    QueueStatus (..),
    UserId,
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
import qualified Data.Aeson.TH as J
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
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.System (SystemTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import Data.Word (Word32)
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), XFTPErrorType)
import Simplex.Messaging.Agent.QueryString
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (E2ERatchetParams, E2ERatchetParamsUri)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( AProtocolType,
    EntityId,
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
    SubscriptionMode,
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
import Simplex.RemoteControl.Types
import Text.Read
import UnliftIO.Exception (Exception)

currentSMPAgentVersion :: Version
currentSMPAgentVersion = 4

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
type ATransmission p = (ACorrId, EntityId, APartyCmd p)

-- | SMP agent protocol transmission or transmission error.
type ATransmissionOrError p = (ACorrId, EntityId, Either AgentErrorType (APartyCmd p))

type UserId = Int64

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

data AEntity = AEConn | AERcvFile | AESndFile | AENone
  deriving (Eq, Show)

data SAEntity :: AEntity -> Type where
  SAEConn :: SAEntity AEConn
  SAERcvFile :: SAEntity AERcvFile
  SAESndFile :: SAEntity AESndFile
  SAENone :: SAEntity AENone

deriving instance Show (SAEntity e)

deriving instance Eq (SAEntity e)

instance TestEquality SAEntity where
  testEquality SAEConn SAEConn = Just Refl
  testEquality SAERcvFile SAERcvFile = Just Refl
  testEquality SAESndFile SAESndFile = Just Refl
  testEquality SAENone SAENone = Just Refl
  testEquality _ _ = Nothing

class AEntityI (e :: AEntity) where sAEntity :: SAEntity e

instance AEntityI AEConn where sAEntity = SAEConn

instance AEntityI AERcvFile where sAEntity = SAERcvFile

instance AEntityI AESndFile where sAEntity = SAESndFile

instance AEntityI AENone where sAEntity = SAENone

data ACmd = forall p e. (APartyI p, AEntityI e) => ACmd (SAParty p) (SAEntity e) (ACommand p e)

deriving instance Show ACmd

data APartyCmd p = forall e. AEntityI e => APC (SAEntity e) (ACommand p e)

instance Eq (APartyCmd p) where
  APC e cmd == APC e' cmd' = case testEquality e e' of
    Just Refl -> cmd == cmd'
    Nothing -> False

deriving instance Show (APartyCmd p)

type ConnInfo = ByteString

-- | Parameterized type for SMP agent protocol commands and responses from all participants.
data ACommand (p :: AParty) (e :: AEntity) where
  NEW :: Bool -> AConnectionMode -> SubscriptionMode -> ACommand Client AEConn -- response INV
  INV :: AConnectionRequestUri -> ACommand Agent AEConn
  JOIN :: Bool -> AConnectionRequestUri -> SubscriptionMode -> ConnInfo -> ACommand Client AEConn -- response OK
  CONF :: ConfirmationId -> [SMPServer] -> ConnInfo -> ACommand Agent AEConn -- ConnInfo is from sender, [SMPServer] will be empty only in v1 handshake
  LET :: ConfirmationId -> ConnInfo -> ACommand Client AEConn -- ConnInfo is from client
  REQ :: InvitationId -> NonEmpty SMPServer -> ConnInfo -> ACommand Agent AEConn -- ConnInfo is from sender
  ACPT :: InvitationId -> ConnInfo -> ACommand Client AEConn -- ConnInfo is from client
  RJCT :: InvitationId -> ACommand Client AEConn
  INFO :: ConnInfo -> ACommand Agent AEConn
  CON :: ACommand Agent AEConn -- notification that connection is established
  SUB :: ACommand Client AEConn
  END :: ACommand Agent AEConn
  CONNECT :: AProtocolType -> TransportHost -> ACommand Agent AENone
  DISCONNECT :: AProtocolType -> TransportHost -> ACommand Agent AENone
  DOWN :: SMPServer -> [ConnId] -> ACommand Agent AENone
  UP :: SMPServer -> [ConnId] -> ACommand Agent AENone
  SWITCH :: QueueDirection -> SwitchPhase -> ConnectionStats -> ACommand Agent AEConn
  RSYNC :: RatchetSyncState -> Maybe AgentCryptoError -> ConnectionStats -> ACommand Agent AEConn
  SEND :: MsgFlags -> MsgBody -> ACommand Client AEConn
  MID :: AgentMsgId -> ACommand Agent AEConn
  SENT :: AgentMsgId -> ACommand Agent AEConn
  MERR :: AgentMsgId -> AgentErrorType -> ACommand Agent AEConn
  MSG :: MsgMeta -> MsgFlags -> MsgBody -> ACommand Agent AEConn
  ACK :: AgentMsgId -> Maybe MsgReceiptInfo -> ACommand Client AEConn
  RCVD :: MsgMeta -> NonEmpty MsgReceipt -> ACommand Agent AEConn
  SWCH :: ACommand Client AEConn
  OFF :: ACommand Client AEConn
  DEL :: ACommand Client AEConn
  DEL_RCVQ :: SMPServer -> SMP.RecipientId -> Maybe AgentErrorType -> ACommand Agent AEConn
  DEL_CONN :: ACommand Agent AEConn
  DEL_USER :: Int64 -> ACommand Agent AENone
  CHK :: ACommand Client AEConn
  STAT :: ConnectionStats -> ACommand Agent AEConn
  OK :: ACommand Agent AEConn
  ERR :: AgentErrorType -> ACommand Agent AEConn
  SUSPENDED :: ACommand Agent AENone
  -- XFTP commands and responses
  RFPROG :: Int64 -> Int64 -> ACommand Agent AERcvFile
  RFDONE :: FilePath -> ACommand Agent AERcvFile
  RFERR :: AgentErrorType -> ACommand Agent AERcvFile
  SFPROG :: Int64 -> Int64 -> ACommand Agent AESndFile
  SFDONE :: ValidFileDescription 'FSender -> [ValidFileDescription 'FRecipient] -> ACommand Agent AESndFile
  SFERR :: AgentErrorType -> ACommand Agent AESndFile

deriving instance Eq (ACommand p e)

deriving instance Show (ACommand p e)

data ACmdTag = forall p e. (APartyI p, AEntityI e) => ACmdTag (SAParty p) (SAEntity e) (ACommandTag p e)

data APartyCmdTag p = forall e. AEntityI e => APCT (SAEntity e) (ACommandTag p e)

instance Eq (APartyCmdTag p) where
  APCT e cmd == APCT e' cmd' = case testEquality e e' of
    Just Refl -> cmd == cmd'
    Nothing -> False

deriving instance Show (APartyCmdTag p)

data ACommandTag (p :: AParty) (e :: AEntity) where
  NEW_ :: ACommandTag Client AEConn
  INV_ :: ACommandTag Agent AEConn
  JOIN_ :: ACommandTag Client AEConn
  CONF_ :: ACommandTag Agent AEConn
  LET_ :: ACommandTag Client AEConn
  REQ_ :: ACommandTag Agent AEConn
  ACPT_ :: ACommandTag Client AEConn
  RJCT_ :: ACommandTag Client AEConn
  INFO_ :: ACommandTag Agent AEConn
  CON_ :: ACommandTag Agent AEConn
  SUB_ :: ACommandTag Client AEConn
  END_ :: ACommandTag Agent AEConn
  CONNECT_ :: ACommandTag Agent AENone
  DISCONNECT_ :: ACommandTag Agent AENone
  DOWN_ :: ACommandTag Agent AENone
  UP_ :: ACommandTag Agent AENone
  SWITCH_ :: ACommandTag Agent AEConn
  RSYNC_ :: ACommandTag Agent AEConn
  SEND_ :: ACommandTag Client AEConn
  MID_ :: ACommandTag Agent AEConn
  SENT_ :: ACommandTag Agent AEConn
  MERR_ :: ACommandTag Agent AEConn
  MSG_ :: ACommandTag Agent AEConn
  ACK_ :: ACommandTag Client AEConn
  RCVD_ :: ACommandTag Agent AEConn
  SWCH_ :: ACommandTag Client AEConn
  OFF_ :: ACommandTag Client AEConn
  DEL_ :: ACommandTag Client AEConn
  DEL_RCVQ_ :: ACommandTag Agent AEConn
  DEL_CONN_ :: ACommandTag Agent AEConn
  DEL_USER_ :: ACommandTag Agent AENone
  CHK_ :: ACommandTag Client AEConn
  STAT_ :: ACommandTag Agent AEConn
  OK_ :: ACommandTag Agent AEConn
  ERR_ :: ACommandTag Agent AEConn
  SUSPENDED_ :: ACommandTag Agent AENone
  -- XFTP commands and responses
  RFDONE_ :: ACommandTag Agent AERcvFile
  RFPROG_ :: ACommandTag Agent AERcvFile
  RFERR_ :: ACommandTag Agent AERcvFile
  SFPROG_ :: ACommandTag Agent AESndFile
  SFDONE_ :: ACommandTag Agent AESndFile
  SFERR_ :: ACommandTag Agent AESndFile

deriving instance Eq (ACommandTag p e)

deriving instance Show (ACommandTag p e)

aPartyCmdTag :: APartyCmd p -> APartyCmdTag p
aPartyCmdTag (APC e cmd) = APCT e $ aCommandTag cmd

aCommandTag :: ACommand p e -> ACommandTag p e
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
  RSYNC {} -> RSYNC_
  SEND {} -> SEND_
  MID _ -> MID_
  SENT _ -> SENT_
  MERR {} -> MERR_
  MSG {} -> MSG_
  ACK {} -> ACK_
  RCVD {} -> RCVD_
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
  RFPROG {} -> RFPROG_
  RFDONE {} -> RFDONE_
  RFERR {} -> RFERR_
  SFPROG {} -> SFPROG_
  SFDONE {} -> SFDONE_
  SFERR {} -> SFERR_

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

data SwitchPhase = SPStarted | SPConfirmed | SPSecured | SPCompleted
  deriving (Eq, Show)

instance StrEncoding SwitchPhase where
  strEncode = \case
    SPStarted -> "started"
    SPConfirmed -> "confirmed"
    SPSecured -> "secured"
    SPCompleted -> "completed"
  strP =
    A.takeTill (== ' ') >>= \case
      "started" -> pure SPStarted
      "confirmed" -> pure SPConfirmed
      "secured" -> pure SPSecured
      "completed" -> pure SPCompleted
      _ -> fail "bad SwitchPhase"

instance ToJSON SwitchPhase where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON SwitchPhase where
  parseJSON = strParseJSON "SwitchPhase"

data RcvSwitchStatus
  = RSSwitchStarted
  | RSSendingQADD
  | RSSendingQUSE
  | RSReceivedMessage
  deriving (Eq, Show)

instance StrEncoding RcvSwitchStatus where
  strEncode = \case
    RSSwitchStarted -> "switch_started"
    RSSendingQADD -> "sending_qadd"
    RSSendingQUSE -> "sending_quse"
    RSReceivedMessage -> "received_message"
  strP =
    A.takeTill (== ' ') >>= \case
      "switch_started" -> pure RSSwitchStarted
      "sending_qadd" -> pure RSSendingQADD
      "sending_quse" -> pure RSSendingQUSE
      "received_message" -> pure RSReceivedMessage
      _ -> fail "bad RcvSwitchStatus"

instance ToField RcvSwitchStatus where toField = toField . decodeLatin1 . strEncode

instance FromField RcvSwitchStatus where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToJSON RcvSwitchStatus where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON RcvSwitchStatus where
  parseJSON = strParseJSON "RcvSwitchStatus"

data SndSwitchStatus
  = SSSendingQKEY
  | SSSendingQTEST
  deriving (Eq, Show)

instance StrEncoding SndSwitchStatus where
  strEncode = \case
    SSSendingQKEY -> "sending_qkey"
    SSSendingQTEST -> "sending_qtest"
  strP =
    A.takeTill (== ' ') >>= \case
      "sending_qkey" -> pure SSSendingQKEY
      "sending_qtest" -> pure SSSendingQTEST
      _ -> fail "bad SndSwitchStatus"

instance ToField SndSwitchStatus where toField = toField . decodeLatin1 . strEncode

instance FromField SndSwitchStatus where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToJSON SndSwitchStatus where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON SndSwitchStatus where
  parseJSON = strParseJSON "SndSwitchStatus"

data RatchetSyncState
  = RSOk
  | RSAllowed
  | RSRequired
  | RSStarted
  | RSAgreed
  deriving (Eq, Show)

instance StrEncoding RatchetSyncState where
  strEncode = \case
    RSOk -> "ok"
    RSAllowed -> "allowed"
    RSRequired -> "required"
    RSStarted -> "started"
    RSAgreed -> "agreed"
  strP =
    A.takeTill (== ' ') >>= \case
      "ok" -> pure RSOk
      "allowed" -> pure RSAllowed
      "required" -> pure RSRequired
      "started" -> pure RSStarted
      "agreed" -> pure RSAgreed
      _ -> fail "bad RatchetSyncState"

instance FromField RatchetSyncState where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

instance ToField RatchetSyncState where toField = toField . decodeLatin1 . strEncode

instance ToJSON RatchetSyncState where
  toEncoding = strToJEncoding
  toJSON = strToJSON

instance FromJSON RatchetSyncState where
  parseJSON = strParseJSON "RatchetSyncState"

data RcvQueueInfo = RcvQueueInfo
  { rcvServer :: SMPServer,
    rcvSwitchStatus :: Maybe RcvSwitchStatus,
    canAbortSwitch :: Bool
  }
  deriving (Eq, Show)

instance StrEncoding RcvQueueInfo where
  strEncode RcvQueueInfo {rcvServer, rcvSwitchStatus, canAbortSwitch} =
    ("srv=" <> strEncode rcvServer)
      <> maybe "" (\switch -> ";switch=" <> strEncode switch) rcvSwitchStatus
      <> (";can_abort_switch=" <> strEncode canAbortSwitch)
  strP = do
    rcvServer <- "srv=" *> strP
    rcvSwitchStatus <- optional $ ";switch=" *> strP
    canAbortSwitch <- ";can_abort_switch=" *> strP
    pure RcvQueueInfo {rcvServer, rcvSwitchStatus, canAbortSwitch}

data SndQueueInfo = SndQueueInfo
  { sndServer :: SMPServer,
    sndSwitchStatus :: Maybe SndSwitchStatus
  }
  deriving (Eq, Show)

instance StrEncoding SndQueueInfo where
  strEncode SndQueueInfo {sndServer, sndSwitchStatus} =
    "srv=" <> strEncode sndServer <> maybe "" (\switch -> ";switch=" <> strEncode switch) sndSwitchStatus
  strP = do
    sndServer <- "srv=" *> strP
    sndSwitchStatus <- optional $ ";switch=" *> strP
    pure SndQueueInfo {sndServer, sndSwitchStatus}

data ConnectionStats = ConnectionStats
  { connAgentVersion :: Version,
    rcvQueuesInfo :: [RcvQueueInfo],
    sndQueuesInfo :: [SndQueueInfo],
    ratchetSyncState :: RatchetSyncState,
    ratchetSyncSupported :: Bool
  }
  deriving (Eq, Show)

instance StrEncoding ConnectionStats where
  strEncode ConnectionStats {connAgentVersion, rcvQueuesInfo, sndQueuesInfo, ratchetSyncState, ratchetSyncSupported} =
    ("agent_version=" <> strEncode connAgentVersion)
      <> (" rcv=" <> strEncodeList rcvQueuesInfo)
      <> (" snd=" <> strEncodeList sndQueuesInfo)
      <> (" sync=" <> strEncode ratchetSyncState)
      <> (" sync_supported=" <> strEncode ratchetSyncSupported)
  strP = do
    connAgentVersion <- "agent_version=" *> strP
    rcvQueuesInfo <- " rcv=" *> strListP
    sndQueuesInfo <- " snd=" *> strListP
    ratchetSyncState <- " sync=" *> strP
    ratchetSyncSupported <- " sync_supported=" *> strP
    pure ConnectionStats {connAgentVersion, rcvQueuesInfo, sndQueuesInfo, ratchetSyncState, ratchetSyncSupported}

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

instance FromJSON NotificationsMode where
  parseJSON = strParseJSON "NotificationsMode"

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

instance StrEncoding MsgMeta where
  strEncode MsgMeta {integrity, recipient = (rmId, rTs), broker = (bmId, bTs), sndMsgId} =
    B.unwords
      [ strEncode integrity,
        "R=" <> bshow rmId <> "," <> showTs rTs,
        "B=" <> encode bmId <> "," <> showTs bTs,
        "S=" <> bshow sndMsgId
      ]
    where
      showTs = B.pack . formatISO8601Millis
  strP = do
    integrity <- strP
    recipient <- " R=" *> partyMeta A.decimal
    broker <- " B=" *> partyMeta base64P
    sndMsgId <- " S=" *> A.decimal
    pure MsgMeta {integrity, recipient, broker, sndMsgId}
    where
      partyMeta idParser = (,) <$> idParser <* A.char ',' <*> tsISO8601P

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
        e2eEncryption_ :: Maybe (E2ERatchetParams 'C.X448),
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
  | AgentRatchetKey
      { agentVersion :: Version,
        e2eEncryption :: E2ERatchetParams 'C.X448,
        info :: ByteString
      }
  deriving (Show)

instance Encoding AgentMsgEnvelope where
  smpEncode = \case
    AgentConfirmation {agentVersion, e2eEncryption_, encConnInfo} ->
      smpEncode (agentVersion, 'C', e2eEncryption_, Tail encConnInfo)
    AgentMsgEnvelope {agentVersion, encAgentMessage} ->
      smpEncode (agentVersion, 'M', Tail encAgentMessage)
    AgentInvitation {agentVersion, connReq, connInfo} ->
      smpEncode (agentVersion, 'I', Large $ strEncode connReq, Tail connInfo)
    AgentRatchetKey {agentVersion, e2eEncryption, info} ->
      smpEncode (agentVersion, 'R', e2eEncryption, Tail info)
  smpP = do
    agentVersion <- smpP
    smpP >>= \case
      'C' -> do
        (e2eEncryption_, Tail encConnInfo) <- smpP
        pure AgentConfirmation {agentVersion, e2eEncryption_, encConnInfo}
      'M' -> do
        Tail encAgentMessage <- smpP
        pure AgentMsgEnvelope {agentVersion, encAgentMessage}
      'I' -> do
        connReq <- strDecode . unLarge <$?> smpP
        Tail connInfo <- smpP
        pure AgentInvitation {agentVersion, connReq, connInfo}
      'R' -> do
        e2eEncryption <- smpP
        Tail info <- smpP
        pure AgentRatchetKey {agentVersion, e2eEncryption, info}
      _ -> fail "bad AgentMsgEnvelope"

-- SMP agent message formats (after double ratchet decryption,
-- or in case of AgentInvitation - in plain text body)
-- AgentRatchetInfo is not encrypted with double ratchet, but with per-queue E2E encryption
data AgentMessage
  = AgentConnInfo ConnInfo
  | -- AgentConnInfoReply is only used in duplexHandshake mode (v2), allowing to include reply queue(s) in the initial confirmation.
    -- It makes REPLY message unnecessary.
    AgentConnInfoReply (NonEmpty SMPQueueInfo) ConnInfo
  | AgentRatchetInfo ByteString
  | AgentMessage APrivHeader AMessage
  deriving (Show)

instance Encoding AgentMessage where
  smpEncode = \case
    AgentConnInfo cInfo -> smpEncode ('I', Tail cInfo)
    AgentConnInfoReply smpQueues cInfo -> smpEncode ('D', smpQueues, Tail cInfo) -- 'D' stands for "duplex"
    AgentRatchetInfo info -> smpEncode ('R', Tail info)
    AgentMessage hdr aMsg -> smpEncode ('M', hdr, aMsg)
  smpP =
    smpP >>= \case
      'I' -> AgentConnInfo . unTail <$> smpP
      'D' -> AgentConnInfoReply <$> smpP <*> (unTail <$> smpP)
      'R' -> AgentRatchetInfo . unTail <$> smpP
      'M' -> AgentMessage <$> smpP <*> smpP
      _ -> fail "bad AgentMessage"

data AgentMessageType
  = AM_CONN_INFO
  | AM_CONN_INFO_REPLY
  | AM_RATCHET_INFO
  | AM_HELLO_
  | AM_REPLY_
  | AM_A_MSG_
  | AM_A_RCVD_
  | AM_QCONT_
  | AM_QADD_
  | AM_QKEY_
  | AM_QUSE_
  | AM_QTEST_
  | AM_EREADY_
  deriving (Eq, Show)

instance Encoding AgentMessageType where
  smpEncode = \case
    AM_CONN_INFO -> "C"
    AM_CONN_INFO_REPLY -> "D"
    AM_RATCHET_INFO -> "S"
    AM_HELLO_ -> "H"
    AM_REPLY_ -> "R"
    AM_A_MSG_ -> "M"
    AM_A_RCVD_ -> "V"
    AM_QCONT_ -> "QC"
    AM_QADD_ -> "QA"
    AM_QKEY_ -> "QK"
    AM_QUSE_ -> "QU"
    AM_QTEST_ -> "QT"
    AM_EREADY_ -> "E"
  smpP =
    A.anyChar >>= \case
      'C' -> pure AM_CONN_INFO
      'D' -> pure AM_CONN_INFO_REPLY
      'S' -> pure AM_RATCHET_INFO
      'H' -> pure AM_HELLO_
      'R' -> pure AM_REPLY_
      'M' -> pure AM_A_MSG_
      'V' -> pure AM_A_RCVD_
      'Q' ->
        A.anyChar >>= \case
          'C' -> pure AM_QCONT_
          'A' -> pure AM_QADD_
          'K' -> pure AM_QKEY_
          'U' -> pure AM_QUSE_
          'T' -> pure AM_QTEST_
          _ -> fail "bad AgentMessageType"
      'E' -> pure AM_EREADY_
      _ -> fail "bad AgentMessageType"

agentMessageType :: AgentMessage -> AgentMessageType
agentMessageType = \case
  AgentConnInfo _ -> AM_CONN_INFO
  AgentConnInfoReply {} -> AM_CONN_INFO_REPLY
  AgentRatchetInfo _ -> AM_RATCHET_INFO
  AgentMessage _ aMsg -> case aMsg of
    -- HELLO is used both in v1 and in v2, but differently.
    -- - in v1 (and, possibly, in v2 for simplex connections) can be sent multiple times,
    --   until the queue is secured - the OK response from the server instead of initial AUTH errors confirms it.
    -- - in v2 duplexHandshake it is sent only once, when it is known that the queue was secured.
    HELLO -> AM_HELLO_
    -- REPLY is only used in v1
    REPLY _ -> AM_REPLY_
    A_MSG _ -> AM_A_MSG_
    A_RCVD {} -> AM_A_RCVD_
    QCONT _ -> AM_QCONT_
    QADD _ -> AM_QADD_
    QKEY _ -> AM_QKEY_
    QUSE _ -> AM_QUSE_
    QTEST _ -> AM_QTEST_
    EREADY _ -> AM_EREADY_

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
  | A_RCVD_
  | QCONT_
  | QADD_
  | QKEY_
  | QUSE_
  | QTEST_
  | EREADY_
  deriving (Eq)

instance Encoding AMsgType where
  smpEncode = \case
    HELLO_ -> "H"
    REPLY_ -> "R"
    A_MSG_ -> "M"
    A_RCVD_ -> "V"
    QCONT_ -> "QC"
    QADD_ -> "QA"
    QKEY_ -> "QK"
    QUSE_ -> "QU"
    QTEST_ -> "QT"
    EREADY_ -> "E"
  smpP =
    A.anyChar >>= \case
      'H' -> pure HELLO_
      'R' -> pure REPLY_
      'M' -> pure A_MSG_
      'V' -> pure A_RCVD_
      'Q' ->
        A.anyChar >>= \case
          'C' -> pure QCONT_
          'A' -> pure QADD_
          'K' -> pure QKEY_
          'U' -> pure QUSE_
          'T' -> pure QTEST_
          _ -> fail "bad AMsgType"
      'E' -> pure EREADY_
      _ -> fail "bad AMsgType"

-- | Messages sent between SMP agents once SMP queue is secured.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md#messages-between-smp-agents
data AMessage
  = -- | the first message in the queue to validate it is secured
    HELLO
  | -- | reply queues information
    REPLY (NonEmpty SMPQueueInfo)
  | -- | agent envelope for the client message
    A_MSG MsgBody
  | -- | agent envelope for delivery receipt
    A_RCVD (NonEmpty AMessageReceipt)
  | -- | the message instructing the client to continue sending messages (after ERR QUOTA)
    QCONT SndQAddr
  | -- add queue to connection (sent by recipient), with optional address of the replaced queue
    QADD (NonEmpty (SMPQueueUri, Maybe SndQAddr))
  | -- key to secure the added queues and agree e2e encryption key (sent by sender)
    QKEY (NonEmpty (SMPQueueInfo, SndPublicVerifyKey))
  | -- inform that the queues are ready to use (sent by recipient)
    QUSE (NonEmpty (SndQAddr, Bool))
  | -- sent by the sender to test new queues and to complete switching
    QTEST (NonEmpty SndQAddr)
  | -- ratchet re-synchronization is complete, with last decrypted sender message id (recipient's `last_external_snd_msg_id`)
    EREADY AgentMsgId
  deriving (Show)

-- | this type is used to send as part of the protocol between different clients
-- TODO possibly, rename fields and types referring to external and internal IDs to make them different
data AMessageReceipt = AMessageReceipt
  { agentMsgId :: AgentMsgId, -- this is an external snd message ID referenced by the message recipient
    msgHash :: MsgHash,
    rcptInfo :: MsgReceiptInfo
  }
  deriving (Show)

-- | this type is used as part of agent protocol to communicate with the user application
data MsgReceipt = MsgReceipt
  { agentMsgId :: AgentMsgId, -- this is an internal agent message ID of received message
    msgRcptStatus :: MsgReceiptStatus
  }
  deriving (Eq, Show)

data MsgReceiptStatus = MROk | MRBadMsgHash
  deriving (Eq, Show)

instance StrEncoding MsgReceiptStatus where
  strEncode = \case
    MROk -> "ok"
    MRBadMsgHash -> "badMsgHash"
  strP =
    A.takeWhile1 (/= ' ') >>= \case
      "ok" -> pure MROk
      "badMsgHash" -> pure MRBadMsgHash
      _ -> fail "bad MsgReceiptStatus"

instance ToJSON MsgReceiptStatus where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON MsgReceiptStatus where
  parseJSON = strParseJSON "MsgReceiptStatus"

type MsgReceiptInfo = ByteString

type SndQAddr = (SMPServer, SMP.SenderId)

instance Encoding AMessage where
  smpEncode = \case
    HELLO -> smpEncode HELLO_
    REPLY smpQueues -> smpEncode (REPLY_, smpQueues)
    A_MSG body -> smpEncode (A_MSG_, Tail body)
    A_RCVD mrs -> smpEncode (A_RCVD_, mrs)
    QCONT addr -> smpEncode (QCONT_, addr)
    QADD qs -> smpEncode (QADD_, qs)
    QKEY qs -> smpEncode (QKEY_, qs)
    QUSE qs -> smpEncode (QUSE_, qs)
    QTEST qs -> smpEncode (QTEST_, qs)
    EREADY lastDecryptedMsgId -> smpEncode (EREADY_, lastDecryptedMsgId)
  smpP =
    smpP
      >>= \case
        HELLO_ -> pure HELLO
        REPLY_ -> REPLY <$> smpP
        A_MSG_ -> A_MSG . unTail <$> smpP
        A_RCVD_ -> A_RCVD <$> smpP
        QCONT_ -> QCONT <$> smpP
        QADD_ -> QADD <$> smpP
        QKEY_ -> QKEY <$> smpP
        QUSE_ -> QUSE <$> smpP
        QTEST_ -> QTEST <$> smpP
        EREADY_ -> EREADY <$> smpP

instance Encoding AMessageReceipt where
  smpEncode AMessageReceipt {agentMsgId, msgHash, rcptInfo} =
    smpEncode (agentMsgId, msgHash, Large rcptInfo)
  smpP = do
    (agentMsgId, msgHash, Large rcptInfo) <- smpP
    pure AMessageReceipt {agentMsgId, msgHash, rcptInfo}

instance StrEncoding MsgReceipt where
  strEncode MsgReceipt {agentMsgId, msgRcptStatus} =
    strEncode agentMsgId <> ":" <> strEncode msgRcptStatus
  strP = do
    agentMsgId <- strP <* A.char ':'
    msgRcptStatus <- strP
    pure MsgReceipt {agentMsgId, msgRcptStatus}

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
    _crScheme :: ConnReqScheme <- strP
    crMode <- A.char '/' *> crModeP <* optional (A.char '/') <* "#/?"
    query <- strP
    crAgentVRange <- queryParam "v" query
    crSmpQueues <- queryParam "smp" query
    let crClientData = safeDecodeUtf8 <$> queryParamStr "data" query
    let crData = ConnReqUriData {crScheme = CRSSimplex, crAgentVRange, crSmpQueues, crClientData}
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

type RcvFileId = ByteString

type SndFileId = ByteString

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
  queueId :: q -> SMP.QueueId

qAddress :: SMPQueue q => q -> (SMPServer, SMP.QueueId)
qAddress q = (qServer q, queueId q)
{-# INLINE qAddress #-}

sameQueue :: SMPQueue q => (SMPServer, SMP.QueueId) -> q -> Bool
sameQueue addr q = sameQAddress addr (qAddress q)
{-# INLINE sameQueue #-}

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
  queueId SMPQueueUri {queueAddress} = queueId queueAddress
  {-# INLINE queueId #-}

instance SMPQueue SMPQueueInfo where
  qServer SMPQueueInfo {queueAddress} = qServer queueAddress
  {-# INLINE qServer #-}
  queueId SMPQueueInfo {queueAddress} = queueId queueAddress
  {-# INLINE queueId #-}

instance SMPQueue SMPQueueAddress where
  qServer SMPQueueAddress {smpServer} = smpServer
  {-# INLINE qServer #-}
  queueId SMPQueueAddress {senderId} = senderId
  {-# INLINE queueId #-}

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
    crSmpQueues :: NonEmpty SMPQueueUri,
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
  deriving (Eq, Show)

instance StrEncoding MsgIntegrity where
  strP = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> strP)
  strEncode = \case
    MsgOk -> "OK"
    MsgError e -> "ERR " <> strEncode e

-- | Error of message integrity validation.
data MsgErrorType
  = MsgSkipped {fromMsgId :: AgentMsgId, toMsgId :: AgentMsgId}
  | MsgBadId {msgId :: AgentMsgId}
  | MsgBadHash
  | MsgDuplicate
  deriving (Eq, Show)

instance StrEncoding MsgErrorType where
  strP =
    "ID " *> (MsgBadId <$> A.decimal)
      <|> "NO_ID " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
      <|> "HASH" $> MsgBadHash
      <|> "DUPLICATE" $> MsgDuplicate
  strEncode = \case
    MsgSkipped fromMsgId toMsgId ->
      B.unwords ["NO_ID", bshow fromMsgId, bshow toMsgId]
    MsgBadId aMsgId -> "ID " <> bshow aMsgId
    MsgBadHash -> "HASH"
    MsgDuplicate -> "DUPLICATE"

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
  | -- | XRCP protocol errors forwarded to agent clients
    RCP {rcpErr :: RCErrorType}
  | -- | SMP server errors
    BROKER {brokerAddress :: String, brokerErr :: BrokerErrorType}
  | -- | errors of other agents
    AGENT {agentErr :: SMPAgentError}
  | -- | agent implementation or dependency errors
    INTERNAL {internalErr :: String}
  | -- | agent inactive
    INACTIVE
  deriving (Eq, Show, Exception)

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
  deriving (Eq, Read, Show, Exception)

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
  deriving (Eq, Read, Show, Exception)

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
  deriving (Eq, Read, Show, Exception)

-- | Errors of another SMP agent.
data SMPAgentError
  = -- | client or agent message that failed to parse
    A_MESSAGE
  | -- | prohibited SMP/agent message
    A_PROHIBITED
  | -- | incompatible version of SMP client, agent or encryption protocols
    A_VERSION
  | -- | cannot decrypt message
    A_CRYPTO {cryptoErr :: AgentCryptoError}
  | -- | duplicate message - this error is detected by ratchet decryption - this message will be ignored and not shown
    -- it may also indicate a loss of ratchet synchronization (when only one message is sent via copied ratchet)
    A_DUPLICATE
  | -- | error in the message to add/delete/etc queue in connection
    A_QUEUE {queueErr :: String}
  deriving (Eq, Read, Show, Exception)

data AgentCryptoError
  = -- | AES decryption error
    DECRYPT_AES
  | -- CryptoBox decryption error
    DECRYPT_CB
  | -- | can't decrypt ratchet header, possibly ratchet out of sync due to device change
    RATCHET_HEADER
  | -- | earlier message number (or, possibly, skipped message that failed to decrypt?)
    RATCHET_EARLIER Word32
  | -- | too many skipped messages
    RATCHET_SKIPPED Word32
  | -- | ratchet synchronization error
    RATCHET_SYNC
  deriving (Eq, Read, Show, Exception)

instance StrEncoding AgentCryptoError where
  strP =
    "DECRYPT_AES" $> DECRYPT_AES
      <|> "DECRYPT_CB" $> DECRYPT_CB
      <|> "RATCHET_HEADER" $> RATCHET_HEADER
      <|> "RATCHET_EARLIER " *> (RATCHET_EARLIER <$> strP)
      <|> "RATCHET_SKIPPED " *> (RATCHET_SKIPPED <$> strP)
      <|> "RATCHET_SYNC" $> RATCHET_SYNC
  strEncode = \case
    DECRYPT_AES -> "DECRYPT_AES"
    DECRYPT_CB -> "DECRYPT_CB"
    RATCHET_HEADER -> "RATCHET_HEADER"
    RATCHET_EARLIER n -> "RATCHET_EARLIER " <> strEncode n
    RATCHET_SKIPPED n -> "RATCHET_SKIPPED " <> strEncode n
    RATCHET_SYNC -> "RATCHET_SYNC"

instance StrEncoding AgentErrorType where
  strP =
    "CMD " *> (CMD <$> parseRead1)
      <|> "CONN " *> (CONN <$> parseRead1)
      <|> "SMP " *> (SMP <$> strP)
      <|> "NTF " *> (NTF <$> strP)
      <|> "XFTP " *> (XFTP <$> strP)
      <|> "RCP " *> (RCP <$> strP)
      <|> "BROKER " *> (BROKER <$> textP <* " RESPONSE " <*> (RESPONSE <$> textP))
      <|> "BROKER " *> (BROKER <$> textP <* " TRANSPORT " <*> (TRANSPORT <$> transportErrorP))
      <|> "BROKER " *> (BROKER <$> textP <* A.space <*> parseRead1)
      <|> "AGENT CRYPTO " *> (AGENT . A_CRYPTO <$> parseRead A.takeByteString)
      <|> "AGENT QUEUE " *> (AGENT . A_QUEUE <$> parseRead A.takeByteString)
      <|> "AGENT " *> (AGENT <$> parseRead1)
      <|> "INTERNAL " *> (INTERNAL <$> parseRead A.takeByteString)
      <|> "INACTIVE" $> INACTIVE
    where
      textP = T.unpack . safeDecodeUtf8 <$> A.takeTill (== ' ')
  strEncode = \case
    CMD e -> "CMD " <> bshow e
    CONN e -> "CONN " <> bshow e
    SMP e -> "SMP " <> strEncode e
    NTF e -> "NTF " <> strEncode e
    XFTP e -> "XFTP " <> strEncode e
    RCP e -> "RCP " <> strEncode e
    BROKER srv (RESPONSE e) -> "BROKER " <> text srv <> " RESPONSE " <> text e
    BROKER srv (TRANSPORT e) -> "BROKER " <> text srv <> " TRANSPORT " <> serializeTransportError e
    BROKER srv e -> "BROKER " <> text srv <> " " <> bshow e
    AGENT (A_CRYPTO e) -> "AGENT CRYPTO " <> bshow e
    AGENT (A_QUEUE e) -> "AGENT QUEUE " <> bshow e
    AGENT e -> "AGENT " <> bshow e
    INTERNAL e -> "INTERNAL " <> bshow e
    INACTIVE -> "INACTIVE"
    where
      text = encodeUtf8 . T.pack

cryptoErrToSyncState :: AgentCryptoError -> RatchetSyncState
cryptoErrToSyncState = \case
  DECRYPT_AES -> RSAllowed
  DECRYPT_CB -> RSAllowed
  RATCHET_HEADER -> RSRequired
  RATCHET_EARLIER _ -> RSAllowed
  RATCHET_SKIPPED _ -> RSRequired
  RATCHET_SYNC -> RSRequired

-- | SMP agent command and response parser for commands passed via network (only parses binary length)
networkCommandP :: Parser ACmd
networkCommandP = commandP A.takeByteString

-- | SMP agent command and response parser for commands stored in db (fully parses binary bodies)
dbCommandP :: Parser ACmd
dbCommandP = commandP $ A.take =<< (A.decimal <* "\n")

instance StrEncoding ACmdTag where
  strEncode (ACmdTag _ _ cmd) = strEncode cmd
  strP =
    A.takeTill (== ' ') >>= \case
      "NEW" -> t NEW_
      "INV" -> ct INV_
      "JOIN" -> t JOIN_
      "CONF" -> ct CONF_
      "LET" -> t LET_
      "REQ" -> ct REQ_
      "ACPT" -> t ACPT_
      "RJCT" -> t RJCT_
      "INFO" -> ct INFO_
      "CON" -> ct CON_
      "SUB" -> t SUB_
      "END" -> ct END_
      "CONNECT" -> nt CONNECT_
      "DISCONNECT" -> nt DISCONNECT_
      "DOWN" -> nt DOWN_
      "UP" -> nt UP_
      "SWITCH" -> ct SWITCH_
      "RSYNC" -> ct RSYNC_
      "SEND" -> t SEND_
      "MID" -> ct MID_
      "SENT" -> ct SENT_
      "MERR" -> ct MERR_
      "MSG" -> ct MSG_
      "ACK" -> t ACK_
      "RCVD" -> ct RCVD_
      "SWCH" -> t SWCH_
      "OFF" -> t OFF_
      "DEL" -> t DEL_
      "DEL_RCVQ" -> ct DEL_RCVQ_
      "DEL_CONN" -> ct DEL_CONN_
      "DEL_USER" -> nt DEL_USER_
      "CHK" -> t CHK_
      "STAT" -> ct STAT_
      "OK" -> ct OK_
      "ERR" -> ct ERR_
      "SUSPENDED" -> nt SUSPENDED_
      "RFPROG" -> at SAERcvFile RFPROG_
      "RFDONE" -> at SAERcvFile RFDONE_
      "RFERR" -> at SAERcvFile RFERR_
      "SFPROG" -> at SAESndFile SFPROG_
      "SFDONE" -> at SAESndFile SFDONE_
      "SFERR" -> at SAESndFile SFERR_
      _ -> fail "bad ACmdTag"
    where
      t = pure . ACmdTag SClient SAEConn
      at e = pure . ACmdTag SAgent e
      ct = at SAEConn
      nt = at SAENone

instance APartyI p => StrEncoding (APartyCmdTag p) where
  strEncode (APCT _ cmd) = strEncode cmd
  strP = (\(ACmdTag _ e t) -> checkParty $ APCT e t) <$?> strP

instance (APartyI p, AEntityI e) => StrEncoding (ACommandTag p e) where
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
    RSYNC_ -> "RSYNC"
    SEND_ -> "SEND"
    MID_ -> "MID"
    SENT_ -> "SENT"
    MERR_ -> "MERR"
    MSG_ -> "MSG"
    ACK_ -> "ACK"
    RCVD_ -> "RCVD"
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
    RFPROG_ -> "RFPROG"
    RFDONE_ -> "RFDONE"
    RFERR_ -> "RFERR"
    SFPROG_ -> "SFPROG"
    SFDONE_ -> "SFDONE"
    SFERR_ -> "SFERR"
  strP = (\(APCT _ t) -> checkEntity t) <$?> strP

checkParty :: forall t p p'. (APartyI p, APartyI p') => t p' -> Either String (t p)
checkParty x = case testEquality (sAParty @p) (sAParty @p') of
  Just Refl -> Right x
  Nothing -> Left "bad party"

checkEntity :: forall t e e'. (AEntityI e, AEntityI e') => t e' -> Either String (t e)
checkEntity x = case testEquality (sAEntity @e) (sAEntity @e') of
  Just Refl -> Right x
  Nothing -> Left "bad entity"

-- | SMP agent command and response parser
commandP :: Parser ByteString -> Parser ACmd
commandP binaryP =
  strP
    >>= \case
      ACmdTag SClient e cmd ->
        ACmd SClient e <$> case cmd of
          NEW_ -> s (NEW <$> strP_ <*> strP_ <*> strP)
          JOIN_ -> s (JOIN <$> strP_ <*> strP_ <*> strP_ <*> binaryP)
          LET_ -> s (LET <$> A.takeTill (== ' ') <* A.space <*> binaryP)
          ACPT_ -> s (ACPT <$> A.takeTill (== ' ') <* A.space <*> binaryP)
          RJCT_ -> s (RJCT <$> A.takeByteString)
          SUB_ -> pure SUB
          SEND_ -> s (SEND <$> smpP <* A.space <*> binaryP)
          ACK_ -> s (ACK <$> A.decimal <*> optional (A.space *> binaryP))
          SWCH_ -> pure SWCH
          OFF_ -> pure OFF
          DEL_ -> pure DEL
          CHK_ -> pure CHK
      ACmdTag SAgent e cmd ->
        ACmd SAgent e <$> case cmd of
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
          RSYNC_ -> s (RSYNC <$> strP_ <*> strP <*> strP)
          MID_ -> s (MID <$> A.decimal)
          SENT_ -> s (SENT <$> A.decimal)
          MERR_ -> s (MERR <$> A.decimal <* A.space <*> strP)
          MSG_ -> s (MSG <$> strP <* A.space <*> smpP <* A.space <*> binaryP)
          RCVD_ -> s (RCVD <$> strP <* A.space <*> strP)
          DEL_RCVQ_ -> s (DEL_RCVQ <$> strP_ <*> strP_ <*> strP)
          DEL_CONN_ -> pure DEL_CONN
          DEL_USER_ -> s (DEL_USER <$> strP)
          STAT_ -> s (STAT <$> strP)
          OK_ -> pure OK
          ERR_ -> s (ERR <$> strP)
          SUSPENDED_ -> pure SUSPENDED
          RFPROG_ -> s (RFPROG <$> A.decimal <* A.space <*> A.decimal)
          RFDONE_ -> s (RFDONE <$> strP)
          RFERR_ -> s (RFERR <$> strP)
          SFPROG_ -> s (SFPROG <$> A.decimal <* A.space <*> A.decimal)
          SFDONE_ -> s (sfDone . safeDecodeUtf8 <$?> binaryP)
          SFERR_ -> s (SFERR <$> strP)
  where
    s :: Parser a -> Parser a
    s p = A.space *> p
    connections :: Parser [ConnId]
    connections = strP `A.sepBy'` A.char ','
    sfDone :: Text -> Either String (ACommand 'Agent 'AESndFile)
    sfDone t =
      let ds = T.splitOn fdSeparator t
       in case ds of
            [] -> Left "no sender file description"
            sd : rds -> SFDONE <$> strDecode (encodeUtf8 sd) <*> mapM (strDecode . encodeUtf8) rds

parseCommand :: ByteString -> Either AgentErrorType ACmd
parseCommand = parse (commandP A.takeByteString) $ CMD SYNTAX

-- | Serialize SMP agent command.
serializeCommand :: ACommand p e -> ByteString
serializeCommand = \case
  NEW ntfs cMode subMode -> s (NEW_, ntfs, cMode, subMode)
  INV cReq -> s (INV_, cReq)
  JOIN ntfs cReq subMode cInfo -> s (JOIN_, ntfs, cReq, subMode, Str $ serializeBinary cInfo)
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
  RSYNC rrState cryptoErr cstats -> s (RSYNC_, rrState, cryptoErr, cstats)
  SEND msgFlags msgBody -> B.unwords [s SEND_, smpEncode msgFlags, serializeBinary msgBody]
  MID mId -> s (MID_, Str $ bshow mId)
  SENT mId -> s (SENT_, Str $ bshow mId)
  MERR mId e -> s (MERR_, Str $ bshow mId, e)
  MSG msgMeta msgFlags msgBody -> B.unwords [s MSG_, s msgMeta, smpEncode msgFlags, serializeBinary msgBody]
  ACK mId rcptInfo_ -> s (ACK_, Str $ bshow mId) <> maybe "" (B.cons ' ' . serializeBinary) rcptInfo_
  RCVD msgMeta rcpts -> s (RCVD_, msgMeta, rcpts)
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
  RFPROG rcvd total -> s (RFPROG_, rcvd, total)
  RFDONE fPath -> s (RFDONE_, fPath)
  RFERR e -> s (RFERR_, e)
  SFPROG sent total -> s (SFPROG_, sent, total)
  SFDONE sd rds -> B.unwords [s SFDONE_, serializeBinary (sfDone sd rds)]
  SFERR e -> s (SFERR_, e)
  where
    s :: StrEncoding a => a -> ByteString
    s = strEncode
    connections :: [ConnId] -> ByteString
    connections = B.intercalate "," . map strEncode
    sfDone sd rds = B.intercalate fdSeparator $ strEncode sd : map strEncode rds

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
tPut h (corrId, connId, APC _ cmd) =
  liftIO $ tPutRaw h (corrId, connId, serializeCommand cmd)

-- | Receive client and agent transmissions from TCP connection.
tGet :: forall c m p. (Transport c, MonadIO m) => SAParty p -> c -> m (ATransmissionOrError p)
tGet party h = liftIO (tGetRaw h) >>= tParseLoadBody
  where
    tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
    tParseLoadBody t@(corrId, entId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tConnId t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (corrId, entId, fullCmd)

    fromParty :: ACmd -> Either AgentErrorType (APartyCmd p)
    fromParty (ACmd (p :: p1) e cmd) = case testEquality party p of
      Just Refl -> Right $ APC e cmd
      _ -> Left $ CMD PROHIBITED

    tConnId :: ARawTransmission -> APartyCmd p -> Either AgentErrorType (APartyCmd p)
    tConnId (_, entId, _) (APC e cmd) =
      APC e <$> case cmd of
        -- NEW, JOIN and ACPT have optional connection ID
        NEW {} -> Right cmd
        JOIN {} -> Right cmd
        ACPT {} -> Right cmd
        -- ERROR response does not always have connection ID
        ERR _ -> Right cmd
        CONNECT {} -> Right cmd
        DISCONNECT {} -> Right cmd
        DOWN {} -> Right cmd
        UP {} -> Right cmd
        SUSPENDED {} -> Right cmd
        -- other responses must have connection ID
        _
          | B.null entId -> Left $ CMD NO_CONN
          | otherwise -> Right cmd

    cmdWithMsgBody :: APartyCmd p -> m (Either AgentErrorType (APartyCmd p))
    cmdWithMsgBody (APC e cmd) =
      APC e <$$> case cmd of
        SEND msgFlags body -> SEND msgFlags <$$> getBody body
        MSG msgMeta msgFlags body -> MSG msgMeta msgFlags <$$> getBody body
        JOIN ntfs qUri subMode cInfo -> JOIN ntfs qUri subMode <$$> getBody cInfo
        CONF confId srvs cInfo -> CONF confId srvs <$$> getBody cInfo
        LET confId cInfo -> LET confId <$$> getBody cInfo
        REQ invId srvs cInfo -> REQ invId srvs <$$> getBody cInfo
        ACPT invId cInfo -> ACPT invId <$$> getBody cInfo
        INFO cInfo -> INFO <$$> getBody cInfo
        _ -> pure $ Right cmd

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

$(J.deriveJSON defaultJSON ''RcvQueueInfo)

$(J.deriveJSON defaultJSON ''SndQueueInfo)

$(J.deriveJSON defaultJSON ''ConnectionStats)

$(J.deriveJSON (sumTypeJSON fstToLower) ''MsgErrorType)

$(J.deriveJSON (sumTypeJSON fstToLower) ''MsgIntegrity)

$(J.deriveJSON (sumTypeJSON id) ''CommandErrorType)

$(J.deriveJSON (sumTypeJSON id) ''ConnectionErrorType)

$(J.deriveJSON (sumTypeJSON id) ''BrokerErrorType)

$(J.deriveJSON (sumTypeJSON id) ''AgentCryptoError)

$(J.deriveJSON (sumTypeJSON id) ''SMPAgentError)

$(J.deriveJSON (sumTypeJSON id) ''AgentErrorType)
