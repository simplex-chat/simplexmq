{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store where

import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Crypto.Random (ChaChaDRG)
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Protocol
  ( MsgBody,
    MsgId,
    RecipientPrivateKey,
    SenderPrivateKey,
    SenderPublicKey,
  )
import qualified Simplex.Messaging.Protocol as SMP

-- * Store management

-- | Store class type. Defines store access methods for implementations.
class Monad m => MonadAgentStore s m where
  -- Queue and Connection management
  createRcvConn :: s -> TVar ChaChaDRG -> ConnData -> RcvQueue -> m ConnId
  createSndConn :: s -> TVar ChaChaDRG -> ConnData -> SndQueue -> m ConnId
  getConn :: s -> ConnId -> m SomeConn
  getAllConns :: s -> m [SomeConn]
  getAllConnIds :: s -> m [ConnId] -- TODO remove - hack for subscribing to all
  getRcvConn :: s -> SMPServer -> SMP.RecipientId -> m SomeConn
  deleteConn :: s -> ConnId -> m ()
  upgradeRcvConnToDuplex :: s -> ConnId -> SndQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnId -> RcvQueue -> m ()
  setRcvQueueStatus :: s -> RcvQueue -> QueueStatus -> m ()
  setRcvQueueActive :: s -> RcvQueue -> VerificationKey -> m ()
  setSndQueueStatus :: s -> SndQueue -> QueueStatus -> m ()

  -- Confirmations
  createConfirmation :: s -> TVar ChaChaDRG -> NewConfirmation -> m ConfirmationId
  getConfirmation :: s -> ConfirmationId -> m Confirmation
  approveConfirmation :: s -> ConfirmationId -> ConnInfo -> m ()
  getApprovedConfirmation :: s -> ConnId -> m Confirmation
  removeApprovedConfirmation :: s -> ConnId -> m ()

  -- Msg management
  updateRcvIds :: s -> ConnId -> m (InternalId, InternalRcvId, PrevExternalSndId, PrevRcvMsgHash)
  createRcvMsg :: s -> ConnId -> RcvMsgData -> m ()
  updateSndIds :: s -> ConnId -> m (InternalId, InternalSndId, PrevSndMsgHash)
  createSndMsg :: s -> ConnId -> SndMsgData -> m ()
  getMsg :: s -> ConnId -> InternalId -> m Msg

  -- Introductions
  createIntro :: s -> TVar ChaChaDRG -> NewIntroduction -> m IntroId
  getIntro :: s -> IntroId -> m Introduction
  addIntroInvitation :: s -> IntroId -> ConnInfo -> SMPQueueInfo -> m ()
  setIntroToStatus :: s -> IntroId -> IntroStatus -> m ()
  setIntroReStatus :: s -> IntroId -> IntroStatus -> m ()
  createInvitation :: s -> TVar ChaChaDRG -> NewInvitation -> m InvitationId
  getInvitation :: s -> InvitationId -> m Invitation
  addInvitationConn :: s -> InvitationId -> ConnId -> m ()
  getConnInvitation :: s -> ConnId -> m (Maybe (Invitation, Connection CDuplex))
  setInvitationStatus :: s -> InvitationId -> InvitationStatus -> m ()

-- * Queue types

-- | A receive queue. SMP queue through which the agent receives messages from a sender.
data RcvQueue = RcvQueue
  { server :: SMPServer,
    rcvId :: SMP.RecipientId,
    rcvPrivateKey :: RecipientPrivateKey,
    sndId :: Maybe SMP.SenderId,
    sndKey :: Maybe SenderPublicKey,
    decryptKey :: DecryptionKey,
    verifyKey :: Maybe VerificationKey,
    status :: QueueStatus
  }
  deriving (Eq, Show)

-- | A send queue. SMP queue through which the agent sends messages to a recipient.
data SndQueue = SndQueue
  { server :: SMPServer,
    sndId :: SMP.SenderId,
    sndPrivateKey :: SenderPrivateKey,
    encryptKey :: EncryptionKey,
    signKey :: SignatureKey,
    status :: QueueStatus
  }
  deriving (Eq, Show)

-- * Connection types

-- | Type of a connection.
data ConnType = CRcv | CSnd | CDuplex deriving (Eq, Show)

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
  RcvConnection :: ConnData -> RcvQueue -> Connection CRcv
  SndConnection :: ConnData -> SndQueue -> Connection CSnd
  DuplexConnection :: ConnData -> RcvQueue -> SndQueue -> Connection CDuplex

deriving instance Eq (Connection d)

deriving instance Show (Connection d)

data SConnType :: ConnType -> Type where
  SCRcv :: SConnType CRcv
  SCSnd :: SConnType CSnd
  SCDuplex :: SConnType CDuplex

connType :: SConnType c -> ConnType
connType SCRcv = CRcv
connType SCSnd = CSnd
connType SCDuplex = CDuplex

deriving instance Eq (SConnType d)

deriving instance Show (SConnType d)

instance TestEquality SConnType where
  testEquality SCRcv SCRcv = Just Refl
  testEquality SCSnd SCSnd = Just Refl
  testEquality SCDuplex SCDuplex = Just Refl
  testEquality _ _ = Nothing

-- | Connection of an unknown type.
-- Used to refer to an arbitrary connection when retrieving from store.
data SomeConn = forall d. SomeConn (SConnType d) (Connection d)

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Show SomeConn

data ConnData = ConnData {connId :: ConnId, viaInv :: Maybe InvitationId, connLevel :: Int}
  deriving (Eq, Show)

-- * Confirmation types

data NewConfirmation = NewConfirmation
  { connId :: ConnId,
    senderKey :: SenderPublicKey,
    senderConnInfo :: ConnInfo
  }

data Confirmation = Confirmation
  { confirmationId :: ConfirmationId,
    connId :: ConnId,
    senderKey :: SenderPublicKey,
    senderConnInfo :: ConnInfo,
    ownConnInfo :: Maybe ConnInfo
  }

-- * Message integrity validation types

type MsgHash = ByteString

-- | Corresponds to `last_external_snd_msg_id` in `connections` table
type PrevExternalSndId = Int64

-- | Corresponds to `last_rcv_msg_hash` in `connections` table
type PrevRcvMsgHash = MsgHash

-- | Corresponds to `last_snd_msg_hash` in `connections` table
type PrevSndMsgHash = MsgHash

-- ? merge/replace these with RcvMsg and SndMsg

-- * Message data containers - used on Msg creation to reduce number of parameters

data RcvMsgData = RcvMsgData
  { internalId :: InternalId,
    internalRcvId :: InternalRcvId,
    internalTs :: InternalTs,
    senderMeta :: (ExternalSndId, ExternalSndTs),
    brokerMeta :: (BrokerId, BrokerTs),
    msgBody :: MsgBody,
    internalHash :: MsgHash,
    externalPrevSndHash :: MsgHash,
    msgIntegrity :: MsgIntegrity
  }

data SndMsgData = SndMsgData
  { internalId :: InternalId,
    internalSndId :: InternalSndId,
    internalTs :: InternalTs,
    msgBody :: MsgBody,
    internalHash :: MsgHash
  }

-- * Broadcast types

type BroadcastId = ByteString

-- * Message types

-- | A message in either direction that is stored by the agent.
data Msg = MRcv RcvMsg | MSnd SndMsg
  deriving (Eq, Show)

-- | A message received by the agent from a sender.
data RcvMsg = RcvMsg
  { msgBase :: MsgBase,
    internalRcvId :: InternalRcvId,
    -- | Id of the message at sender, corresponds to `internalSndId` from the sender's side.
    -- Sender Id is made sequential for detection of missing messages. For redundant / parallel queues,
    -- it also allows to keep track of duplicates and restore the original order before delivery to the client.
    externalSndId :: ExternalSndId,
    externalSndTs :: ExternalSndTs,
    -- | Id of the message at broker, although it is not sequential (to avoid metadata leakage for potential observer),
    -- it is needed to track repeated deliveries in case of connection loss - this logic is not implemented yet.
    brokerId :: BrokerId,
    brokerTs :: BrokerTs,
    rcvMsgStatus :: RcvMsgStatus,
    -- | Timestamp of acknowledgement to broker, corresponds to `AcknowledgedToBroker` status.
    -- Do not mix up with `brokerTs` - timestamp created at broker after it receives the message from sender.
    ackBrokerTs :: AckBrokerTs,
    -- | Timestamp of acknowledgement to sender, corresponds to `AcknowledgedToSender` status.
    -- Do not mix up with `externalSndTs` - timestamp created at sender before sending,
    -- which in its turn corresponds to `internalTs` in sending agent.
    ackSenderTs :: AckSenderTs,
    -- | Hash of previous message as received from sender - stored for integrity forensics.
    externalPrevSndHash :: MsgHash,
    msgIntegrity :: MsgIntegrity
  }
  deriving (Eq, Show)

-- internal Ids are newtypes to prevent mixing them up
newtype InternalRcvId = InternalRcvId {unRcvId :: Int64} deriving (Eq, Show)

type ExternalSndId = Int64

type ExternalSndTs = UTCTime

type BrokerId = MsgId

type BrokerTs = UTCTime

data RcvMsgStatus
  = Received
  | AcknowledgedToBroker
  | AcknowledgedToSender
  deriving (Eq, Show)

type AckBrokerTs = UTCTime

type AckSenderTs = UTCTime

-- | A message sent by the agent to a recipient.
data SndMsg = SndMsg
  { msgBase :: MsgBase,
    -- | Id of the message sent / to be sent, as in its number in order of sending.
    internalSndId :: InternalSndId,
    sndMsgStatus :: SndMsgStatus,
    -- | Timestamp of the message received by broker, corresponds to `Sent` status.
    sentTs :: SentTs,
    -- | Timestamp of the message received by recipient, corresponds to `Delivered` status.
    deliveredTs :: DeliveredTs
  }
  deriving (Eq, Show)

newtype InternalSndId = InternalSndId {unSndId :: Int64} deriving (Eq, Show)

data SndMsgStatus
  = Created
  | Sent
  | Delivered
  deriving (Eq, Show)

type SentTs = UTCTime

type DeliveredTs = UTCTime

-- | Base message data independent of direction.
data MsgBase = MsgBase
  { connAlias :: ConnId,
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

type InternalTs = UTCTime

-- * Introduction types

data NewIntroduction = NewIntroduction
  { toConn :: ConnId,
    reConn :: ConnId,
    reInfo :: ByteString
  }

data Introduction = Introduction
  { introId :: IntroId,
    toConn :: ConnId,
    toInfo :: Maybe ByteString,
    toStatus :: IntroStatus,
    reConn :: ConnId,
    reInfo :: ByteString,
    reStatus :: IntroStatus,
    qInfo :: Maybe SMPQueueInfo
  }

data IntroStatus = IntroNew | IntroInv | IntroCon
  deriving (Eq)

serializeIntroStatus :: IntroStatus -> Text
serializeIntroStatus = \case
  IntroNew -> ""
  IntroInv -> "INV"
  IntroCon -> "CON"

introStatusT :: Text -> Maybe IntroStatus
introStatusT = \case
  "" -> Just IntroNew
  "INV" -> Just IntroInv
  "CON" -> Just IntroCon
  _ -> Nothing

data NewInvitation = NewInvitation
  { viaConn :: ConnId,
    externalIntroId :: IntroId,
    connInfo :: ConnInfo,
    qInfo :: Maybe SMPQueueInfo
  }

data Invitation = Invitation
  { invId :: InvitationId,
    viaConn :: ConnId,
    externalIntroId :: IntroId,
    connInfo :: ConnInfo,
    qInfo :: Maybe SMPQueueInfo,
    connId :: Maybe ConnId,
    status :: InvitationStatus
  }
  deriving (Show)

data InvitationStatus = InvNew | InvAcpt | InvCon
  deriving (Eq, Show)

serializeInvStatus :: InvitationStatus -> Text
serializeInvStatus = \case
  InvNew -> ""
  InvAcpt -> "ACPT"
  InvCon -> "CON"

invStatusT :: Text -> Maybe InvitationStatus
invStatusT = \case
  "" -> Just InvNew
  "ACPT" -> Just InvAcpt
  "CON" -> Just InvCon
  _ -> Nothing

-- * Store errors

-- | Agent store error.
data StoreError
  = -- | IO exceptions in store actions.
    SEInternal ByteString
  | -- | failed to generate unique random ID
    SEUniqueID
  | -- | Connection alias not found (or both queues absent).
    SEConnNotFound
  | -- | Connection alias already used.
    SEConnDuplicate
  | -- | Wrong connection type, e.g. "send" connection when "receive" or "duplex" is expected, or vice versa.
    -- 'upgradeRcvConnToDuplex' and 'upgradeSndConnToDuplex' do not allow duplex connections - they would also return this error.
    SEBadConnType ConnType
  | -- | Confirmation not found.
    SEConfirmationNotFound
  | -- | Introduction ID not found.
    SEIntroNotFound
  | -- | Invitation ID not found.
    SEInvitationNotFound
  | -- | Currently not used. The intention was to pass current expected queue status in methods,
    -- as we always know what it should be at any stage of the protocol,
    -- and in case it does not match use this error.
    SEBadQueueStatus
  | -- | Used in `getMsg` that is not implemented/used. TODO remove.
    SENotImplemented
  deriving (Eq, Show, Exception)
