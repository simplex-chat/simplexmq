{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store where

import Control.Exception (Exception)
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Time (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Transmission
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
  createRcvConn :: s -> RcvQueue -> m ()
  createSndConn :: s -> SndQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  getAllConnAliases :: s -> m [ConnAlias] -- TODO remove - hack for subscribing to all
  getRcvQueue :: s -> SMPServer -> SMP.RecipientId -> m RcvQueue
  deleteConn :: s -> ConnAlias -> m ()
  upgradeRcvConnToDuplex :: s -> ConnAlias -> SndQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnAlias -> RcvQueue -> m ()
  setRcvQueueStatus :: s -> RcvQueue -> QueueStatus -> m ()
  setRcvQueueActive :: s -> RcvQueue -> VerificationKey -> m ()
  setSndQueueStatus :: s -> SndQueue -> QueueStatus -> m ()

  -- Msg management
  createRcvMsg :: s -> ConnAlias -> MsgBody -> InternalTs -> (ExternalSndId, ExternalSndTs) -> (BrokerId, BrokerTs) -> m InternalId
  createSndMsg :: s -> ConnAlias -> MsgBody -> InternalTs -> m InternalId
  getMsg :: s -> ConnAlias -> InternalId -> m Msg

-- * Queue types

-- | A receive queue. SMP queue through which the agent receives messages from a sender.
data RcvQueue = RcvQueue
  { server :: SMPServer,
    rcvId :: SMP.RecipientId,
    connAlias :: ConnAlias,
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
    connAlias :: ConnAlias,
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
  RcvConnection :: ConnAlias -> RcvQueue -> Connection CRcv
  SndConnection :: ConnAlias -> SndQueue -> Connection CSnd
  DuplexConnection :: ConnAlias -> RcvQueue -> SndQueue -> Connection CDuplex

deriving instance Eq (Connection d)

deriving instance Show (Connection d)

data SConnType :: ConnType -> Type where
  SCRcv :: SConnType CRcv
  SCSnd :: SConnType CSnd
  SCDuplex :: SConnType CDuplex

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
    ackSenderTs :: AckSenderTs
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
  { connAlias :: ConnAlias,
    -- | Monotonically increasing id of a message per connection, internal to the agent.
    -- Internal Id preserves ordering between both received and sent messages, and is needed
    -- to track the order of the conversation (which can be different for the sender / receiver)
    -- and address messages in commands. External [sender] Id cannot be used for this purpose
    -- due to a possibility of implementation errors in different agents.
    internalId :: InternalId,
    internalTs :: InternalTs,
    msgBody :: MsgBody
  }
  deriving (Eq, Show)

newtype InternalId = InternalId {unId :: Int64} deriving (Eq, Show)

type InternalTs = UTCTime

-- * Store errors

data StoreError
  = SEInternal ByteString
  | SEConnNotFound
  | SEConnDuplicate
  | SEBadConnType ConnType
  | SEBadQueueStatus -- not used, planned to check strictly
  | SENotImplemented -- TODO remove
  deriving (Eq, Show, Exception)
