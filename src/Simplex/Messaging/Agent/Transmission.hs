{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Agent.Transmission where

import Control.Monad
import Control.Monad.IO.Class
-- import Numeric.Natural
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Kind
import Data.List.Split (splitOn)
import Data.Time.Clock (UTCTime)
import Data.Type.Equality
import Data.Typeable ()
import Network.Socket
import Numeric.Natural
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Server.Transmission
  ( CorrId (..),
    Encoded,
    MsgBody,
    PublicKey,
    SenderId,
    errBadParameters,
    errMessageBody,
  )
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO
import Text.Read
import UnliftIO.Exception

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

instance TestEquality SAParty where
  testEquality SAgent SAgent = Just Refl
  testEquality SClient SClient = Just Refl
  testEquality _ _ = Nothing

data ACmd where
  ACmd :: SAParty p -> ACommand p -> ACmd

deriving instance Show ACmd

data ACommand (p :: AParty) where
  NEW :: SMPServer -> ACommand Client
  INV :: SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> ReplyMode -> ACommand Client
  CON :: ACommand Agent
  CONF :: OtherPartyId -> ACommand Agent
  LET :: OtherPartyId -> ACommand Client
  SUB :: SubMode -> ACommand Client
  END :: ACommand Agent
  -- QST :: QueueDirection -> ACommand Client
  -- STAT :: QueueDirection -> Maybe QueueStatus -> Maybe SubMode -> ACommand Agent
  SEND :: MsgBody -> ACommand Client
  MSG :: AgentMsgId -> UTCTime -> UTCTime -> MsgStatus -> MsgBody -> ACommand Agent
  ACK :: AgentMsgId -> ACommand Client
  -- RCVD :: AgentMsgId -> ACommand Agent
  -- OFF :: ACommand Client
  -- DEL :: ACommand Client
  OK :: ACommand Agent
  ERR :: ErrorType -> ACommand Agent

deriving instance Show (ACommand p)

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_MSG :: MsgBody -> AMessage

-- A_ACK :: AgentMsgId -> AckStatus -> AMessage
-- A_DEL :: AMessage

data SMPServer = SMPServer
  { host :: HostName,
    port :: Maybe ServiceName,
    keyHash :: Maybe KeyHash
  }
  deriving (Eq, Show)

type KeyHash = Encoded

type ConnAlias = ByteString

type OtherPartyId = Encoded

data Mode = On | Off deriving (Eq, Show, Read)

newtype AckMode = AckMode Mode deriving (Eq, Show)

newtype SubMode = SubMode Mode deriving (Show)

data SMPQueueInfo = SMPQueueInfo SMPServer SenderId EncryptionKey
  deriving (Show)

data ReplyMode = ReplyOn SMPServer | ReplyOff deriving (Show)

type EncryptionKey = PublicKey

type VerificationKey = PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueStatus = New | Confirmed | Secured | Active | Disabled
  deriving (Eq, Show, Read)

type AgentMsgId = Int

data MsgStatus = MsgOk | MsgError MsgErrorType
  deriving (Show)

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash
  deriving (Show)

data ErrorType
  = UNKNOWN
  | UNSUPPORTED -- TODO remove once all commands implemented
  | PROHIBITED
  | SYNTAX Int
  | BROKER Natural
  | SMP SMP.ErrorType
  | SIZE
  | STORE StoreError
  | INTERNAL -- etc. TODO SYNTAX Natural
  deriving (Show, Exception)

data AckStatus = AckOk | AckError AckErrorType
  deriving (Show)

data AckErrorType = AckUnknown | AckProhibited | AckSyntax Int -- etc.
  deriving (Show)

errBadEncoding :: Int
errBadEncoding = 10

errBadInvitation :: Int
errBadInvitation = 12

errNoConnAlias :: Int
errNoConnAlias = 13

smpErrTCPConnection :: Natural
smpErrTCPConnection = 1

smpErrCorrelationId :: Natural
smpErrCorrelationId = 2

smpUnexpectedResponse :: Natural
smpUnexpectedResponse = 3

parseCommand :: ByteString -> Either ErrorType ACmd
parseCommand command = case B.words command of
  ["NEW", srv] -> newConn srv -- . Right $ AckMode On
  -- ["NEW", srv, am] -> newConn srv $ ackMode am
  ["INV", qInfo] -> ACmd SAgent . INV <$> smpQueueInfo qInfo
  "JOIN" : qInfo : ws -> joinConn qInfo ws
  ["CON"] -> Right . ACmd SAgent $ CON
  "NEW" : _ -> errParams
  "INV" : _ -> errParams
  "JOIN" : _ -> errParams
  "CON" : _ -> errParams
  _ -> Left UNKNOWN
  where
    newConn :: ByteString -> Either ErrorType ACmd
    newConn srv = ACmd SClient . NEW <$> smpServer srv

    joinConn :: ByteString -> [ByteString] -> Either ErrorType ACmd
    joinConn qInfo ws = do
      q <- smpQueueInfo qInfo
      case ws of
        [] -> let SMPQueueInfo srv _ _ = q in joinCmd q $ ReplyOn srv
        ["NO_REPLY"] -> joinCmd q ReplyOff
        [srv] -> do
          s <- smpServer srv
          joinCmd q $ ReplyOn s
        _ -> errParams
      where
        joinCmd q r = return $ ACmd SClient $ JOIN q r

    smpServer :: ByteString -> Either ErrorType SMPServer
    smpServer srv =
      let (s, kf) = span (/= '#') $ B.unpack srv
          (h, p) = span (/= ':') s
       in SMPServer h (srvPart p) <$> traverse dec64 (srvPart kf)

    smpQueueInfo :: ByteString -> Either ErrorType SMPQueueInfo
    smpQueueInfo qInfo = case splitOn "::" $ B.unpack qInfo of
      ["smp", srv, qId, ek] -> liftM3 SMPQueueInfo (smpServer $ B.pack srv) (dec64 qId) (dec64 ek)
      _ -> Left $ SYNTAX errBadInvitation

    dec64 :: String -> Either ErrorType ByteString
    dec64 s = case decode $ B.pack s of
      Left _ -> Left $ SYNTAX errBadEncoding
      Right b -> Right b

    srvPart :: String -> Maybe String
    srvPart s = if length s > 1 then Just $ tail s else Nothing

    -- ackMode :: ByteString -> Either ErrorType AckMode
    -- ackMode am = case B.split '=' am of
    --   ["ACK", mode] -> AckMode <$> getMode mode
    --   _ -> errParams

    -- getMode :: ByteString -> Either ErrorType Mode
    -- getMode mode = case mode of
    --   "ON" -> Right On
    --   "OFF" -> Right Off
    --   _ -> errParams

    errParams :: Either ErrorType a
    errParams = Left $ SYNTAX errBadParameters

serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW srv -> "NEW " <> server srv
  INV qInfo -> "INV " <> smpQueueInfo qInfo
  JOIN qInfo rMode ->
    "JOIN " <> smpQueueInfo qInfo <> " "
      <> case rMode of
        ReplyOff -> "NO_REPLY"
        ReplyOn srv -> server srv
  CON -> "CON"
  ERR e -> "ERR " <> B.pack (show e)
  c -> B.pack $ show c
  where
    server :: SMPServer -> ByteString
    server SMPServer {host, port, keyHash} = B.pack $ host <> maybe "" (':' :) port <> maybe "" (('#' :) . B.unpack) keyHash

    smpQueueInfo :: SMPQueueInfo -> ByteString
    smpQueueInfo (SMPQueueInfo srv qId ek) = "smp::" <> server srv <> "::" <> encode qId <> "::" <> encode ek

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

-- | get client and agent transmissions
tGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (ATransmissionOrError p)
tGet party h = tGetRaw h >>= tParseLoadBody
  where
    tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
    tParseLoadBody t@(corrId, connAlias, command) = do
      let cmd = parseCommand command >>= fromParty >>= tConnAlias t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (CorrId corrId, connAlias, fullCmd)

    fromParty :: ACmd -> Either ErrorType (ACommand p)
    fromParty (ACmd (p :: p1) cmd) = case testEquality party p of
      Just Refl -> Right cmd
      _ -> Left PROHIBITED

    tConnAlias :: ARawTransmission -> ACommand p -> Either ErrorType (ACommand p)
    tConnAlias (_, connAlias, _) cmd = case cmd of
      -- NEW and JOIN have optional connAlias
      NEW _ -> Right cmd
      JOIN _ _ -> Right cmd
      -- ERROR response does not always have connAlias
      ERR _ -> Right cmd
      -- other responses must have connAlias
      _
        | B.null connAlias -> Left $ SYNTAX errNoConnAlias
        | otherwise -> Right cmd

    cmdWithMsgBody :: ACommand p -> m (Either ErrorType (ACommand p))
    cmdWithMsgBody = \case
      SEND body -> SEND <$$> getMsgBody body
      MSG agentMsgId srvTS agentTS status body -> MSG agentMsgId srvTS agentTS status <$$> getMsgBody body
      cmd -> return $ Right cmd

    getMsgBody :: MsgBody -> m (Either ErrorType MsgBody)
    getMsgBody msgBody =
      case B.unpack msgBody of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> do
            body <- getBytes h size
            s <- getLn h
            return $ if B.null s then Right body else Left SIZE
          Nothing -> return . Left $ SYNTAX errMessageBody
