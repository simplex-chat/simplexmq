{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
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

$( singletons
     [d|
       data Party = Broker | Recipient | Sender
         deriving (Show)
       |]
 )

type Transmission (a :: Party) = (Signed a, Maybe Signature)

type Signed (a :: Party) = (Maybe ConnId, Command a)

data Cmd where
  Cmd :: Sing a -> Command a -> Cmd

deriving instance Show Cmd

type SomeSigned = (Maybe ConnId, Cmd)

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

parseCommand :: String -> Cmd
parseCommand command = case words command of
  ["CREATE", recipientKey] -> rCmd $ CREATE recipientKey
  ["SUB"] -> rCmd SUB
  ["SECURE", senderKey] -> rCmd $ SECURE senderKey
  ["DELMSG", msgId] -> rCmd $ DELMSG msgId
  ["SUSPEND"] -> rCmd SUSPEND
  ["DELETE"] -> rCmd DELETE
  ["SEND", msgBody] -> smpSend $ B.pack msgBody
  "CREATE" : _ -> smpError SYNTAX
  "SUB" : _ -> smpError SYNTAX
  "SECURE" : _ -> smpError SYNTAX
  "DELMSG" : _ -> smpError SYNTAX
  "SUSPEND" : _ -> smpError SYNTAX
  "DELETE" : _ -> smpError SYNTAX
  "SEND" : _ -> smpError SYNTAX
  _ -> smpError CMD
  where
    rCmd = Cmd SRecipient

smpError :: ErrorType -> Cmd
smpError = Cmd SBroker . ERROR

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

data ErrorType = CMD | SYNTAX | AUTH | INTERNAL deriving (Show)
