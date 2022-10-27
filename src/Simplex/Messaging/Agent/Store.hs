{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store where

import Control.Exception (Exception)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Time (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (RatchetX448)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
  ( MsgBody,
    MsgFlags,
    MsgId,
    NotifierId,
    NtfPrivateSignKey,
    NtfPublicVerifyKey,
    RcvDhSecret,
    RcvNtfDhSecret,
    RcvPrivateSignKey,
    SndPrivateSignKey,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util ((<$?>))
import Simplex.Messaging.Version

-- * Queue types

-- | A receive queue. SMP queue through which the agent receives messages from a sender.
data RcvQueue = RcvQueue
  { connId :: ConnId,
    server :: SMPServer,
    -- | recipient queue ID
    rcvId :: SMP.RecipientId,
    -- | key used by the recipient to sign transmissions
    rcvPrivateKey :: RcvPrivateSignKey,
    -- | shared DH secret used to encrypt/decrypt message bodies from server to recipient
    rcvDhSecret :: RcvDhSecret,
    -- | private DH key related to public sent to sender out-of-band (to agree simple per-queue e2e)
    e2ePrivKey :: C.PrivateKeyX25519,
    -- | public sender's DH key and agreed shared DH secret for simple per-queue e2e
    e2eDhSecret :: Maybe C.DhSecretX25519,
    -- | sender queue ID
    sndId :: SMP.SenderId,
    -- | queue status
    status :: QueueStatus,
    -- | database queue ID (within connection), can be Nothing for old queues
    dbQueueId :: Int64,
    -- | True for a primary queue of the connection
    primary :: Bool,
    -- | True for the next primary queue
    nextPrimary :: Bool,
    -- | database queue ID to replace, Nothing if this queue is not replacing another, `Just Nothing` is used for replacing old queues
    dbReplaceQueueId :: Maybe Int64,
    -- | SMP client version
    smpClientVersion :: Version,
    -- | credentials used in context of notifications
    clientNtfCreds :: Maybe ClientNtfCreds
  }
  deriving (Eq, Show)

data ClientNtfCreds = ClientNtfCreds
  { -- | key pair to be used by the notification server to sign transmissions
    ntfPublicKey :: NtfPublicVerifyKey,
    ntfPrivateKey :: NtfPrivateSignKey,
    -- | queue ID to be used by the notification server for NSUB command
    notifierId :: NotifierId,
    -- | shared DH secret used to encrypt/decrypt notification metadata (NMsgMeta) from server to recipient
    rcvNtfDhSecret :: RcvNtfDhSecret
  }
  deriving (Eq, Show)

-- | A send queue. SMP queue through which the agent sends messages to a recipient.
data SndQueue = SndQueue
  { connId :: ConnId,
    server :: SMPServer,
    -- | sender queue ID
    sndId :: SMP.SenderId,
    -- | key pair used by the sender to sign transmissions
    sndPublicKey :: Maybe C.APublicVerifyKey,
    sndPrivateKey :: SndPrivateSignKey,
    -- | DH public key used to negotiate per-queue e2e encryption
    e2ePubKey :: Maybe C.PublicKeyX25519,
    -- | shared DH secret agreed for simple per-queue e2e encryption
    e2eDhSecret :: C.DhSecretX25519,
    -- | queue status
    status :: QueueStatus,
    -- | database queue ID (within connection), can be Nothing for old queues
    dbQueueId :: Int64,
    -- | True for a primary queue of the connection
    primary :: Bool,
    -- | True for the next primary queue
    nextPrimary :: Bool,
    -- | ID of the queue this one is replacing
    dbReplaceQueueId :: Maybe Int64,
    -- | SMP client version
    smpClientVersion :: Version
  }
  deriving (Eq, Show)

instance SMPQueue RcvQueue where
  qServer RcvQueue {server} = server
  {-# INLINE qServer #-}
  qAddress RcvQueue {server, rcvId} = (server, rcvId)
  {-# INLINE qAddress #-}
  sameQueue addr q = sameQAddress addr (qAddress q)
  {-# INLINE sameQueue #-}

instance SMPQueue SndQueue where
  qServer SndQueue {server} = server
  {-# INLINE qServer #-}
  qAddress SndQueue {server, sndId} = (server, sndId)
  {-# INLINE qAddress #-}
  sameQueue addr q = sameQAddress addr (qAddress q)
  {-# INLINE sameQueue #-}

findQ :: SMPQueue q => (SMPServer, SMP.QueueId) -> NonEmpty q -> Maybe q
findQ = find . sameQueue

removeQ :: SMPQueue q => (SMPServer, SMP.QueueId) -> NonEmpty q -> Maybe (q, [q])
removeQ addr qs = case L.break (sameQueue addr) qs of
  (_, []) -> Nothing
  (qs1, q : qs2) -> Just (q, qs1 <> qs2)

-- * Connection types

-- | Type of a connection.
data ConnType = CNew | CRcv | CSnd | CDuplex | CContact deriving (Eq, Show)

-- | Connection of a specific type.
--
-- - RcvConnection is a connection that only has a receive queue set up,
--   typically created by a recipient initiating a duplex connection.
--
-- - SndConnection is a connection that only has a send queue set up, typically
--   created by a sender joining a duplex connection through a recipient's invitation.
--
-- - DuplexConnection is a connection that has both receive and send queues set up,
--   typically created by upgrading a receive or a send connection with a missing queue.
data Connection (d :: ConnType) where
  NewConnection :: ConnData -> Connection CNew
  RcvConnection :: ConnData -> RcvQueue -> Connection CRcv
  SndConnection :: ConnData -> SndQueue -> Connection CSnd
  DuplexConnection :: ConnData -> NonEmpty RcvQueue -> NonEmpty SndQueue -> Connection CDuplex
  ContactConnection :: ConnData -> RcvQueue -> Connection CContact

deriving instance Eq (Connection d)

deriving instance Show (Connection d)

data SConnType :: ConnType -> Type where
  SCNew :: SConnType CNew
  SCRcv :: SConnType CRcv
  SCSnd :: SConnType CSnd
  SCDuplex :: SConnType CDuplex
  SCContact :: SConnType CContact

connType :: SConnType c -> ConnType
connType SCNew = CNew
connType SCRcv = CRcv
connType SCSnd = CSnd
connType SCDuplex = CDuplex
connType SCContact = CContact

deriving instance Eq (SConnType d)

deriving instance Show (SConnType d)

instance TestEquality SConnType where
  testEquality SCRcv SCRcv = Just Refl
  testEquality SCSnd SCSnd = Just Refl
  testEquality SCDuplex SCDuplex = Just Refl
  testEquality SCContact SCContact = Just Refl
  testEquality _ _ = Nothing

-- | Connection of an unknown type.
-- Used to refer to an arbitrary connection when retrieving from store.
data SomeConn = forall d. SomeConn (SConnType d) (Connection d)

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Show SomeConn

data ConnData = ConnData
  { connId :: ConnId,
    connAgentVersion :: Version,
    enableNtfs :: Bool,
    duplexHandshake :: Maybe Bool -- added in agent protocol v2
  }
  deriving (Eq, Show)

data AgentCmdType = ACClient | ACInternal

instance StrEncoding AgentCmdType where
  strEncode = \case
    ACClient -> "CLIENT"
    ACInternal -> "INTERNAL"
  strP =
    A.takeTill (== ' ') >>= \case
      "CLIENT" -> pure ACClient
      "INTERNAL" -> pure ACInternal
      _ -> fail "bad AgentCmdType"

data AgentCommand
  = AClientCommand (ACommand 'Client)
  | AInternalCommand InternalCommand

instance StrEncoding AgentCommand where
  strEncode = \case
    AClientCommand cmd -> strEncode (ACClient, Str $ serializeCommand cmd)
    AInternalCommand cmd -> strEncode (ACInternal, cmd)
  strP =
    strP_ >>= \case
      ACClient -> AClientCommand <$> ((\(ACmd _ cmd) -> checkParty cmd) <$?> dbCommandP)
      ACInternal -> AInternalCommand <$> strP

data AgentCommandTag
  = AClientCommandTag (ACommandTag 'Client)
  | AInternalCommandTag InternalCommandTag
  deriving (Show)

instance StrEncoding AgentCommandTag where
  strEncode = \case
    AClientCommandTag t -> strEncode (ACClient, t)
    AInternalCommandTag t -> strEncode (ACInternal, t)
  strP =
    strP_ >>= \case
      ACClient -> AClientCommandTag <$> strP
      ACInternal -> AInternalCommandTag <$> strP

data InternalCommand
  = ICAck SMP.RecipientId MsgId
  | ICAckDel SMP.RecipientId MsgId InternalId
  | ICAllowSecure SMP.RecipientId SMP.SndPublicVerifyKey
  | ICDuplexSecure SMP.RecipientId SMP.SndPublicVerifyKey
  | ICQSecure SMP.RecipientId SMP.SndPublicVerifyKey
  | ICQDelete SMP.RecipientId

data InternalCommandTag
  = ICAck_
  | ICAckDel_
  | ICAllowSecure_
  | ICDuplexSecure_
  | ICQSecure_
  | ICQDelete_
  deriving (Show)

instance StrEncoding InternalCommand where
  strEncode = \case
    ICAck rId srvMsgId -> strEncode (ICAck_, rId, srvMsgId)
    ICAckDel rId srvMsgId mId -> strEncode (ICAckDel_, rId, srvMsgId, mId)
    ICAllowSecure rId sndKey -> strEncode (ICAllowSecure_, rId, sndKey)
    ICDuplexSecure rId sndKey -> strEncode (ICDuplexSecure_, rId, sndKey)
    ICQSecure rId senderKey -> strEncode (ICQSecure_, rId, senderKey)
    ICQDelete rId -> strEncode (ICQDelete_, rId)
  strP =
    strP >>= \case
      ICAck_ -> ICAck <$> _strP <*> _strP
      ICAckDel_ -> ICAckDel <$> _strP <*> _strP <*> _strP
      ICAllowSecure_ -> ICAllowSecure <$> _strP <*> _strP
      ICDuplexSecure_ -> ICDuplexSecure <$> _strP <*> _strP
      ICQSecure_ -> ICQSecure <$> _strP <*> _strP
      ICQDelete_ -> ICQDelete <$> _strP

instance StrEncoding InternalCommandTag where
  strEncode = \case
    ICAck_ -> "ACK"
    ICAckDel_ -> "ACK_DEL"
    ICAllowSecure_ -> "ALLOW_SECURE"
    ICDuplexSecure_ -> "DUPLEX_SECURE"
    ICQSecure_ -> "QSECURE"
    ICQDelete_ -> "QDELETE"
  strP =
    A.takeTill (== ' ') >>= \case
      "ACK" -> pure ICAck_
      "ACK_DEL" -> pure ICAckDel_
      "ALLOW_SECURE" -> pure ICAllowSecure_
      "DUPLEX_SECURE" -> pure ICDuplexSecure_
      "QSECURE" -> pure ICQSecure_
      "QDELETE" -> pure ICQDelete_
      _ -> fail "bad InternalCommandTag"

agentCommandTag :: AgentCommand -> AgentCommandTag
agentCommandTag = \case
  AClientCommand cmd -> AClientCommandTag $ aCommandTag cmd
  AInternalCommand cmd -> AInternalCommandTag $ internalCmdTag cmd

internalCmdTag :: InternalCommand -> InternalCommandTag
internalCmdTag = \case
  ICAck {} -> ICAck_
  ICAckDel {} -> ICAckDel_
  ICAllowSecure {} -> ICAllowSecure_
  ICDuplexSecure {} -> ICDuplexSecure_
  ICQSecure {} -> ICQSecure_
  ICQDelete _ -> ICQDelete_

-- * Confirmation types

data NewConfirmation = NewConfirmation
  { connId :: ConnId,
    senderConf :: SMPConfirmation,
    ratchetState :: RatchetX448
  }

data AcceptedConfirmation = AcceptedConfirmation
  { confirmationId :: ConfirmationId,
    connId :: ConnId,
    senderConf :: SMPConfirmation,
    ratchetState :: RatchetX448,
    ownConnInfo :: ConnInfo
  }

-- * Invitations

data NewInvitation = NewInvitation
  { contactConnId :: ConnId,
    connReq :: ConnectionRequestUri 'CMInvitation,
    recipientConnInfo :: ConnInfo
  }

data Invitation = Invitation
  { invitationId :: InvitationId,
    contactConnId :: ConnId,
    connReq :: ConnectionRequestUri 'CMInvitation,
    recipientConnInfo :: ConnInfo,
    ownConnInfo :: Maybe ConnInfo,
    accepted :: Bool
  }

-- * Message integrity validation types

-- | Corresponds to `last_external_snd_msg_id` in `connections` table
type PrevExternalSndId = Int64

-- | Corresponds to `last_rcv_msg_hash` in `connections` table
type PrevRcvMsgHash = MsgHash

-- | Corresponds to `last_snd_msg_hash` in `connections` table
type PrevSndMsgHash = MsgHash

-- * Message data containers

data RcvMsgData = RcvMsgData
  { msgMeta :: MsgMeta,
    msgType :: AgentMessageType,
    msgFlags :: MsgFlags,
    msgBody :: MsgBody,
    internalRcvId :: InternalRcvId,
    internalHash :: MsgHash,
    externalPrevSndHash :: MsgHash
  }

data RcvMsg = RcvMsg
  { internalId :: InternalId,
    msgMeta :: MsgMeta,
    msgBody :: MsgBody,
    userAck :: Bool
  }

data SndMsgData = SndMsgData
  { internalId :: InternalId,
    internalSndId :: InternalSndId,
    internalTs :: InternalTs,
    msgType :: AgentMessageType,
    msgFlags :: MsgFlags,
    msgBody :: MsgBody,
    internalHash :: MsgHash,
    prevMsgHash :: MsgHash
  }

data PendingMsgData = PendingMsgData
  { msgId :: InternalId,
    msgType :: AgentMessageType,
    msgFlags :: MsgFlags,
    msgBody :: MsgBody,
    internalTs :: InternalTs
  }
  deriving (Show)

-- internal Ids are newtypes to prevent mixing them up
newtype InternalRcvId = InternalRcvId {unRcvId :: Int64} deriving (Eq, Show)

type ExternalSndId = Int64

type ExternalSndTs = UTCTime

type BrokerId = MsgId

type BrokerTs = UTCTime

newtype InternalSndId = InternalSndId {unSndId :: Int64} deriving (Eq, Show)

-- | Base message data independent of direction.
data MsgBase = MsgBase
  { connId :: ConnId,
    -- | Monotonically increasing id of a message per connection, internal to the agent.
    -- Internal Id preserves ordering between both received and sent messages, and is needed
    -- to track the order of the conversation (which can be different for the sender / receiver)
    -- and address messages in commands. External [sender] Id cannot be used for this purpose
    -- due to a possibility of implementation errors in different agents.
    internalId :: InternalId,
    internalTs :: InternalTs,
    msgBody :: MsgBody,
    -- | Hash of the message as computed by agent.
    internalHash :: MsgHash
  }
  deriving (Eq, Show)

newtype InternalId = InternalId {unId :: Int64} deriving (Eq, Show)

instance StrEncoding InternalId where
  strEncode = strEncode . unId
  strP = InternalId <$> strP

type InternalTs = UTCTime

type AsyncCmdId = Int64

-- * Store errors

-- | Agent store error.
data StoreError
  = -- | IO exceptions in store actions.
    SEInternal ByteString
  | -- | Failed to generate unique random ID
    SEUniqueID
  | -- | Connection not found (or both queues absent).
    SEConnNotFound
  | -- | Connection already used.
    SEConnDuplicate
  | -- | Wrong connection type, e.g. "send" connection when "receive" or "duplex" is expected, or vice versa.
    -- 'upgradeRcvConnToDuplex' and 'upgradeSndConnToDuplex' do not allow duplex connections - they would also return this error.
    SEBadConnType ConnType
  | -- | Confirmation not found.
    SEConfirmationNotFound
  | -- | Invitation not found
    SEInvitationNotFound
  | -- | Message not found
    SEMsgNotFound
  | -- | Command not found
    SECmdNotFound
  | -- | Currently not used. The intention was to pass current expected queue status in methods,
    -- as we always know what it should be at any stage of the protocol,
    -- and in case it does not match use this error.
    SEBadQueueStatus
  | -- | connection does not have associated double-ratchet state
    SERatchetNotFound
  | -- | connection does not have associated x3dh keys
    SEX3dhKeysNotFound
  | -- | Used in `getMsg` that is not implemented/used. TODO remove.
    SENotImplemented
  | -- | Used to wrap agent errors inside store operations to avoid race conditions
    SEAgentError AgentErrorType
  deriving (Eq, Show, Exception)
