{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Notifications.Server.StoreLog
  ( StoreLog,
    NtfStoreLogRecord (..),
    readWriteNtfSTMStore,
    logCreateToken,
    logTokenStatus,
    logUpdateToken,
    logTokenCron,
    logDeleteToken,
    logUpdateTokenTime,
    logCreateSubscription,
    logSubscriptionStatus,
    logDeleteSubscription,
    closeStoreLog,
  )
where

import Control.Applicative (optional)
import Control.Concurrent.STM
import Control.Logger.Simple
import Control.Monad
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Data.Text as T
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Protocol (NtfPrivateAuthKey)
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (safeDecodeUtf8)
import System.IO

data NtfStoreLogRecord
  = CreateToken NtfTknRec
  | TokenStatus NtfTokenId NtfTknStatus
  | UpdateToken NtfTokenId DeviceToken NtfRegCode
  | TokenCron NtfTokenId Word16
  | DeleteToken NtfTokenId
  | UpdateTokenTime NtfTokenId RoundedSystemTime
  | CreateSubscription NtfSubRec
  | SubscriptionStatus NtfSubscriptionId NtfSubStatus
  | DeleteSubscription NtfSubscriptionId
  deriving (Show)

data NtfTknRec = NtfTknRec
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: NtfTknStatus,
    tknVerifyKey :: C.APublicAuthKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: Word16,
    tknUpdatedAt :: Maybe RoundedSystemTime
  }
  deriving (Show)

mkTknData :: NtfTknRec -> IO NtfTknData
mkTknData NtfTknRec {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval = cronInt, tknUpdatedAt = updatedAt} = do
  tknStatus <- newTVarIO status
  tknCronInterval <- newTVarIO cronInt
  tknUpdatedAt <- newTVarIO updatedAt
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

mkTknRec :: NtfTknData -> IO NtfTknRec
mkTknRec NtfTknData {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval = cronInt, tknUpdatedAt = updatedAt} = do
  tknStatus <- readTVarIO status
  tknCronInterval <- readTVarIO cronInt
  tknUpdatedAt <- readTVarIO updatedAt
  pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

data NtfSubRec = NtfSubRec
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    tokenId :: NtfTokenId,
    subStatus :: NtfSubStatus
  }
  deriving (Show)

mkSubData :: NtfSubRec -> IO NtfSubData
mkSubData NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus = status} = do
  subStatus <- newTVarIO status
  pure NtfSubData {ntfSubId, smpQueue, notifierKey, tokenId, subStatus}

mkSubRec :: NtfSubData -> STM NtfSubRec
mkSubRec NtfSubData {ntfSubId, smpQueue, notifierKey, tokenId, subStatus = status} = do
  subStatus <- readTVar status
  pure NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus}

instance StrEncoding NtfStoreLogRecord where
  strEncode = \case
    CreateToken tknRec -> strEncode (Str "TCREATE", tknRec)
    TokenStatus tknId tknStatus -> strEncode (Str "TSTATUS", tknId, tknStatus)
    UpdateToken tknId token regCode -> strEncode (Str "TUPDATE", tknId, token, regCode)
    TokenCron tknId cronInt -> strEncode (Str "TCRON", tknId, cronInt)
    DeleteToken tknId -> strEncode (Str "TDELETE", tknId)
    UpdateTokenTime tknId ts -> strEncode (Str "TTIME", tknId, ts)
    CreateSubscription subRec -> strEncode (Str "SCREATE", subRec)
    SubscriptionStatus subId subStatus -> strEncode (Str "SSTATUS", subId, subStatus)
    DeleteSubscription subId -> strEncode (Str "SDELETE", subId)
  strP =
    A.choice
      [ "TCREATE " *> (CreateToken <$> strP),
        "TSTATUS " *> (TokenStatus <$> strP_ <*> strP),
        "TUPDATE " *> (UpdateToken <$> strP_ <*> strP_ <*> strP),
        "TCRON " *> (TokenCron <$> strP_ <*> strP),
        "TDELETE " *> (DeleteToken <$> strP),
        "TTIME " *> (UpdateTokenTime <$> strP_ <*> strP),
        "SCREATE " *> (CreateSubscription <$> strP),
        "SSTATUS " *> (SubscriptionStatus <$> strP_ <*> strP),
        "SDELETE " *> (DeleteSubscription <$> strP)
      ]

instance StrEncoding NtfTknRec where
  strEncode NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt} =
    B.unwords
      [ "tknId=" <> strEncode ntfTknId,
        "token=" <> strEncode token,
        "tokenStatus=" <> strEncode tknStatus,
        "verifyKey=" <> strEncode tknVerifyKey,
        "dhKeys=" <> strEncode tknDhKeys,
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
    tknDhKeys <- "dhKeys=" *> strP_
    tknDhSecret <- "dhSecret=" *> strP_
    tknRegCode <- "regCode=" *> strP_
    tknCronInterval <- "cron=" *> strP
    tknUpdatedAt <- optional $ " updatedAt=" *> strP
    pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

instance StrEncoding NtfSubRec where
  strEncode NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus} =
    B.unwords
      [ "subId=" <> strEncode ntfSubId,
        "smpQueue=" <> strEncode smpQueue,
        "notifierKey=" <> strEncode notifierKey,
        "tknId=" <> strEncode tokenId,
        "subStatus=" <> strEncode subStatus
      ]
  strP = do
    ntfSubId <- "subId=" *> strP_
    smpQueue <- "smpQueue=" *> strP_
    notifierKey <- "notifierKey=" *> strP_
    tokenId <- "tknId=" *> strP_
    subStatus <- "subStatus=" *> strP
    pure NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus}

logNtfStoreRecord :: StoreLog 'WriteMode -> NtfStoreLogRecord -> IO ()
logNtfStoreRecord = writeStoreLogRecord
{-# INLINE logNtfStoreRecord #-}

logCreateToken :: StoreLog 'WriteMode -> NtfTknData -> IO ()
logCreateToken s tkn = logNtfStoreRecord s . CreateToken =<< mkTknRec tkn

logTokenStatus :: StoreLog 'WriteMode -> NtfTokenId -> NtfTknStatus -> IO ()
logTokenStatus s tknId tknStatus = logNtfStoreRecord s $ TokenStatus tknId tknStatus

logUpdateToken :: StoreLog 'WriteMode -> NtfTokenId -> DeviceToken -> NtfRegCode -> IO ()
logUpdateToken s tknId token regCode = logNtfStoreRecord s $ UpdateToken tknId token regCode

logTokenCron :: StoreLog 'WriteMode -> NtfTokenId -> Word16 -> IO ()
logTokenCron s tknId cronInt = logNtfStoreRecord s $ TokenCron tknId cronInt

logDeleteToken :: StoreLog 'WriteMode -> NtfTokenId -> IO ()
logDeleteToken s tknId = logNtfStoreRecord s $ DeleteToken tknId

logUpdateTokenTime :: StoreLog 'WriteMode -> NtfTokenId -> RoundedSystemTime -> IO ()
logUpdateTokenTime s tknId t = logNtfStoreRecord s $ UpdateTokenTime tknId t

logCreateSubscription :: StoreLog 'WriteMode -> NtfSubData -> IO ()
logCreateSubscription s sub = logNtfStoreRecord s . CreateSubscription =<< atomically (mkSubRec sub)

logSubscriptionStatus :: StoreLog 'WriteMode -> NtfSubscriptionId -> NtfSubStatus -> IO ()
logSubscriptionStatus s subId subStatus = logNtfStoreRecord s $ SubscriptionStatus subId subStatus

logDeleteSubscription :: StoreLog 'WriteMode -> NtfSubscriptionId -> IO ()
logDeleteSubscription s subId = logNtfStoreRecord s $ DeleteSubscription subId

readWriteNtfSTMStore :: FilePath -> NtfSTMStore -> IO (StoreLog 'WriteMode)
readWriteNtfSTMStore = readWriteStoreLog readNtfStore writeNtfStore

-- TODO [ntfdb] there is no need to read into lookup indices, and the functions and NtfSMPStore type can be moved here
readNtfStore :: FilePath -> NtfSTMStore -> IO ()
readNtfStore f st = mapM_ (addNtfLogRecord . LB.toStrict) . LB.lines =<< LB.readFile f
  where
    addNtfLogRecord s = case strDecode s of
      Left e -> logError $ "Log parsing error (" <> T.pack e <> "): " <> safeDecodeUtf8 (B.take 100 s)
      Right lr -> case lr of
        CreateToken r@NtfTknRec {ntfTknId} -> do
          tkn <- mkTknData r
          atomically $ addNtfToken st ntfTknId tkn
        TokenStatus tknId status -> do
          tkn_ <- getNtfTokenIO st tknId
          forM_ tkn_ $ \tkn@NtfTknData {tknStatus} -> do
            atomically $ writeTVar tknStatus status
            when (status == NTActive) $ void $ atomically $ removeInactiveTokenRegistrations st tkn
        UpdateToken tknId token' tknRegCode -> do
          getNtfTokenIO st tknId
            >>= mapM_
              ( \tkn@NtfTknData {tknStatus} -> do
                  atomically $ removeTokenRegistration st tkn
                  atomically $ writeTVar tknStatus NTRegistered
                  atomically $ addNtfToken st tknId tkn {token = token', tknRegCode}
              )
        TokenCron tknId cronInt ->
          getNtfTokenIO st tknId
            >>= mapM_ (\NtfTknData {tknCronInterval} -> atomically $ writeTVar tknCronInterval cronInt)
        DeleteToken tknId ->
          atomically $ void $ deleteNtfToken st tknId
        UpdateTokenTime tknId t ->
          getNtfTokenIO st tknId
            >>= mapM_ (\NtfTknData {tknUpdatedAt} -> atomically $ writeTVar tknUpdatedAt $ Just t)
        CreateSubscription r@NtfSubRec {ntfSubId} -> do
          sub <- mkSubData r
          void $ atomically $ addNtfSubscription st ntfSubId sub
        SubscriptionStatus subId status -> do
          getNtfSubscriptionIO st subId
            >>= mapM_ (\NtfSubData {subStatus} -> atomically $ writeTVar subStatus status)
        DeleteSubscription subId ->
          atomically $ deleteNtfSubscription st subId

writeNtfStore :: StoreLog 'WriteMode -> NtfSTMStore -> IO ()
writeNtfStore s NtfSTMStore {tokens, subscriptions} = do
  mapM_ (logCreateToken s) =<< readTVarIO tokens
  mapM_ (logCreateSubscription s) =<< readTVarIO subscriptions
