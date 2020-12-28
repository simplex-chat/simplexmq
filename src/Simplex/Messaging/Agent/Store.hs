{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Store where

import Data.Kind
import Data.Time.Clock (UTCTime)
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

data SendQueue = SendQueue
  { server :: SMPServer,
    sndId :: QueueId,
    sndPrivateKey :: PrivateKey,
    encryptKey :: PublicKey,
    signKey :: PrivateKey,
    status :: QueueStatus,
    ackMode :: AckMode -- whether acknowledgement is expected (via ReceiveQueue if present)
  }

data ConnType = CSend | CReceive | CDuplex

data Connection (d :: ConnType) where
  ReceiveConnection :: ConnAlias -> ReceiveQueue -> Connection CReceive
  SendConnection :: ConnAlias -> SendQueue -> Connection CSend
  DuplexConnection :: ConnAlias -> ReceiveQueue -> SendQueue -> Connection CDuplex

data SConnType :: ConnType -> Type where
  SCReceive :: SConnType CReceive
  SCSend :: SConnType CSend
  SCDuplex :: SConnType CDuplex

deriving instance Show (SConnType d)

data SomeConn where
  SomeConn :: SConnType d -> Connection d -> SomeConn

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

class MonadAgentStore s m where
  createRcvConn :: s -> Maybe ConnAlias -> ReceiveQueue -> m (Either StoreError (Connection CReceive))
  createSndConn :: s -> Maybe ConnAlias -> SendQueue -> m (Either StoreError (Connection CSend))
  getConn :: s -> ConnAlias -> m (Either StoreError SomeConn)
  deleteConn :: s -> ConnAlias -> m (Either StoreError ())
  addSndQueue :: s -> ConnAlias -> SendQueue -> m (Either StoreError (Connection CDuplex))
  addRcvQueue :: s -> ConnAlias -> SendQueue -> m (Either StoreError (Connection CDuplex))
  removeSndAuth :: s -> ConnAlias -> m (Either StoreError ())
  updateQueueStatus :: s -> ConnAlias -> QueueDirection -> QueueStatus -> m (Either StoreError ())
  createMsg :: s -> ConnAlias -> QueueDirection -> AMessage -> m (Either StoreError MessageDelivery)
  getLastMsg :: s -> ConnAlias -> QueueDirection -> m (Either StoreError MessageDelivery)
  getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m (Either StoreError MessageDelivery)
  updateMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m (Either StoreError ())
  deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m (Either StoreError ())

data StoreError
  = SEInternal
  | SEConnNotFound
  | SEMsgNotFound
  | SEBadConnType ConnType
  | SEBadQueueStatus
