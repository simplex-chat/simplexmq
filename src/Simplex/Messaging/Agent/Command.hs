{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Command where

import Control.Monad.IO.Class
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Time.Clock (UTCTime)
import Network.Socket
import Simplex.Messaging.Server.Transmission (Encoded, MsgBody, PublicKey, QueueId)
import Simplex.Messaging.Transport
import System.IO

data AParty = Agent | User
  deriving (Show)

data SAParty :: AParty -> Type where
  SAgent :: SAParty Agent
  SUser :: SAParty User

deriving instance Show (SAParty a)

data ACmd where
  ACmd :: SAParty a -> ACommand a -> ACmd

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
  STAT :: ConnAlias -> QueueDirection -> Maybe QueueState -> Maybe SubMode -> ACommand Agent
  SEND :: ConnAlias -> MsgBody -> ACommand User
  MSG :: ConnAlias -> AgentMsgId -> UTCTime -> UTCTime -> MsgStatus -> MsgBody -> ACommand Agent
  ACK :: ConnAlias -> AgentMsgId -> ACommand User
  RCVD :: ConnAlias -> AgentMsgId -> ACommand Agent
  OFF :: ConnAlias -> ACommand User
  DEL :: ConnAlias -> ACommand User
  OK :: ConnAlias -> ACommand Agent
  ERR :: ErrorType -> ACommand Agent

deriving instance Show (ACommand a)

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_DEL :: AMessage
  A_MSG :: AgentMsgId -> UTCTime -> MsgBody -> AMessage
  A_ACK :: AgentMsgId -> AckStatus -> AMessage

data SMPServer = SMPServer HostName ServiceName KeyFingerprint deriving (Show)

type KeyFingerprint = Encoded

type ConnAlias = ByteString

type ConnectionName = ByteString

type OtherPartyId = Encoded

data Mode = On | Off deriving (Show)

newtype AckMode = AckMode Mode deriving (Show)

newtype SubMode = SubMode Mode deriving (Show)

data SMPQueueInfo = SMPQueueInfo SMPServer QueueId EncryptionKey
  deriving (Show)

type EncryptionKey = PublicKey

type VerificationKey = PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueState = New | Confirmed | Secured | Active | Disabled
  deriving (Show)

type AgentMsgId = Int

data MsgStatus = MsgOk | MsgError MsgErrorType
  deriving (Show)

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash
  deriving (Show)

data ErrorType = UNKNOWN | PROHIBITED -- etc.
  deriving (Show)

data AckStatus = AckOk | AckError AckErrorType
  deriving (Show)

data AckErrorType = AckUnknown | AckProhibited | AckSyntax Int -- etc.
  deriving (Show)

parseCommand :: SAParty p -> ByteString -> Either ErrorType (ACommand p)
parseCommand _ _ = Left UNKNOWN

serializeCommand :: ACommand p -> ByteString
serializeCommand = B.pack . show

aCmdGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (Either ErrorType (ACommand p))
aCmdGet _ h = getLn h >>= (\_ -> return $ Left UNKNOWN)
