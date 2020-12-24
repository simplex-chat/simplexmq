{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Command where

import Data.ByteString.Char8 (ByteString)
import Data.Kind
import Data.Time.Clock
import Network.Socket
import Simplex.Messaging.Server.Transmission (Encoded, MsgBody, PublicKey, QueueId)

data AParty = Agent | User
  deriving (Show)

data SAParty :: AParty -> Type where
  SAgent :: SAParty Agent
  SUser :: SAParty User

deriving instance Show (SAParty a)

data ACommand (a :: AParty) where
  NEW :: SMPServer -> Maybe ConnectionName -> AckMode -> ACommand User
  INV :: ConnAlias -> SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> Maybe SMPServer -> Maybe ConnectionName -> AckMode -> ACommand User
  CON :: ConnAlias -> ACommand Agent
  CONF :: ConnAlias -> OtherPartyId -> ACommand Agent
  LET :: ConnAlias -> OtherPartyId -> ACommand User
  SUB :: ConnAlias -> SubMode -> ACommand User
  END :: ConnAlias -> ACommand Agent
  QST :: ConnAlias -> QueueDirection -> ACommand User
  STAT :: ConnAlias -> QueueDirection -> Maybe ConnState -> Maybe SubMode -> ACommand Agent
  SEND :: ConnAlias -> MsgBody -> ACommand User
  MSG :: ConnAlias -> AgentMsgId -> UTCTime -> UTCTime -> MsgStatus -> MsgBody -> ACommand Agent
  ACK :: ConnAlias -> AgentMsgId -> ACommand User
  RCVD :: ConnAlias -> AgentMsgId -> ACommand Agent
  OFF :: ConnAlias -> ACommand User
  DEL :: ConnAlias -> ACommand User
  OK :: ConnAlias -> ACommand Agent
  ERR :: ConnAlias -> ErrorType -> ACommand Agent

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_DEL :: AMessage
  A_MSG :: AgentMsgId -> UTCTime -> MsgBody -> AMessage
  A_ACK :: AgentMsgId -> AckStatus -> AMessage

data SMPServer = SMPServer HostName ServiceName KeyFingerprint

type KeyFingerprint = Encoded

type ConnAlias = ByteString

type ConnectionName = ByteString

type OtherPartyId = Encoded

data Mode = On | Off

newtype AckMode = AckMode Mode

newtype SubMode = SubMode Mode

data SMPQueueInfo = SMPQueueInfo SMPServer QueueId EncryptionKey

type EncryptionKey = PublicKey

type VerificationKey = PublicKey

data QueueDirection = SND | RCV

data ConnState = New | Pending | Confirmed | Secured | Active | Disabled

type AgentMsgId = Int

data MsgStatus = MsgOk | MsgError MsgErrorType

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash

data ErrorType = UNKNOWN | PROHIBITED -- etc.

data AckStatus = AckOk | AckError AckErrorType

data AckErrorType = AckUnknown | AckProhibited | AckSyntax Int -- etc.
