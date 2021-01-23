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

import Control.Monad
import Control.Monad.IO.Class
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (ord)
import Data.Kind
import Data.Time.Clock
import Data.Time.ISO8601
import Simplex.Messaging.Types
import Simplex.Messaging.Transport
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

type Signed = (CorrId, QueueId, Cmd)

type Transmission = (Signature, Signed)

type SignedOrError = (CorrId, QueueId, Either ErrorType Cmd)

type TransmissionOrError = (Signature, SignedOrError)

type RawTransmission = (ByteString, ByteString, ByteString, ByteString)

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

parseCommand :: ByteString -> Either ErrorType Cmd
parseCommand command = case B.words command of
  ["NEW", rKeyStr] -> case decode rKeyStr of
    Right rKey -> rCmd $ NEW rKey
    _ -> errParams
  ["SUB"] -> rCmd SUB
  ["KEY", sKeyStr] -> case decode sKeyStr of
    Right sKey -> rCmd $ KEY sKey
    _ -> errParams
  ["ACK"] -> rCmd ACK
  ["OFF"] -> rCmd OFF
  ["DEL"] -> rCmd DEL
  ["SEND"] -> errParams
  "SEND" : msgBody -> Right . Cmd SSender . SEND $ B.unwords msgBody
  ["IDS", rIdStr, sIdStr] -> case decode rIdStr of
    Right rId -> case decode sIdStr of
      Right sId -> bCmd $ IDS rId sId
      _ -> errParams
    _ -> errParams
  ["MSG", msgIdStr, ts, msgBody] -> case decode msgIdStr of
    Right msgId -> case parseISO8601 $ B.unpack ts of
      Just utc -> bCmd $ MSG msgId utc msgBody
      _ -> errParams
    _ -> errParams
  ["END"] -> bCmd END
  ["OK"] -> bCmd OK
  "ERR" : err -> case err of
    ["UNKNOWN"] -> bErr UNKNOWN
    ["PROHIBITED"] -> bErr PROHIBITED
    ["SYNTAX", errCode] -> maybe errParams (bErr . SYNTAX) $ digitToInt $ B.unpack errCode
    ["SIZE"] -> bErr SIZE
    ["AUTH"] -> bErr AUTH
    ["INTERNAL"] -> bErr INTERNAL
    _ -> errParams
  "NEW" : _ -> errParams
  "SUB" : _ -> errParams
  "KEY" : _ -> errParams
  "ACK" : _ -> errParams
  "OFF" : _ -> errParams
  "DEL" : _ -> errParams
  "MSG" : _ -> errParams
  "IDS" : _ -> errParams
  "END" : _ -> errParams
  "OK" : _ -> errParams
  _ -> Left UNKNOWN
  where
    errParams = Left $ SYNTAX errBadParameters
    rCmd = Right . Cmd SRecipient
    bCmd = Right . Cmd SBroker
    bErr = bCmd . ERR

digitToInt :: String -> Maybe Int
digitToInt [c] =
  let i = ord c - zero
   in if i >= 0 && i <= 9 then Just i else Nothing
digitToInt _ = Nothing

zero :: Int
zero = ord '0'

serializeCommand :: Cmd -> ByteString
serializeCommand = \case
  Cmd SRecipient (NEW rKey) -> "NEW " <> encode rKey
  Cmd SRecipient (KEY sKey) -> "KEY " <> encode sKey
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

tPut :: MonadIO m => Handle -> Transmission -> m ()
tPut h (signature, (corrId, queueId, command)) =
  liftIO $ tPutRaw h (encode signature, bs corrId, encode queueId, serializeCommand command)

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
tGet :: forall m. MonadIO m => (Cmd -> Either ErrorType Cmd) -> Handle -> m TransmissionOrError
tGet fromParty h = do
  (signature, corrId, queueId, command) <- liftIO $ tGetRaw h
  let decodedTransmission = liftM2 (,corrId,,command) (decode signature) (decode queueId)
  either (const $ tError corrId) tParseLoadBody decodedTransmission
  where
    tError :: ByteString -> m TransmissionOrError
    tError corrId = return (B.empty, (CorrId corrId, B.empty, Left $ SYNTAX errBadTransmission))

    tParseLoadBody :: RawTransmission -> m TransmissionOrError
    tParseLoadBody t@(signature, corrId, queueId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tCredentials t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (signature, (CorrId corrId, queueId, fullCmd))

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
        | B.null signature && B.null queueId -> Right cmd
        | otherwise -> Left $ SYNTAX errHasCredentials
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
