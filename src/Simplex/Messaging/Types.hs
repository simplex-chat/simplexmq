{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module Simplex.Messaging.Types where

import Data.ByteString.Char8 (ByteString)
import Data.String
import qualified Simplex.Messaging.Crypto as C

type Encoded = ByteString

-- newtype to avoid accidentally changing order of transmission parts
newtype CorrId = CorrId {bs :: ByteString} deriving (Eq, Ord, Show)

instance IsString CorrId where
  fromString = CorrId . fromString

-- only used by Agent, kept here so its definition is close to respective public key
type RecipientPrivateKey = C.PrivateKey

type RecipientPublicKey = C.PublicKey

-- only used by Agent, kept here so its definition is close to respective public key
type SenderPrivateKey = C.PrivateKey

type SenderPublicKey = C.PublicKey

type MsgId = Encoded

type MsgBody = ByteString

data ErrorType = PROHIBITED | SYNTAX Int | SIZE | AUTH | INTERNAL | DUPLICATE deriving (Show, Eq)

errBadTransmission :: Int
errBadTransmission = 1

errBadSMPCommand :: Int
errBadSMPCommand = 2

errNoCredentials :: Int
errNoCredentials = 3

errHasCredentials :: Int
errHasCredentials = 4

errNoQueueId :: Int
errNoQueueId = 5

errMessageBody :: Int
errMessageBody = 6
