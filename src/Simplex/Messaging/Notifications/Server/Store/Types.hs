{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Server.Store.Types
  ( NtfTknRec (..),
    NtfSubRec (..),
    NtfAssociatedService,
    ServerNtfSub,
    mkTknData,
    mkTknRec,
    mkSubData,
    mkSubRec,
  )
where

import Control.Applicative (optional)
import Control.Concurrent.STM
import qualified Data.ByteString.Char8 as B
import Data.Maybe (fromMaybe)
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken, NtfRegCode, NtfSubStatus, NtfSubscriptionId, NtfTokenId, NtfTknStatus, SMPQueueNtf)
import Simplex.Messaging.Notifications.Server.Store (NtfSubData (..), NtfTknData (..))
import Simplex.Messaging.Protocol (NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey)
import Simplex.Messaging.SystemTime

data NtfTknRec = NtfTknRec
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhPrivKey :: C.PrivateKeyX25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: Word16,
    tknUpdatedAt :: Maybe SystemDate
  }
  deriving (Show)

mkTknData :: NtfTknRec -> IO NtfTknData
mkTknData NtfTknRec {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhPrivKey = pk, tknDhSecret, tknRegCode, tknCronInterval = cronInt, tknUpdatedAt = updatedAt} = do
  tknStatus <- newTVarIO status
  tknCronInterval <- newTVarIO cronInt
  tknUpdatedAt <- newTVarIO updatedAt
  let tknDhKeys = (C.publicKey pk, pk)
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

mkTknRec :: NtfTknData -> IO NtfTknRec
mkTknRec NtfTknData {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhKeys = (_, tknDhPrivKey), tknDhSecret, tknRegCode, tknCronInterval = cronInt, tknUpdatedAt = updatedAt} = do
  tknStatus <- readTVarIO status
  tknCronInterval <- readTVarIO cronInt
  tknUpdatedAt <- readTVarIO updatedAt
  pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

instance StrEncoding NtfTknRec where
  strEncode NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey = pk, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt} =
    B.unwords
      [ "tknId=" <> strEncode ntfTknId,
        "token=" <> strEncode token,
        "tokenStatus=" <> strEncode tknStatus,
        "verifyKey=" <> strEncode tknVerifyKey,
        "dhKeys=" <> strEncode (C.publicKey pk, pk),
        "dhSecret=" <> strEncode tknDhSecret,
        "regCode=" <> strEncode tknRegCode,
        "cron=" <> strEncode tknCronInterval
      ]
      <> maybe "" updatedAtStr tknUpdatedAt
    where
      updatedAtStr t = " updatedAt=" <> strEncode t
  strP = do
    ntfTknId <- "tknId=" *> strP_
    token <- "token=" *> strP_
    tknStatus <- "tokenStatus=" *> strP_
    tknVerifyKey <- "verifyKey=" *> strP_
    (_ :: C.PublicKeyX25519, tknDhPrivKey) <- "dhKeys=" *> strP_
    tknDhSecret <- "dhSecret=" *> strP_
    tknRegCode <- "regCode=" *> strP_
    tknCronInterval <- "cron=" *> strP
    tknUpdatedAt <- optional $ " updatedAt=" *> strP
    pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhPrivKey, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

data NtfSubRec = NtfSubRec
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    tokenId :: NtfTokenId,
    subStatus :: NtfSubStatus,
    ntfServiceAssoc :: NtfAssociatedService -- Bool
  }
  deriving (Show)

type ServerNtfSub = (NtfSubscriptionId, (NotifierId, NtfPrivateAuthKey))

type NtfAssociatedService = Bool

mkSubData :: NtfSubRec -> IO NtfSubData
mkSubData NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus = status, ntfServiceAssoc = serviceAssoc} = do
  subStatus <- newTVarIO status
  ntfServiceAssoc <- newTVarIO serviceAssoc
  pure NtfSubData {ntfSubId, smpQueue, notifierKey, tokenId, subStatus, ntfServiceAssoc}

mkSubRec :: NtfSubData -> IO NtfSubRec
mkSubRec NtfSubData {ntfSubId, smpQueue, notifierKey, tokenId, subStatus = status, ntfServiceAssoc = serviceAssoc} = do
  subStatus <- readTVarIO status
  ntfServiceAssoc <- readTVarIO serviceAssoc
  pure NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus, ntfServiceAssoc}

instance StrEncoding NtfSubRec where
  strEncode NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus, ntfServiceAssoc} =
    B.unwords
      [ "subId=" <> strEncode ntfSubId,
        "smpQueue=" <> strEncode smpQueue,
        "notifierKey=" <> strEncode notifierKey,
        "tknId=" <> strEncode tokenId,
        "subStatus=" <> strEncode subStatus,
        "serviceAssoc=" <> strEncode ntfServiceAssoc
      ]
  strP = do
    ntfSubId <- "subId=" *> strP_
    smpQueue <- "smpQueue=" *> strP_
    notifierKey <- "notifierKey=" *> strP_
    tokenId <- "tknId=" *> strP_
    subStatus <- "subStatus=" *> strP
    ntfServiceAssoc <- fromMaybe False <$> optional (" serviceAssoc=" *> strP)
    pure NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus, ntfServiceAssoc}
