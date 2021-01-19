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
import Simplex.Messaging.Server.Transmission (PrivateKey, PublicKey, RecipientId, SenderId)

data ReceiveQueue = ReceiveQueue
  { server :: SMPServer,
    rcvId :: RecipientId,
    rcvPrivateKey :: PrivateKey,
    sndId :: Maybe SenderId,
    sndKey :: Maybe PublicKey,
    decryptKey :: PrivateKey,
    verifyKey :: Maybe PublicKey,
    status :: QueueStatus,
    ackMode :: AckMode -- whether acknowledgement will be sent (via SendQueue if present)
  }
  deriving (Eq, Show)

data SendQueue = SendQueue
  { server :: SMPServer,
    sndId :: SenderId,
    sndPrivateKey :: PrivateKey,
    encryptKey :: PublicKey,
    signKey :: PrivateKey,
    -- verifyKey :: Maybe PublicKey,
    status :: QueueStatus,
    ackMode :: AckMode -- whether acknowledgement is expected (via ReceiveQueue if present)
  }
  deriving (Eq, Show)

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

type SMPServerId = Int64

-- TODO rework types - decouple Transmission types from Store? Convert on the agent instead?
class Monad m => MonadAgentStore s m where
  addServer :: s -> SMPServer -> m SMPServerId
  getRcvQueue :: s -> ConnAlias -> m ReceiveQueue
  getSndQueue :: s -> ConnAlias -> m SendQueue
  createRcvConn :: s -> ConnAlias -> ReceiveQueue -> m ()
  createSndConn :: s -> ConnAlias -> SendQueue -> m ()
  getReceiveQueue :: s -> SMPServer -> RecipientId -> m (ConnAlias, ReceiveQueue)
  deleteConn :: s -> ConnAlias -> m ()
  addSndQueue :: s -> ConnAlias -> SendQueue -> m ()
  addRcvQueue :: s -> ConnAlias -> ReceiveQueue -> m ()
  removeSndAuth :: s -> ConnAlias -> m ()
  updateRcvQueueStatus :: s -> ReceiveQueue -> QueueStatus -> m ()
  updateSndQueueStatus :: s -> SendQueue -> QueueStatus -> m ()
  createMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> AMessage -> m ()
  getLastMsg :: s -> ConnAlias -> QueueDirection -> m MessageDelivery
  getMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m MessageDelivery
  updateMsgStatus :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
  deleteMsg :: s -> ConnAlias -> QueueDirection -> AgentMsgId -> m ()
