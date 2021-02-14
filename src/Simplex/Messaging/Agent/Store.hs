{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store
  ( ReceiveQueue (..),
    SendQueue (..),
    Connection (..),
    SConnType (..),
    SomeConn (..),
    MessageDelivery (..),
    DeliveryStatus (..),
    MonadAgentStore (..),
  )
where

import Data.Kind (Type)
import Data.Time.Clock (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Store.Types (ConnType (..))
import Simplex.Messaging.Agent.Transmission
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Types (RecipientPrivateKey, SenderPrivateKey, SenderPublicKey)

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

data Connection (d :: ConnType) where
  ReceiveConnection :: ConnAlias -> ReceiveQueue -> Connection CReceive
  SendConnection :: ConnAlias -> SendQueue -> Connection CSend
  DuplexConnection :: ConnAlias -> ReceiveQueue -> SendQueue -> Connection CDuplex

deriving instance Show (Connection d)

deriving instance Eq (Connection d)

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

data SomeConn where
  SomeConn :: SConnType d -> Connection d -> SomeConn

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Show SomeConn

data MessageDelivery = MessageDelivery
  { connAlias :: ConnAlias,
    agentMsgId :: Int,
    timestamp :: UTCTime,
    message :: AMessage,
    direction :: QueueDirection,
    msgStatus :: DeliveryStatus
  }

data DeliveryStatus
  = MDTransmitted -- SMP: SEND sent / MSG received
  | MDConfirmed -- SMP: OK received / ACK sent
  | MDAcknowledged AckStatus -- SAMP: RCVD sent to agent client / ACK received from agent client and sent to the server

class Monad m => MonadAgentStore s m where
  createRcvConn :: s -> ReceiveQueue -> m ()
  createSndConn :: s -> SendQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  getRcvQueue :: s -> SMPServer -> SMP.RecipientId -> m ReceiveQueue
  deleteConn :: s -> ConnAlias -> m ()
  upgradeRcvConnToDuplex :: s -> ConnAlias -> SendQueue -> m ()
  upgradeSndConnToDuplex :: s -> ConnAlias -> ReceiveQueue -> m ()
  removeSndAuth :: s -> ConnAlias -> m ()
  setRcvQueueStatus :: s -> ReceiveQueue -> QueueStatus -> m ()
  setSndQueueStatus :: s -> SendQueue -> QueueStatus -> m ()
  createMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> m ()
  getLastMsg :: s -> ConnAlias -> QueueDirection -> m MessageDelivery
  getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
  updateMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
  deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
