{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Common where

import Data.ByteString.Char8 (ByteString)
import Data.String

type Encoded = ByteString

-- newtype to avoid accidentally changing order of transmission parts
newtype CorrId = CorrId {bs :: ByteString} deriving (Eq, Ord, Show)

instance IsString CorrId where
  fromString = CorrId . fromString

type PublicKey = Encoded

type PrivateKey = Encoded

type Signature = Encoded

type RecipientKey = PublicKey

type SenderKey = PublicKey

type RecipientId = QueueId

type SenderId = QueueId

type QueueId = Encoded

type MsgId = Encoded

type MsgBody = ByteString

data SMPErrorType = UNKNOWN | PROHIBITED | SYNTAX Int | SIZE | AUTH | INTERNAL | DUPLICATE deriving (Show, Eq)

errBadTransmission :: Int
errBadTransmission = 1

errBadParameters :: Int
errBadParameters = 2

errNoCredentials :: Int
errNoCredentials = 3

errHasCredentials :: Int
errHasCredentials = 4

errNoQueueId :: Int
errNoQueueId = 5

errMessageBody :: Int
errMessageBody = 6
