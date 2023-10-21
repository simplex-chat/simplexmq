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
    readWriteNtfStore,
    logCreateToken,
    logTokenStatus,
    logUpdateToken,
    logTokenCron,
    logDeleteToken,
    logCreateSubscription,
    logSubscriptionStatus,
    logDeleteSubscription,
    closeStoreLog,
  )
where

import Control.Concurrent.STM
import Control.Monad
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Protocol (NtfPrivateSignKey)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (whenM)
import System.Directory (doesFileExist, renameFile)
import System.IO

data NtfStoreLogRecord
  = CreateToken NtfTknRec
  | TokenStatus NtfTokenId NtfTknStatus
  | UpdateToken NtfTokenId DeviceToken NtfRegCode
  | TokenCron NtfTokenId Word16
  | DeleteToken NtfTokenId
  | CreateSubscription NtfSubRec
  | SubscriptionStatus NtfSubscriptionId NtfSubStatus
  | DeleteSubscription NtfSubscriptionId

data NtfTknRec = NtfTknRec
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: NtfTknStatus,
    tknVerifyKey :: C.APublicVerifyKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: Word16
  }

mkTknData :: NtfTknRec -> STM NtfTknData
mkTknData NtfTknRec {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval = cronInt} = do
  tknStatus <- newTVar status
  tknCronInterval <- newTVar cronInt
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval}

mkTknRec :: NtfTknData -> STM NtfTknRec
mkTknRec NtfTknData {ntfTknId, token, tknStatus = status, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval = cronInt} = do
  tknStatus <- readTVar status
  tknCronInterval <- readTVar cronInt
  pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval}

data NtfSubRec = NtfSubRec
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateSignKey,
    tokenId :: NtfTokenId,
    subStatus :: NtfSubStatus
  }

mkSubData :: NtfSubRec -> STM NtfSubData
mkSubData NtfSubRec {ntfSubId, smpQueue, notifierKey, tokenId, subStatus = status} = do
  subStatus <- newTVar status
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
        "SCREATE " *> (CreateSubscription <$> strP),
        "SSTATUS " *> (SubscriptionStatus <$> strP_ <*> strP),
        "SDELETE " *> (DeleteSubscription <$> strP)
      ]

instance StrEncoding NtfTknRec where
  strEncode NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval} =
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
  strP = do
    ntfTknId <- "tknId=" *> strP_
    token <- "token=" *> strP_
    tknStatus <- "tokenStatus=" *> strP_
    tknVerifyKey <- "verifyKey=" *> strP_
    tknDhKeys <- "dhKeys=" *> strP_
    tknDhSecret <- "dhSecret=" *> strP_
    tknRegCode <- "regCode=" *> strP_
    tknCronInterval <- "cron=" *> strP
    pure NtfTknRec {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval}

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
logCreateToken s tkn = logNtfStoreRecord s . CreateToken =<< atomically (mkTknRec tkn)

logTokenStatus :: StoreLog 'WriteMode -> NtfTokenId -> NtfTknStatus -> IO ()
logTokenStatus s tknId tknStatus = logNtfStoreRecord s $ TokenStatus tknId tknStatus

logUpdateToken :: StoreLog 'WriteMode -> NtfTokenId -> DeviceToken -> NtfRegCode -> IO ()
logUpdateToken s tknId token regCode = logNtfStoreRecord s $ UpdateToken tknId token regCode

logTokenCron :: StoreLog 'WriteMode -> NtfTokenId -> Word16 -> IO ()
logTokenCron s tknId cronInt = logNtfStoreRecord s $ TokenCron tknId cronInt

logDeleteToken :: StoreLog 'WriteMode -> NtfTokenId -> IO ()
logDeleteToken s tknId = logNtfStoreRecord s $ DeleteToken tknId

logCreateSubscription :: StoreLog 'WriteMode -> NtfSubData -> IO ()
logCreateSubscription s sub = logNtfStoreRecord s . CreateSubscription =<< atomically (mkSubRec sub)

logSubscriptionStatus :: StoreLog 'WriteMode -> NtfSubscriptionId -> NtfSubStatus -> IO ()
logSubscriptionStatus s subId subStatus = logNtfStoreRecord s $ SubscriptionStatus subId subStatus

logDeleteSubscription :: StoreLog 'WriteMode -> NtfSubscriptionId -> IO ()
logDeleteSubscription s subId = logNtfStoreRecord s $ DeleteSubscription subId

readWriteNtfStore :: FilePath -> NtfStore -> IO (StoreLog 'WriteMode)
readWriteNtfStore f st = do
  whenM (doesFileExist f) $ do
    readNtfStore f st
    renameFile f $ f <> ".bak"
  s <- openWriteStoreLog f
  writeNtfStore s st
  pure s

readNtfStore :: FilePath -> NtfStore -> IO ()
readNtfStore f st = mapM_ addNtfLogRecord . B.lines =<< B.readFile f
  where
    addNtfLogRecord s = case strDecode s of
      Left e -> B.putStrLn $ "Log parsing error (" <> B.pack e <> "): " <> B.take 100 s
      Right lr -> atomically $ case lr of
        CreateToken r@NtfTknRec {ntfTknId} -> do
          tkn <- mkTknData r
          addNtfToken st ntfTknId tkn
        TokenStatus tknId status -> do
          tkn_ <- getNtfToken st tknId
          forM_ tkn_ $ \tkn@NtfTknData {tknStatus} -> do
            writeTVar tknStatus status
            when (status == NTActive) $ void $ removeInactiveTokenRegistrations st tkn
        UpdateToken tknId token' tknRegCode ->
          getNtfToken st tknId
            >>= mapM_
              ( \tkn@NtfTknData {tknStatus} -> do
                  removeTokenRegistration st tkn
                  writeTVar tknStatus NTRegistered
                  addNtfToken st tknId tkn {token = token', tknRegCode}
              )
        TokenCron tknId cronInt ->
          getNtfToken st tknId
            >>= mapM_ (\NtfTknData {tknCronInterval} -> writeTVar tknCronInterval cronInt)
        DeleteToken tknId ->
          void $ deleteNtfToken st tknId
        CreateSubscription r@NtfSubRec {ntfSubId} -> do
          sub <- mkSubData r
          void $ addNtfSubscription st ntfSubId sub
        SubscriptionStatus subId status ->
          getNtfSubscription st subId
            >>= mapM_ (\NtfSubData {subStatus} -> writeTVar subStatus status)
        DeleteSubscription subId ->
          deleteNtfSubscription st subId

writeNtfStore :: StoreLog 'WriteMode -> NtfStore -> IO ()
writeNtfStore s NtfStore {tokens, subscriptions} = do
  mapM_ (logCreateToken s) =<< readTVarIO tokens
  mapM_ (logCreateSubscription s) =<< readTVarIO subscriptions
