{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Protocol where

import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.IO.Class
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Kind
import Data.Time.Clock
import Data.Time.ISO8601
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers
import Simplex.Messaging.Transport
import Simplex.Messaging.Types
import Simplex.Messaging.Util
import System.IO
import Text.Read

data Party = Broker | Recipient | Sender
  deriving (Show)

data SParty :: Party -> Type where
  SBroker :: SParty Broker
  SRecipient :: SParty Recipient
  SSender :: SParty Sender

deriving instance Show (SParty a)

data Cmd where
  Cmd :: SParty a -> Command a -> Cmd

deriving instance Show Cmd

type Transmission = (CorrId, QueueId, Cmd)

type SignedTransmission = (C.Signature, Transmission)

type TransmissionOrError = (CorrId, QueueId, Either ErrorType Cmd)

type SignedTransmissionOrError = (C.Signature, TransmissionOrError)

type RawTransmission = (ByteString, ByteString, ByteString, ByteString)

type RecipientId = QueueId

type SenderId = QueueId

type QueueId = Encoded

data Command (a :: Party) where
  NEW :: RecipientKey -> Command Recipient
  SUB :: Command Recipient
  KEY :: SenderKey -> Command Recipient
  ACK :: Command Recipient
  OFF :: Command Recipient
  DEL :: Command Recipient
  SEND :: MsgBody -> Command Sender
  IDS :: RecipientId -> SenderId -> Command Broker
  MSG :: MsgId -> UTCTime -> MsgBody -> Command Broker
  END :: Command Broker
  OK :: Command Broker
  ERR :: ErrorType -> Command Broker

deriving instance Show (Command a)

deriving instance Eq (Command a)

commandP :: Parser Cmd
commandP =
  "NEW " *> newCmd
    <|> "IDS " *> idsResp
    <|> "SUB" $> Cmd SRecipient SUB
    <|> "KEY " *> keyCmd
    <|> "ACK" $> Cmd SRecipient ACK
    <|> "OFF" $> Cmd SRecipient OFF
    <|> "DEL" $> Cmd SRecipient DEL
    <|> "SEND " *> sendCmd
    <|> "MSG " *> message
    <|> "END" $> Cmd SBroker END
    <|> "OK" $> Cmd SBroker OK
    <|> "ERR " *> serverError
  where
    newCmd = Cmd SRecipient . NEW <$> C.pubKeyP
    idsResp = Cmd SBroker <$> (IDS <$> (base64P <* A.space) <*> base64P)
    keyCmd = Cmd SRecipient . KEY <$> C.pubKeyP
    sendCmd = Cmd SSender . SEND <$> A.takeByteString
    message = do
      msgId <- base64P <* A.space
      ts <- tsISO8601P <* A.space
      Cmd SBroker . MSG msgId ts <$> A.takeByteString
    serverError = Cmd SBroker . ERR <$> errorType
    errorType =
      "PROHIBITED" $> PROHIBITED
        <|> "SYNTAX " *> (SYNTAX <$> A.decimal)
        <|> "SIZE" $> SIZE
        <|> "AUTH" $> AUTH
        <|> "INTERNAL" $> INTERNAL

parseCommand :: ByteString -> Either ErrorType Cmd
parseCommand = parse commandP $ SYNTAX errBadSMPCommand

serializeCommand :: Cmd -> ByteString
serializeCommand = \case
  Cmd SRecipient (NEW rKey) -> "NEW " <> C.serializePubKey rKey
  Cmd SRecipient (KEY sKey) -> "KEY " <> C.serializePubKey sKey
  Cmd SRecipient cmd -> B.pack $ show cmd
  Cmd SSender (SEND msgBody) -> "SEND" <> serializeMsg msgBody
  Cmd SBroker (MSG msgId ts msgBody) ->
    B.unwords ["MSG", encode msgId, B.pack $ formatISO8601Millis ts] <> serializeMsg msgBody
  Cmd SBroker (IDS rId sId) -> B.unwords ["IDS", encode rId, encode sId]
  Cmd SBroker (ERR err) -> "ERR " <> B.pack (show err)
  Cmd SBroker resp -> B.pack $ show resp
  where
    serializeMsg msgBody = " " <> B.pack (show $ B.length msgBody) <> "\n" <> msgBody

tPutRaw :: Handle -> RawTransmission -> IO ()
tPutRaw h (signature, corrId, queueId, command) = do
  putLn h signature
  putLn h corrId
  putLn h queueId
  putLn h command

tGetRaw :: Handle -> IO RawTransmission
tGetRaw h = do
  signature <- getLn h
  corrId <- getLn h
  queueId <- getLn h
  command <- getLn h
  return (signature, corrId, queueId, command)

tPut :: MonadIO m => Handle -> SignedTransmission -> m ()
tPut h (C.Signature sig, (corrId, queueId, command)) =
  liftIO $ tPutRaw h (encode sig, bs corrId, encode queueId, serializeCommand command)

fromClient :: Cmd -> Either ErrorType Cmd
fromClient = \case
  Cmd SBroker _ -> Left PROHIBITED
  cmd -> Right cmd

fromServer :: Cmd -> Either ErrorType Cmd
fromServer = \case
  cmd@(Cmd SBroker _) -> Right cmd
  _ -> Left PROHIBITED

-- | get client and server transmissions
-- `fromParty` is used to limit allowed senders - `fromClient` or `fromServer` should be used
tGet :: forall m. MonadIO m => (Cmd -> Either ErrorType Cmd) -> Handle -> m SignedTransmissionOrError
tGet fromParty h = do
  (signature, corrId, queueId, command) <- liftIO $ tGetRaw h
  let decodedTransmission = liftM2 (,corrId,,command) (decode signature) (decode queueId)
  either (const $ tError corrId) tParseLoadBody decodedTransmission
  where
    tError :: ByteString -> m SignedTransmissionOrError
    tError corrId = return (C.Signature B.empty, (CorrId corrId, B.empty, Left $ SYNTAX errBadTransmission))

    tParseLoadBody :: RawTransmission -> m SignedTransmissionOrError
    tParseLoadBody t@(sig, corrId, queueId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tCredentials t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (C.Signature sig, (CorrId corrId, queueId, fullCmd))

    tCredentials :: RawTransmission -> Cmd -> Either ErrorType Cmd
    tCredentials (signature, _, queueId, _) cmd = case cmd of
      -- IDS response should not have queue ID
      Cmd SBroker (IDS _ _) -> Right cmd
      -- ERR response does not always have queue ID
      Cmd SBroker (ERR _) -> Right cmd
      -- other responses must have queue ID
      Cmd SBroker _
        | B.null queueId -> Left $ SYNTAX errNoQueueId
        | otherwise -> Right cmd
      -- NEW must NOT have signature or queue ID
      Cmd SRecipient (NEW _)
        | B.null signature -> Left $ SYNTAX errNoCredentials
        | not (B.null queueId) -> Left $ SYNTAX errHasCredentials
        | otherwise -> Right cmd
      -- SEND must have queue ID, signature is not always required
      Cmd SSender (SEND _)
        | B.null queueId -> Left $ SYNTAX errNoQueueId
        | otherwise -> Right cmd
      -- other client commands must have both signature and queue ID
      Cmd SRecipient _
        | B.null signature || B.null queueId -> Left $ SYNTAX errNoCredentials
        | otherwise -> Right cmd

    cmdWithMsgBody :: Cmd -> m (Either ErrorType Cmd)
    cmdWithMsgBody = \case
      Cmd SSender (SEND body) ->
        Cmd SSender . SEND <$$> getMsgBody body
      Cmd SBroker (MSG msgId ts body) ->
        Cmd SBroker . MSG msgId ts <$$> getMsgBody body
      cmd -> return $ Right cmd

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
