{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Transmission where

import Data.Singletons.TH

$( singletons
     [d|
       data Party = Broker | Recipient | Sender
       |]
 )

type Transmission (a :: Party) = (Signed a, Maybe Signature)

type Signed (a :: Party) = (Maybe ConnId, Com a)

data SomeCom where
  SomeCom :: Sing a -> Com a -> SomeCom

type SomeSigned = (Maybe ConnId, SomeCom)

data Com (a :: Party) where
  CREATE :: RecipientKey -> Com Recipient
  SECURE :: SenderKey -> Com Recipient
  DELMSG :: MsgId -> Com Recipient
  SUB :: Com Recipient
  SUSPEND :: Com Recipient
  DELETE :: Com Recipient
  SEND :: MsgBody -> Com Sender
  MSG :: MsgId -> Timestamp -> MsgBody -> Com Broker
  CONN :: SenderId -> RecipientId -> Com Broker
  ERROR :: ErrorType -> Com Broker
  OK :: Com Broker

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

type MsgBody = Encoded

data ErrorType = CMD | SYNTAX | AUTH | INTERNAL deriving (Show)
