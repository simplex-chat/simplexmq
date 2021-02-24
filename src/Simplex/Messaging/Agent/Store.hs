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
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Time (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Types
  ( MsgBody,
    MsgId,
    RecipientPrivateKey,
    SenderPrivateKey,
    SenderPublicKey,
  )

-- * Store management

-- | Store class type. Defines store access methods for implementations.
class Monad m => MonadAgentStore s m where
  -- Queue and Connection management
  createRcvConn :: s -> ReceiveQueue -> m ()
  createSndConn :: s -> SendQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  getRcvQueue :: s -> SMPServer -> SMP.RecipientId -> m ReceiveQueue
  deleteConn :: s -> ConnAlias -> m ()
  upgradeRcvConnToDuplex :: s -> ConnAlias -> SendQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnAlias -> ReceiveQueue -> m ()
  setRcvQueueStatus :: s -> ReceiveQueue -> QueueStatus -> m ()
  setSndQueueStatus :: s -> SendQueue -> QueueStatus -> m ()

  -- Msg management
  createRcvMsg :: s -> ConnAlias -> MsgBody -> ExternalSndId -> ExternalSndTs -> BrokerId -> BrokerTs -> m ()
  createSndMsg :: s -> ConnAlias -> MsgBody -> m ()
  getMsg :: s -> ConnAlias -> InternalId -> m Msg

-- * Queue types

-- | A receive queue. SMP queue through which the agent receives messages from a sender.
data ReceiveQueue = ReceiveQueue
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
data SendQueue = SendQueue
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
data ConnType = CReceive | CSend | CDuplex deriving (Eq, Show)

-- | Connection of a specific type.
--
-- - ReceiveConnection is a connection that only has a receive queue set up,
--   typically created by a recipient initiating a duplex connection.
--
-- - SendConnection is a connection that only has a send queue set up, typically
--   created by a sender joining a duplex connection through a recipient's invitation.
--
-- - DuplexConnection is a connection that has both receive and send queues set up,
--   typically created by upgrading a receive or a send connection with a missing queue.
data Connection (d :: ConnType) where
  ReceiveConnection :: ConnAlias -> ReceiveQueue -> Connection CReceive
  SendConnection :: ConnAlias -> SendQueue -> Connection CSend
  DuplexConnection :: ConnAlias -> ReceiveQueue -> SendQueue -> Connection CDuplex

deriving instance Eq (Connection d)

deriving instance Show (Connection d)

data SConnType :: ConnType -> Type where
  SCReceive :: SConnType CReceive
  SCSend :: SConnType CSend
  SCDuplex :: SConnType CDuplex

deriving instance Eq (SConnType d)

deriving instance Show (SConnType d)

instance TestEquality SConnType where
  testEquality SCReceive SCReceive = Just Refl
  testEquality SCSend SCSend = Just Refl
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
  { baseData :: MsgBase,
    internalRcvId :: InternalRcvId,
    -- | Id of the message at sender, corresponds to `internalSndId` from the sender's side.
    externalSndId :: ExternalSndId,
    externalSndTs :: ExternalSndTs,
    brokerId :: BrokerId,
    brokerTs :: BrokerTs,
    rcvStatus :: RcvStatus,
    -- | Timestamp of acknowledgement to broker, corresponds to `AcknowledgedToBroker` status.
    -- Do not mix up with `brokerTs` - timestamp created at broker after it receives the message from sender.
    ackBrokerTs :: AckBrokerTs,
    -- | Timestamp of acknowledgement to sender, corresponds to `AcknowledgedToSender` status.
    -- Do not mix up with `externalSndTs` - timestamp created at sender before sending,
    -- which in its turn corresponds to `internalTs`.
    ackSenderTs :: AckSenderTs
  }
  deriving (Eq, Show)

type InternalRcvId = Int64

type ExternalSndId = Integer

type ExternalSndTs = UTCTime

type BrokerId = MsgId

type BrokerTs = UTCTime

data RcvStatus
  = Received
  | AcknowledgedToBroker
  | AcknowledgedToSender
  deriving (Eq, Show)

type AckBrokerTs = UTCTime

type AckSenderTs = UTCTime

-- | A message sent by the agent to a recipient.
data SndMsg = SndMsg
  { baseData :: MsgBase,
    -- | Id of the message sent / to be sent, as in its number in order of sending.
    internalSndId :: InternalSndId,
    sndStatus :: SndStatus,
    -- | Timestamp of the message received by broker, corresponds to `Sent` status.
    sentTs :: SentTs,
    -- | Timestamp of the message received by recipient, corresponds to `Delivered` status.
    deliveredTs :: DeliveredTs
  }
  deriving (Eq, Show)

type InternalSndId = Int64

data SndStatus
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
    -- Preserves ordering between both received and sent messages.
    internalId :: InternalId,
    internalTs :: InternalTs,
    msgBody :: MsgBody
  }
  deriving (Eq, Show)

type InternalId = Int64

type InternalTs = UTCTime

-- * Store errors

data StoreError
  = SEInternal
  | SENotFound
  | SEBadConn
  | SEBadConnType ConnType
  | SEBadQueueStatus
  | SEBadQueueDirection
  | SENotImplemented -- TODO remove
  deriving (Eq, Show, Exception)
