module Simplex.Messaging.Agent.Types.TransmissionTypes where

import Data.ByteString.Char8 (ByteString)
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Types (Encoded)

data SMPServer = SMPServer
  { host :: HostName,
    port :: Maybe ServiceName,
    keyHash :: Maybe KeyHash
  }
  deriving (Eq, Ord, Show)

type KeyHash = Encoded

type ConnAlias = ByteString

type OtherPartyId = Encoded

data Mode = On | Off deriving (Eq, Show, Read)

newtype AckMode = AckMode Mode deriving (Eq, Show)

data SMPQueueInfo = SMPQueueInfo SMPServer SMP.SenderId EncryptionKey
  deriving (Eq, Show)

data ReplyMode = ReplyOff | ReplyOn | ReplyVia SMPServer deriving (Eq, Show)

type EncryptionKey = C.PublicKey

type DecryptionKey = C.PrivateKey

type SignatureKey = C.PrivateKey

type VerificationKey = C.PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueStatus = New | Confirmed | Secured | Active | Disabled
  deriving (Eq, Show, Read)

type AgentMsgId = Integer

data MsgStatus = MsgOk | MsgError MsgErrorType
  deriving (Eq, Show)

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash
  deriving (Eq, Show)

data AckStatus = AckOk | AckError AckErrorType
  deriving (Show)

data AckErrorType = AckUnknown | AckProhibited | AckSyntax Int -- etc.
  deriving (Show)
