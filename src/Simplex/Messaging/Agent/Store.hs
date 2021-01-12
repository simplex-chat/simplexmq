{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store where

import Data.Int (Int64)
import Data.Kind
import Data.Time.Clock (UTCTime)
import Data.Type.Equality
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server.Transmission (Encoded, PublicKey, QueueId)

data ReceiveQueue = ReceiveQueue
  { server :: SMPServer,
    rcvId :: QueueId,
    rcvPrivateKey :: PrivateKey,
    sndId :: Maybe QueueId,
    sndKey :: Maybe PublicKey,
    decryptKey :: PrivateKey,
    verifyKey :: Maybe PublicKey,
    status :: QueueStatus,
    ackMode :: AckMode -- whether acknowledgement will be sent (via SendQueue if present)
  }
  deriving (Eq, Show)

data SendQueue = SendQueue
  { server :: SMPServer,
    sndId :: QueueId,
    sndPrivateKey :: PrivateKey,
    encryptKey :: PublicKey,
    signKey :: PrivateKey,
    -- verifyKey :: Maybe PublicKey,
    status :: QueueStatus,
    ackMode :: AckMode -- whether acknowledgement is expected (via ReceiveQueue if present)
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

type PrivateKey = Encoded

data DeliveryStatus
  = MDTransmitted -- SMP: SEND sent / MSG received
  | MDConfirmed -- SMP: OK received / ACK sent
  | MDAcknowledged AckStatus -- SAMP: RCVD sent to agent client / ACK received from agent client and sent to the server

type SMPServerId = Int64

class Monad m => MonadAgentStore s m where
  addServer :: s -> SMPServer -> m SMPServerId
  createRcvConn :: s -> ConnAlias -> ReceiveQueue -> m ()
  createSndConn :: s -> ConnAlias -> SendQueue -> m ()
  getConn :: s -> ConnAlias -> m SomeConn
  deleteConn :: s -> ConnAlias -> m ()
  addSndQueue :: s -> ConnAlias -> SendQueue -> m ()
  addRcvQueue :: s -> ConnAlias -> ReceiveQueue -> m ()
  removeSndAuth :: s -> ConnAlias -> m ()
  updateQueueStatus :: s -> ConnAlias -> QueueDirection -> QueueStatus -> m ()
  createMsg :: s -> ConnAlias -> QueueDirection -> AMessage -> m MessageDelivery
  getLastMsg :: s -> ConnAlias -> QueueDirection -> m MessageDelivery
  getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
  updateMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
  deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
