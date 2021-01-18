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

import Control.Applicative ((<|>))
import Control.Monad.IO.Class
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Data.Functor
import Data.Kind
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601
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
  NEW :: SMPServer -> ACommand Client -- response INV
  INV :: SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> ReplyMode -> ACommand Client -- response OK
  CON :: ACommand Agent -- notification that connection is established
  -- TODO currently it automatically allows whoever sends the confirmation
  READY :: ACommand Agent
  -- CONF :: OtherPartyId -> ACommand Agent
  -- LET :: OtherPartyId -> ACommand Client
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

type Message = ByteString

data SMPMessage
  = SMPConfirmation PublicKey
  | SMPMessage
      { agentMsgId :: Integer,
        agentTimestamp :: UTCTime,
        previousMsgHash :: ByteString,
        agentMessage :: AMessage
      }
  deriving (Show)

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_MSG :: MsgBody -> AMessage
  deriving (Show)

parseSMPMessage :: ByteString -> Either ErrorType SMPMessage
parseSMPMessage = parse (smpMessageP <* A.endOfLine) $ SYNTAX errBadMessage
  where
    smpMessageP :: Parser SMPMessage
    smpMessageP =
      smpConfirmationP <* A.endOfLine
        <|> A.endOfLine *> smpClientMessageP

    smpConfirmationP :: Parser SMPMessage
    smpConfirmationP = SMPConfirmation <$> ("KEY " *> base64P <* A.endOfLine)

    smpClientMessageP :: Parser SMPMessage
    smpClientMessageP =
      SMPMessage
        <$> A.decimal <* A.space
        <*> tsISO8601P <* A.space
        <*> base64P <* A.endOfLine
        <*> agentMessageP

tsISO8601P :: Parser UTCTime
tsISO8601P = maybe (fail "timestamp") pure . parseISO8601 . B.unpack =<< A.takeTill (== ' ')

serializeSMPMessage :: SMPMessage -> ByteString
serializeSMPMessage = \case
  SMPConfirmation sKey -> smpMessage ("KEY " <> encode sKey) "" ""
  SMPMessage {agentMsgId, agentTimestamp, previousMsgHash, agentMessage} ->
    let header = messageHeader agentMsgId agentTimestamp previousMsgHash
        body = serializeAgentMessage agentMessage
     in smpMessage "" header body
  where
    messageHeader msgId ts prevMsgHash =
      B.unwords [B.pack $ show msgId, B.pack $ formatISO8601Millis ts, encode prevMsgHash]
    smpMessage smpHeader aHeader aBody = B.intercalate "\n" [smpHeader, aHeader, aBody, ""]

agentMessageP :: Parser AMessage
agentMessageP =
  "HELLO " *> hello
    <|> "REPLY " *> reply
    <|> "MSG " *> a_msg
  where
    hello = HELLO <$> base64P <*> ackMode
    reply = REPLY <$> smpQueueInfoP
    a_msg = do
      size :: Int <- A.decimal
      A_MSG <$> (A.endOfLine *> A.take size <* A.endOfLine)
    ackMode = " NO_ACK" $> AckMode Off <|> pure (AckMode On)

smpQueueInfoP :: Parser SMPQueueInfo
smpQueueInfoP =
  "smp::" *> (SMPQueueInfo <$> smpServerP <* "::" <*> base64P <* "::" <*> base64P)

smpServerP :: Parser SMPServer
smpServerP = SMPServer <$> server <*> port <*> msgHash
  where
    server = B.unpack <$> A.takeTill (A.inClass ":# ")
    port = A.char ':' *> (Just . show <$> (A.decimal :: Parser Int)) <|> pure Nothing
    msgHash = A.char '#' *> (Just <$> base64P) <|> pure Nothing

base64P :: Parser ByteString
base64P = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')
  pad <- A.takeWhile (== '=')
  either fail pure $ decode (str <> pad)

parseAgentMessage :: ByteString -> Either ErrorType AMessage
parseAgentMessage = parse agentMessageP $ SYNTAX errBadMessage

parse :: Parser a -> e -> (ByteString -> Either e a)
parse parser err = first (const err) . A.parseOnly (parser <* A.endOfInput)

errParams :: Either ErrorType a
errParams = Left $ SYNTAX errBadParameters

serializeAgentMessage :: AMessage -> ByteString
serializeAgentMessage = \case
  HELLO verifyKey ackMode -> "HELLO " <> encode verifyKey <> if ackMode == AckMode Off then " NO_ACK" else ""
  REPLY qInfo -> "REPLY " <> serializeSmpQueueInfo qInfo
  A_MSG body -> "MSG " <> serializeMsg body <> "\n"

serializeSmpQueueInfo :: SMPQueueInfo -> ByteString
serializeSmpQueueInfo (SMPQueueInfo srv qId ek) = B.intercalate "::" ["smp", serializeServer srv, encode qId, encode ek]

serializeServer :: SMPServer -> ByteString
serializeServer SMPServer {host, port, keyHash} = B.pack $ host <> maybe "" (':' :) port <> maybe "" (('#' :) . B.unpack) keyHash

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

newtype SubMode = SubMode Mode deriving (Show)

data SMPQueueInfo = SMPQueueInfo SMPServer SenderId EncryptionKey
  deriving (Show)

data ReplyMode = ReplyOff | ReplyOn | ReplyVia SMPServer deriving (Show)

type EncryptionKey = PublicKey

type VerificationKey = PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueStatus = New | Confirmed | Secured | Active | Disabled
  deriving (Eq, Show, Read)

type AgentMsgId = Integer

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

errBadCommand :: Int
errBadCommand = 11

errBadInvitation :: Int
errBadInvitation = 12

errNoConnAlias :: Int
errNoConnAlias = 13

errBadMessage :: Int
errBadMessage = 14

errBadServer :: Int
errBadServer = 15

smpErrTCPConnection :: Natural
smpErrTCPConnection = 1

smpErrCorrelationId :: Natural
smpErrCorrelationId = 2

smpUnexpectedResponse :: Natural
smpUnexpectedResponse = 3

parseCommandP :: Parser ACmd
parseCommandP =
  "NEW " *> newCmd
    <|> "INV " *> invResp
    <|> "JOIN " *> joinCmd
    <|> "SEND " *> sendCmd
    <|> "MSG " *> message
    <|> "ACK " *> acknowledge
    <|> "CON" $> ACmd SAgent CON
    <|> "OK" $> ACmd SAgent OK
  where
    newCmd = ACmd SClient . NEW <$> smpServerP
    invResp = ACmd SAgent . INV <$> smpQueueInfoP
    joinCmd = ACmd SClient <$> (JOIN <$> smpQueueInfoP <*> replyMode)
    sendCmd = ACmd SClient <$> (SEND <$> A.takeByteString)
    message =
      let sp = A.space; msgId = A.decimal <* sp; ts = tsISO8601P <* sp; body = A.takeByteString
       in ACmd SAgent <$> (MSG <$> msgId <*> ts <*> ts <*> status <* sp <*> body)
    acknowledge = ACmd SClient <$> (ACK <$> A.decimal)
    replyMode =
      " NO_REPLY" $> ReplyOff
        <|> A.space *> (ReplyVia <$> smpServerP)
        <|> pure ReplyOn
    status = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> msgErrorType)
    msgErrorType =
      "ID " *> (MsgBadId <$> A.decimal)
        <|> "NO_ID " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
        <|> "HASH" $> MsgBadHash

parseCommand :: ByteString -> Either ErrorType ACmd
parseCommand = parse parseCommandP $ SYNTAX errBadCommand

serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW srv -> "NEW " <> serializeServer srv
  INV qInfo -> "INV " <> serializeSmpQueueInfo qInfo
  JOIN qInfo rMode -> "JOIN " <> serializeSmpQueueInfo qInfo <> replyMode rMode
  SEND msgBody -> "SEND " <> serializeMsg msgBody
  MSG aMsgId aTs ts st body ->
    B.unwords ["MSG", B.pack $ show aMsgId, B.pack $ formatISO8601Millis aTs, B.pack $ formatISO8601Millis ts, msgStatus st, serializeMsg body]
  ACK aMsgId -> "ACK " <> B.pack (show aMsgId)
  CON -> "CON"
  ERR e -> "ERR " <> B.pack (show e)
  OK -> "OK"
  c -> B.pack $ show c
  where
    replyMode :: ReplyMode -> ByteString
    replyMode = \case
      ReplyOff -> " NO_REPLY"
      ReplyVia srv -> " " <> serializeServer srv
      ReplyOn -> ""
    msgStatus :: MsgStatus -> ByteString
    msgStatus = \case
      MsgOk -> "OK"
      MsgError e ->
        "ERR" <> case e of
          MsgSkipped fromMsgId toMsgId ->
            B.unwords ["NO_ID", B.pack $ show fromMsgId, B.pack $ show toMsgId]
          MsgBadId aMsgId -> "ID " <> B.pack (show aMsgId)
          MsgBadHash -> "HASH"

-- TODO - save function as in the server Transmission - re-use?
serializeMsg :: ByteString -> ByteString
serializeMsg body = B.pack (show $ B.length body) <> "\n" <> body

tPutRaw :: Handle -> ARawTransmission -> IO ()
tPutRaw h (corrId, connAlias, command) = do
  putLn h corrId
  putLn h connAlias
  putLn h command

tGetRaw :: Handle -> IO ARawTransmission
tGetRaw h = do
  corrId <- getLn h
  connAlias <- getLn h
  command <- getLn h
  return (corrId, connAlias, command)

tPut :: MonadIO m => Handle -> ATransmission p -> m ()
tPut h (corrId, connAlias, command) =
  liftIO $ tPutRaw h (bs corrId, connAlias, serializeCommand command)

-- | get client and agent transmissions
tGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (ATransmissionOrError p)
tGet party h = liftIO (tGetRaw h) >>= tParseLoadBody
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

    -- TODO refactor with server
    getMsgBody :: MsgBody -> m (Either ErrorType MsgBody)
    getMsgBody msgBody =
      case B.unpack msgBody of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> liftIO $ do
            body <- B.hGet h size
            s <- getLn h
            return $ if B.null s then Right body else Left SIZE
          Nothing -> return . Left $ SYNTAX errMessageBody
