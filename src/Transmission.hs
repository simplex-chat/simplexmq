{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Transmission where

import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (ord)
import Data.Kind
import Data.Time.Clock
import Data.Time.ISO8601

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

type Signed = (ConnId, Cmd)

type Transmission = (Signature, Signed)

type SignedOrError = (ConnId, Either ErrorType Cmd)

type TransmissionOrError = (Signature, SignedOrError)

type RawTransmission = (ByteString, ByteString, ByteString)

data Command (a :: Party) where
  CONN :: RecipientKey -> Command Recipient
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
  ["CONN", rKeyStr] -> case decode rKeyStr of
    Right rKey -> rCmd $ CONN rKey
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
  "CONN" : _ -> errParams
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
  Cmd SRecipient (CONN rKey) -> "CONN " <> encode rKey
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

type Encoded = ByteString

type PublicKey = Encoded

type Signature = Encoded

type RecipientKey = PublicKey

type SenderKey = PublicKey

type RecipientId = ConnId

type SenderId = ConnId

type ConnId = Encoded

type MsgId = Encoded

type MsgBody = ByteString

data ErrorType = UNKNOWN | PROHIBITED | SYNTAX Int | SIZE | AUTH | INTERNAL | DUPLICATE deriving (Show, Eq)

errBadTransmission :: Int
errBadTransmission = 1

errBadParameters :: Int
errBadParameters = 2

errNoCredentials :: Int
errNoCredentials = 3

errHasCredentials :: Int
errHasCredentials = 4

errNoConnectionId :: Int
errNoConnectionId = 5

errMessageBody :: Int
errMessageBody = 6
