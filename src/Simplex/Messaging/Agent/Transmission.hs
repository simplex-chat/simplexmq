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
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Time.Clock (UTCTime)
import Data.Time.ISO8601
import Data.Type.Equality
import Data.Typeable ()
import Network.Socket
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers
import Simplex.Messaging.Protocol
  ( CorrId (..),
    Encoded,
    ErrorType,
    MsgBody,
    MsgId,
    SenderPublicKey,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO
import Text.Read
import UnliftIO.Exception

type ARawTransmission = (ByteString, ByteString, ByteString)

type ATransmission p = (CorrId, ConnAlias, ACommand p)

type ATransmissionOrError p = (CorrId, ConnAlias, Either AgentErrorType (ACommand p))

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

data ACmd = forall p. ACmd (SAParty p) (ACommand p)

deriving instance Show ACmd

data ACommand (p :: AParty) where
  NEW :: SMPServer -> ACommand Client -- response INV
  INV :: SMPQueueInfo -> ACommand Agent
  JOIN :: SMPQueueInfo -> ReplyMode -> ACommand Client -- response OK
  CON :: ACommand Agent -- notification that connection is established
  -- TODO currently it automatically allows whoever sends the confirmation
  -- CONF :: OtherPartyId -> ACommand Agent
  -- LET :: OtherPartyId -> ACommand Client
  SUB :: ACommand Client
  SUBALL :: ACommand Client -- TODO should be moved to chat protocol - hack for subscribing to all
  END :: ACommand Agent
  -- QST :: QueueDirection -> ACommand Client
  -- STAT :: QueueDirection -> Maybe QueueStatus -> Maybe SubMode -> ACommand Agent
  SEND :: MsgBody -> ACommand Client
  SENT :: AgentMsgId -> ACommand Agent
  MSG ::
    { m_recipient :: (AgentMsgId, UTCTime),
      m_broker :: (MsgId, UTCTime),
      m_sender :: (AgentMsgId, UTCTime),
      m_status :: MsgStatus,
      m_body :: MsgBody
    } ->
    ACommand Agent
  -- ACK :: AgentMsgId -> ACommand Client
  -- RCVD :: AgentMsgId -> ACommand Agent
  OFF :: ACommand Client
  DEL :: ACommand Client
  OK :: ACommand Agent
  ERR :: AgentErrorType -> ACommand Agent

deriving instance Eq (ACommand p)

deriving instance Show (ACommand p)

type Message = ByteString

data SMPMessage
  = SMPConfirmation SenderPublicKey
  | SMPMessage
      { senderMsgId :: AgentMsgId,
        senderTimestamp :: SenderTimestamp,
        previousMsgHash :: ByteString,
        agentMessage :: AMessage
      }
  deriving (Show)

data AMessage where
  HELLO :: VerificationKey -> AckMode -> AMessage
  REPLY :: SMPQueueInfo -> AMessage
  A_MSG :: MsgBody -> AMessage
  deriving (Show)

parseSMPMessage :: ByteString -> Either AgentErrorType SMPMessage
parseSMPMessage = parse (smpMessageP <* A.endOfLine) $ AGENT A_MESSAGE
  where
    smpMessageP :: Parser SMPMessage
    smpMessageP =
      smpConfirmationP <* A.endOfLine
        <|> A.endOfLine *> smpClientMessageP

    smpConfirmationP :: Parser SMPMessage
    smpConfirmationP = SMPConfirmation <$> ("KEY " *> C.pubKeyP <* A.endOfLine)

    smpClientMessageP :: Parser SMPMessage
    smpClientMessageP =
      SMPMessage
        <$> A.decimal <* A.space
        <*> tsISO8601P <* A.space
        <*> base64P <* A.endOfLine
        <*> agentMessageP

serializeSMPMessage :: SMPMessage -> ByteString
serializeSMPMessage = \case
  SMPConfirmation sKey -> smpMessage ("KEY " <> C.serializePubKey sKey) "" ""
  SMPMessage {senderMsgId, senderTimestamp, previousMsgHash, agentMessage} ->
    let header = messageHeader senderMsgId senderTimestamp previousMsgHash
        body = serializeAgentMessage agentMessage
     in smpMessage "" header body
  where
    messageHeader msgId ts prevMsgHash =
      B.unwords [bshow msgId, B.pack $ formatISO8601Millis ts, encode prevMsgHash]
    smpMessage smpHeader aHeader aBody = B.intercalate "\n" [smpHeader, aHeader, aBody, ""]

agentMessageP :: Parser AMessage
agentMessageP =
  "HELLO " *> hello
    <|> "REPLY " *> reply
    <|> "MSG " *> a_msg
  where
    hello = HELLO <$> C.pubKeyP <*> ackMode
    reply = REPLY <$> smpQueueInfoP
    a_msg = do
      size :: Int <- A.decimal
      A_MSG <$> (A.endOfLine *> A.take size <* A.endOfLine)
    ackMode = " NO_ACK" $> AckMode Off <|> pure (AckMode On)

smpQueueInfoP :: Parser SMPQueueInfo
smpQueueInfoP =
  "smp::" *> (SMPQueueInfo <$> smpServerP <* "::" <*> base64P <* "::" <*> C.pubKeyP)

smpServerP :: Parser SMPServer
smpServerP = SMPServer <$> server <*> port <*> kHash
  where
    server = B.unpack <$> A.takeTill (A.inClass ":# ")
    port = fromChar ':' $ show <$> (A.decimal :: Parser Int)
    kHash = fromChar '#' C.keyHashP
    fromChar :: Char -> Parser a -> Parser (Maybe a)
    fromChar ch parser = do
      c <- A.peekChar
      if c == Just ch
        then A.char ch *> (Just <$> parser)
        else pure Nothing

parseAgentMessage :: ByteString -> Either AgentErrorType AMessage
parseAgentMessage = parse agentMessageP $ AGENT A_MESSAGE

serializeAgentMessage :: AMessage -> ByteString
serializeAgentMessage = \case
  HELLO verifyKey ackMode -> "HELLO " <> C.serializePubKey verifyKey <> if ackMode == AckMode Off then " NO_ACK" else ""
  REPLY qInfo -> "REPLY " <> serializeSmpQueueInfo qInfo
  A_MSG body -> "MSG " <> serializeMsg body <> "\n"

serializeSmpQueueInfo :: SMPQueueInfo -> ByteString
serializeSmpQueueInfo (SMPQueueInfo srv qId ek) =
  B.intercalate "::" ["smp", serializeServer srv, encode qId, C.serializePubKey ek]

serializeServer :: SMPServer -> ByteString
serializeServer SMPServer {host, port, keyHash} =
  B.pack $ host <> maybe "" (':' :) port <> maybe "" (('#' :) . B.unpack . C.serializeKeyHash) keyHash

data SMPServer = SMPServer
  { host :: HostName,
    port :: Maybe ServiceName,
    keyHash :: Maybe C.KeyHash
  }
  deriving (Eq, Ord, Show)

type ConnAlias = ByteString

type OtherPartyId = Encoded

data Mode = On | Off deriving (Eq, Show, Read)

newtype AckMode = AckMode Mode deriving (Eq, Show)

data SMPQueueInfo = SMPQueueInfo SMPServer SMP.SenderId EncryptionKey
  deriving (Eq, Show)

data ReplyMode = ReplyOff | ReplyOn | ReplyVia SMPServer deriving (Eq, Show)

type EncryptionKey = C.PublicKey

type DecryptionKey = C.SafePrivateKey

type SignatureKey = C.SafePrivateKey

type VerificationKey = C.PublicKey

data QueueDirection = SND | RCV deriving (Show)

data QueueStatus = New | Confirmed | Secured | Active | Disabled
  deriving (Eq, Show, Read)

type AgentMsgId = Int64

type SenderTimestamp = UTCTime

data MsgStatus = MsgOk | MsgError MsgErrorType
  deriving (Eq, Show)

data MsgErrorType = MsgSkipped AgentMsgId AgentMsgId | MsgBadId AgentMsgId | MsgBadHash
  deriving (Eq, Show)

-- | error type used in errors sent to agent clients
data AgentErrorType
  = CMD CommandErrorType -- command errors
  | CONN ConnectionErrorType -- connection state errors
  | SMP ErrorType -- SMP protocol errors forwarded to agent clients
  | BROKER BrokerErrorType -- SMP server errors
  | AGENT SMPAgentError -- errors of other agents
  | INTERNAL ByteString -- agent implementation errors
  deriving (Eq, Read, Show, Exception)

data CommandErrorType
  = PROHIBITED -- command is prohibited
  | SYNTAX -- command syntax is invalid
  | NO_CONN -- connection alias is required with this command
  | SIZE -- message size is not correct (no terminating space)
  | LARGE -- message does not fit SMP block
  deriving (Eq, Read, Show, Exception)

data ConnectionErrorType
  = UNKNOWN -- connection alias not in database
  | DUPLICATE -- connection alias already exists
  | SIMPLEX_RCV -- operation requires send queue
  | SIMPLEX_SND -- operation requires receive queue
  deriving (Eq, Read, Show, Exception)

data BrokerErrorType
  = RESPONSE ErrorType -- invalid server response (failed to parse)
  | QUEUE -- queue ID in response is different from expected
  | UNEXPECTED -- unexpected response
  | NETWORK -- network error
  | TRANSPORT TransportError -- handshake or other transport error
  | TIMEOUT -- command response timeout
  deriving (Eq, Read, Show, Exception)

data SMPAgentError
  = A_MESSAGE -- possibly should include bytestring that failed to parse
  | A_PROHIBITED -- possibly should include the prohibited SMP/agent message
  deriving (Eq, Read, Show, Exception)

commandP :: Parser ACmd
commandP =
  "NEW " *> newCmd
    <|> "INV " *> invResp
    <|> "JOIN " *> joinCmd
    <|> "SUB" $> ACmd SClient SUB
    <|> "SUBALL" $> ACmd SClient SUBALL -- TODO remove - hack for subscribing to all
    <|> "END" $> ACmd SAgent END
    <|> "SEND " *> sendCmd
    <|> "SENT " *> sentResp
    <|> "MSG " *> message
    <|> "OFF" $> ACmd SClient OFF
    <|> "DEL" $> ACmd SClient DEL
    <|> "ERR " *> agentError
    <|> "CON" $> ACmd SAgent CON
    <|> "OK" $> ACmd SAgent OK
  where
    newCmd = ACmd SClient . NEW <$> smpServerP
    invResp = ACmd SAgent . INV <$> smpQueueInfoP
    joinCmd = ACmd SClient <$> (JOIN <$> smpQueueInfoP <*> replyMode)
    sendCmd = ACmd SClient . SEND <$> A.takeByteString
    sentResp = ACmd SAgent . SENT <$> A.decimal
    message = do
      m_status <- status <* A.space
      m_recipient <- "R=" *> partyMeta A.decimal
      m_broker <- "B=" *> partyMeta base64P
      m_sender <- "S=" *> partyMeta A.decimal
      m_body <- A.takeByteString
      return $ ACmd SAgent MSG {m_recipient, m_broker, m_sender, m_status, m_body}
    replyMode =
      " NO_REPLY" $> ReplyOff
        <|> A.space *> (ReplyVia <$> smpServerP)
        <|> pure ReplyOn
    partyMeta idParser = (,) <$> idParser <* "," <*> tsISO8601P <* A.space
    status = "OK" $> MsgOk <|> "ERR " *> (MsgError <$> msgErrorType)
    msgErrorType =
      "ID " *> (MsgBadId <$> A.decimal)
        <|> "NO_ID " *> (MsgSkipped <$> A.decimal <* A.space <*> A.decimal)
        <|> "HASH" $> MsgBadHash
    agentError = ACmd SAgent . ERR <$> agentErrorType
    agentErrorType =
      "SMP " *> (SMP <$> SMP.errorTypeP)
        <|> "BROKER " *> (BROKER <$> brokerError)
        <|> parseRead
    brokerError =
      "RESPONSE " *> (RESPONSE <$> SMP.errorTypeP)
        <|> "TRANSPORT " *> (TRANSPORT <$> transportError)
        <|> parseRead
    transportError =
      "BLOCK" $> TEBadBlock
        <|> "AES_ENCRYPT" $> TEEncrypt
        <|> "AES_DECRYPT" $> TEDecrypt
        <|> TEHandshake <$> parseRead

parseCommand :: ByteString -> Either AgentErrorType ACmd
parseCommand = parse commandP $ CMD SYNTAX

serializeCommand :: ACommand p -> ByteString
serializeCommand = \case
  NEW srv -> "NEW " <> serializeServer srv
  INV qInfo -> "INV " <> serializeSmpQueueInfo qInfo
  JOIN qInfo rMode -> "JOIN " <> serializeSmpQueueInfo qInfo <> replyMode rMode
  SUB -> "SUB"
  SUBALL -> "SUBALL" -- TODO remove - hack for subscribing to all
  END -> "END"
  SEND msgBody -> "SEND " <> serializeMsg msgBody
  SENT mId -> "SENT " <> bshow mId
  MSG {m_recipient = (rmId, rTs), m_broker = (bmId, bTs), m_sender = (smId, sTs), m_status, m_body} ->
    B.unwords
      [ "MSG",
        msgStatus m_status,
        "R=" <> bshow rmId <> "," <> showTs rTs,
        "B=" <> encode bmId <> "," <> showTs bTs,
        "S=" <> bshow smId <> "," <> showTs sTs,
        serializeMsg m_body
      ]
  OFF -> "OFF"
  DEL -> "DEL"
  CON -> "CON"
  ERR e -> "ERR " <> agentError e
  OK -> "OK"
  where
    replyMode :: ReplyMode -> ByteString
    replyMode = \case
      ReplyOff -> " NO_REPLY"
      ReplyVia srv -> " " <> serializeServer srv
      ReplyOn -> ""
    showTs :: UTCTime -> ByteString
    showTs = B.pack . formatISO8601Millis
    msgStatus :: MsgStatus -> ByteString
    msgStatus = \case
      MsgOk -> "OK"
      MsgError e ->
        "ERR" <> case e of
          MsgSkipped fromMsgId toMsgId ->
            B.unwords ["NO_ID", bshow fromMsgId, bshow toMsgId]
          MsgBadId aMsgId -> "ID " <> bshow aMsgId
          MsgBadHash -> "HASH"
    agentError :: AgentErrorType -> ByteString
    agentError = \case
      SMP e -> "SMP " <> bshow e
      BROKER e -> "BROKER " <> brokerError e
      e -> bshow e
    brokerError :: BrokerErrorType -> ByteString
    brokerError = \case
      RESPONSE e -> "RESPONSE " <> bshow e
      TRANSPORT e -> "TRANSPORT " <> transportError e
      e -> bshow e
    transportError :: TransportError -> ByteString
    transportError = \case
      TEEncrypt -> "AES_ENCRYPT"
      TEDecrypt -> "AES_DECRYPT"
      TEBadBlock -> "BLOCK"
      TEHandshake e -> bshow e

serializeMsg :: ByteString -> ByteString
serializeMsg body = bshow (B.length body) <> "\n" <> body

tPutRaw :: Handle -> ARawTransmission -> IO ()
tPutRaw h (corrId, connAlias, command) = do
  putLn h corrId
  putLn h connAlias
  putLn h command

tGetRaw :: Handle -> IO ARawTransmission
tGetRaw h = (,,) <$> getLn h <*> getLn h <*> getLn h

tPut :: MonadIO m => Handle -> ATransmission p -> m ()
tPut h (CorrId corrId, connAlias, command) =
  liftIO $ tPutRaw h (corrId, connAlias, serializeCommand command)

-- | get client and agent transmissions
tGet :: forall m p. MonadIO m => SAParty p -> Handle -> m (ATransmissionOrError p)
tGet party h = liftIO (tGetRaw h) >>= tParseLoadBody
  where
    tParseLoadBody :: ARawTransmission -> m (ATransmissionOrError p)
    tParseLoadBody t@(corrId, connAlias, command) = do
      let cmd = parseCommand command >>= fromParty >>= tConnAlias t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (CorrId corrId, connAlias, fullCmd)

    fromParty :: ACmd -> Either AgentErrorType (ACommand p)
    fromParty (ACmd (p :: p1) cmd) = case testEquality party p of
      Just Refl -> Right cmd
      _ -> Left $ CMD PROHIBITED

    tConnAlias :: ARawTransmission -> ACommand p -> Either AgentErrorType (ACommand p)
    tConnAlias (_, connAlias, _) cmd = case cmd of
      -- NEW and JOIN have optional connAlias
      NEW _ -> Right cmd
      JOIN _ _ -> Right cmd
      -- ERROR response does not always have connAlias
      ERR _ -> Right cmd
      -- other responses must have connAlias
      _
        | B.null connAlias -> Left $ CMD NO_CONN
        | otherwise -> Right cmd

    cmdWithMsgBody :: ACommand p -> m (Either AgentErrorType (ACommand p))
    cmdWithMsgBody = \case
      SEND body -> SEND <$$> getMsgBody body
      MSG agentMsgId srvTS agentTS status body -> MSG agentMsgId srvTS agentTS status <$$> getMsgBody body
      cmd -> return $ Right cmd

    -- TODO refactor with server
    getMsgBody :: MsgBody -> m (Either AgentErrorType MsgBody)
    getMsgBody msgBody =
      case B.unpack msgBody of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> liftIO $ do
            body <- B.hGet h size
            s <- getLn h
            return $ if B.null s then Right body else Left $ CMD SIZE
          Nothing -> return . Left $ CMD SYNTAX
