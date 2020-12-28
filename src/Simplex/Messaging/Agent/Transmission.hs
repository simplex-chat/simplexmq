{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Transmission where

import Control.Monad.IO.Class
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.Time.Clock (UTCTime)
import Network.Socket
-- import Numeric.Natural
import Simplex.Messaging.Server.Transmission (CorrId (..), Encoded, MsgBody, PublicKey, QueueId, errMessageBody)
import Simplex.Messaging.Transport
import System.IO
import Text.Read

type ARawTransmission = (ByteString, ByteString, ByteString)

type ATransmission p = (CorrId, ConnAlias, ACommand p)

type ATransmissionOrError p = (CorrId, ConnAlias, Either ErrorType (ACommand p))

data AParty = Agent | Client
  deriving (Eq, Show)

data SAParty :: AParty -> Type where
  SAgent :: SAParty Agent
  SClient :: SAParty Client

deriving instance Show (SAParty p)

deriving instance Eq (SAParty p)

data ACmd where
  ACmd :: SAParty p -> ACommand p -> ACmd

deriving instance Show ACmd

data ACommand (p :: AParty) where
  NEW :: SMPServer -> AckMode -> ACommand Client
  INV :: SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> Maybe SMPServer -> AckMode -> ACommand Client
  CON :: ACommand Agent
  CONF :: OtherPartyId -> ACommand Agent
  LET :: OtherPartyId -> ACommand Client
  SUB :: SubMode -> ACommand Client
  END :: ACommand Agent
  QST :: QueueDirection -> ACommand Client
  STAT :: QueueDirection -> Maybe QueueStatus -> Maybe SubMode -> ACommand Agent
  SEND :: MsgBody -> ACommand Client
  MSG :: AgentMsgId -> UTCTime -> UTCTime -> MsgStatus -> MsgBody -> ACommand Agent
  ACK :: AgentMsgId -> ACommand Client
  RCVD :: AgentMsgId -> ACommand Agent
  OFF :: ACommand Client
  DEL :: ACommand Client
  OK :: ACommand Agent
  ERR :: ErrorType -> ACommand Agent

deriving instance Show (ACommand p)

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_MSG :: MsgBody -> AMessage
  A_ACK :: AgentMsgId -> AckStatus -> AMessage
  A_DEL :: AMessage

data SMPServer = SMPServer HostName ServiceName KeyFingerprint deriving (Show)

type KeyFingerprint = Encoded

type ConnAlias = ByteString

type OtherPartyId = Encoded

data Mode = On | Off deriving (Show)

newtype AckMode = AckMode Mode deriving (Show)

newtype SubMode = SubMode Mode deriving (Show)

data SMPQueueInfo = SMPQueueInfo SMPServer QueueId EncryptionKey
  deriving (Show)

type EncryptionKey = PublicKey

type VerificationKey = PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueStatus = New | Confirmed | Secured | Active | Disabled
  deriving (Show)

type AgentMsgId = Int

data MsgStatus = MsgOk | MsgError MsgErrorType
  deriving (Show)

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash
  deriving (Show)

data ErrorType = UNKNOWN | PROHIBITED | SYNTAX Int | SIZE -- etc. TODO SYNTAX Natural
  deriving (Show)

data AckStatus = AckOk | AckError AckErrorType
  deriving (Show)

data AckErrorType = AckUnknown | AckProhibited | AckSyntax Int -- etc.
  deriving (Show)

parseCommand :: ByteString -> Either ErrorType ACmd
parseCommand _ = Left UNKNOWN

serializeCommand :: ACommand p -> ByteString
serializeCommand = B.pack . show

tPutRaw :: MonadIO m => Handle -> ARawTransmission -> m ()
tPutRaw h (corrId, connAlias, command) = do
  putLn h corrId
  putLn h connAlias
  putLn h command

tGetRaw :: MonadIO m => Handle -> m ARawTransmission
tGetRaw h = do
  corrId <- getLn h
  connAlias <- getLn h
  command <- getLn h
  return (corrId, connAlias, command)

tPut :: MonadIO m => Handle -> ATransmission p -> m ()
tPut h (corrId, connAlias, command) = tPutRaw h (bs corrId, connAlias, serializeCommand command)

fromClient :: ACmd -> Either ErrorType ACmd
fromClient = \case
  ACmd SAgent _ -> Left PROHIBITED
  cmd -> Right cmd

fromAgent :: ACmd -> Either ErrorType ACmd
fromAgent = \case
  ACmd SClient _ -> Left PROHIBITED
  cmd -> Right cmd

-- | get client and agent transmissions
-- tGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (ATransmissionOrError p)
-- tGet fromParty h = tGetRaw h >>= tParseLoadBody
--   where
--     tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
--     tParseLoadBody t@(corrId, connAlias, command) = do
--       let cmd = parseCommand command >>= fromParty -- >>= tCredentials t
--       fullCmd <- either (return . Left) cmdWithMsgBody cmd
--       return (CorrId corrId, connAlias, fullCmd)

--     fromParty :: ACmd -> Either ErrorType (ACommand p)
--     fromParty (ACmd p cmd)
--       | p == party = Right cmd
--       | otherwise = Left PROHIBITED

--     tCredentials :: RawTransmission -> Cmd -> Either ErrorType Cmd
--     tCredentials (signature, _, queueId, _) cmd = case cmd of
--       -- IDS response should not have queue ID
--       Cmd SBroker (IDS _ _) -> Right cmd
--       -- ERROR response does not always have queue ID
--       Cmd SBroker (ERR _) -> Right cmd
--       -- other responses must have queue ID
--       Cmd SBroker _
--         | B.null queueId -> Left $ SYNTAX errNoConnectionId
--         | otherwise -> Right cmd
--       -- CREATE must NOT have signature or queue ID
--       Cmd SRecipient (NEW _)
--         | B.null signature && B.null queueId -> Right cmd
--         | otherwise -> Left $ SYNTAX errHasCredentials
--       -- SEND must have queue ID, signature is not always required
--       Cmd SSender (SEND _)
--         | B.null queueId -> Left $ SYNTAX errNoConnectionId
--         | otherwise -> Right cmd
--       -- other client commands must have both signature and queue ID
--       Cmd SRecipient _
--         | B.null signature || B.null queueId -> Left $ SYNTAX errNoCredentials
--         | otherwise -> Right cmd

-- cmdWithMsgBody :: ACommand p -> m (Either ErrorType (ACommand p))
-- cmdWithMsgBody = \case
--   SEND body -> SEND <$$> getMsgBody body
--   MSG agentMsgId srvTS agentTS status body -> MSG agentMsgId srvTS agentTS status <$$> getMsgBody body
--   cmd -> return $ Right cmd

-- getMsgBody :: MsgBody -> m (Either ErrorType MsgBody)
-- getMsgBody msgBody =
--   case B.unpack msgBody of
--     ':' : body -> return . Right $ B.pack body
--     str -> case readMaybe str :: Maybe Int of
--       Just size -> do
--         body <- getBytes h size
--         s <- getLn h
--         return $ if B.null s then Right body else Left SIZE
--       Nothing -> return . Left $ SYNTAX errMessageBody

aCmdGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (Either ErrorType (ACommand p))
aCmdGet _ h = getLn h >>= (\_ -> return $ Left UNKNOWN)
