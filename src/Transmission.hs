{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Transmission where

import qualified Data.ByteString.Char8 as B
import Data.Singletons.TH
import Text.Read

$( singletons
     [d|
       data Party = Broker | Recipient | Sender
         deriving (Show)
       |]
 )

type Signed (a :: Party) = (ConnId, Command a)

data Cmd where
  Cmd :: Sing a -> Command a -> Cmd

deriving instance Show Cmd

type SomeSigned = (ConnId, Cmd)

type Transmission = (Signature, SomeSigned)

type SomeSigned' = (ConnId, Either ErrorType Cmd)

type Transmission' = (Signature, SomeSigned')

type RawTransmission = (String, String, String)

data Command (a :: Party) where
  CREATE :: RecipientKey -> Command Recipient
  SECURE :: SenderKey -> Command Recipient
  DELMSG :: MsgId -> Command Recipient
  SUB :: Command Recipient
  SUSPEND :: Command Recipient
  DELETE :: Command Recipient
  SEND :: MsgBody -> Command Sender
  MSG :: MsgId -> Timestamp -> MsgBody -> Command Broker
  CONN :: SenderId -> RecipientId -> Command Broker
  ERROR :: ErrorType -> Command Broker
  OK :: Command Broker

deriving instance Show (Command a)

mkTransmission :: Signature -> ConnId -> Either ErrorType Cmd -> Transmission'
mkTransmission signature connId cmd = (signature, (connId, cmd))

parseCommand :: String -> Either ErrorType Cmd
parseCommand command = case words command of
  ["CREATE", recipientKey] -> rCmd $ CREATE recipientKey
  ["SUB"] -> rCmd SUB
  ["SECURE", senderKey] -> rCmd $ SECURE senderKey
  ["DELMSG", msgId] -> rCmd $ DELMSG msgId
  ["SUSPEND"] -> rCmd SUSPEND
  ["DELETE"] -> rCmd DELETE
  ["SEND", msgBody] -> Right . smpSend $ B.pack msgBody
  ["MSG", msgId, timestamp, msgBody] -> bCmd $ MSG msgId timestamp (B.pack msgBody)
  ["CONN", rId, sId] -> bCmd $ CONN rId sId
  ["OK"] -> bCmd OK
  "ERROR" : err -> case err of
    ["SYNTAX", errCode] -> maybe errParams (bCmd . ERROR . SYNTAX) $ readMaybe errCode
    ["AUTH"] -> bCmd $ ERROR AUTH
    ["INTERNAL"] -> bCmd $ ERROR INTERNAL
    _ -> errParams
  "CREATE" : _ -> errParams
  "SUB" : _ -> errParams
  "SECURE" : _ -> errParams
  "DELMSG" : _ -> errParams
  "SUSPEND" : _ -> errParams
  "DELETE" : _ -> errParams
  "SEND" : _ -> errParams
  "MSG" : _ -> errParams
  "CONN" : _ -> errParams
  "OK" : _ -> errParams
  _ -> Left $ SYNTAX errUnknownCommand
  where
    errParams = Left $ SYNTAX errBadParameters
    rCmd = Right . Cmd SRecipient
    bCmd = Right . Cmd SBroker

serializeCommand :: Cmd -> String
serializeCommand = \case
  Cmd SRecipient (CREATE rKey) -> "CREATE " ++ rKey
  Cmd SRecipient (SECURE sKey) -> "SECURE " ++ sKey
  Cmd SRecipient (DELMSG msgId) -> "DELMSG " ++ msgId
  Cmd SRecipient cmd -> show cmd
  Cmd SSender (SEND msgBody) -> "SEND " ++ show (B.length msgBody) ++ "\n" ++ B.unpack msgBody
  Cmd SBroker (MSG msgId timestamp msgBody) ->
    "MSG " ++ msgId ++ " " ++ timestamp ++ " " ++ show (B.length msgBody) ++ "\n" ++ B.unpack msgBody
  Cmd SBroker (CONN rId sId) -> "CONN " ++ rId ++ " " ++ sId
  Cmd SBroker (ERROR err) -> "ERROR " ++ show err
  Cmd SBroker OK -> "OK"

syntaxError :: Int -> Cmd
syntaxError err = smpError $ SYNTAX err

smpError :: ErrorType -> Cmd
smpError errType = Cmd SBroker $ ERROR errType

smpSend :: MsgBody -> Cmd
smpSend = Cmd SSender . SEND

type Encoded = String

type PublicKey = Encoded

type Signature = Encoded

type RecipientKey = PublicKey

type SenderKey = PublicKey

type RecipientId = ConnId

type SenderId = ConnId

type ConnId = Encoded

type MsgId = Encoded

type Timestamp = Encoded

type MsgBody = B.ByteString

data ErrorType = SYNTAX Int | AUTH | INTERNAL deriving (Show)

errUnknownCommand :: Int
errUnknownCommand = 1

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

errMessageBodySize :: Int
errMessageBodySize = 7

errNotAllowed :: Int
errNotAllowed = 8
