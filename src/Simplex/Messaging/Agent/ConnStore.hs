{-# LANGUAGE DuplicateRecordFields #-}

module Simplex.Messaging.Agent.ConnStore where

import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Agent.Command
import Simplex.Messaging.Server.Transmission (Encoded, PublicKey, QueueId)

data ReceiveQueue = ReceiveQueue
  { server :: SMPServer,
    rcvId :: QueueId,
    rcvPrivateKey :: PrivateKey,
    sndId :: Maybe QueueId,
    sndKey :: Maybe PublicKey,
    decryptKey :: PrivateKey,
    verifyKey :: Maybe PublicKey,
    status :: QueueState,
    ackMode :: AckMode
  }

data SendQueue = SendQueue
  { server :: SMPServer,
    sndId :: QueueId,
    sndPrivateKey :: PrivateKey,
    encryptKey :: PublicKey,
    signKey :: PrivateKey,
    status :: QueueState,
    ackMode :: AckMode
  }

data Connection
  = ReceiveConnection {connAlias :: ConnAlias, rcvQueue :: ReceiveQueue}
  | SendConnection {connAlias :: ConnAlias, sndQueue :: SendQueue}
  | DuplexConnection {connAlias :: ConnAlias, rcvQueue :: ReceiveQueue, sndQueue :: SendQueue}

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
  | MDAcknowledged -- SAMP: RCVD sent to agent client / ACK received from agent client and sent to the server
