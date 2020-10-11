{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

module Transport where

data Party = Broker | Recipient | Sender

type Transmission (a :: Party) = (Signed a, Signature)

type Signed (a :: Party) = (ConnId, Com a)

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

type Signature = Encoded

type RecipientKey = Encoded

type SenderKey = Encoded

type ConnId = Encoded

type SenderId = Encoded

type RecipientId = Encoded

type MsgId = Encoded

type Timestamp = Encoded

type MsgBody = Encoded

data ErrorType = CMD | SYNTAX | AUTH | INTERNAL
