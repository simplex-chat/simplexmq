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
    logCreateTokenRec,
    logTokenStatus,
    logUpdateToken,
    logTokenCron,
    logDeleteToken,
    logUpdateTokenTime,
    logCreateSubscription,
    logCreateSubscriptionRec,
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
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime)
import Simplex.Messaging.Server.StoreLog
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

logNtfStoreRecord :: StoreLog 'WriteMode -> NtfStoreLogRecord -> IO ()
logNtfStoreRecord = writeStoreLogRecord
{-# INLINE logNtfStoreRecord #-}

logCreateToken :: StoreLog 'WriteMode -> NtfTknData -> IO ()
logCreateToken s tkn = logNtfStoreRecord s . CreateToken =<< mkTknRec tkn

logCreateTokenRec :: StoreLog 'WriteMode -> NtfTknRec -> IO ()
logCreateTokenRec s = logNtfStoreRecord s . CreateToken

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
logCreateSubscription s sub = logNtfStoreRecord s . CreateSubscription =<< mkSubRec sub

logCreateSubscriptionRec :: StoreLog 'WriteMode -> NtfSubRec -> IO ()
logCreateSubscriptionRec s = logNtfStoreRecord s . CreateSubscription

logSubscriptionStatus :: StoreLog 'WriteMode -> NtfSubscriptionId -> NtfSubStatus -> IO ()
logSubscriptionStatus s subId subStatus = logNtfStoreRecord s $ SubscriptionStatus subId subStatus

logDeleteSubscription :: StoreLog 'WriteMode -> NtfSubscriptionId -> IO ()
logDeleteSubscription s subId = logNtfStoreRecord s $ DeleteSubscription subId

readWriteNtfSTMStore :: Bool -> FilePath -> NtfSTMStore -> IO (StoreLog 'WriteMode)
readWriteNtfSTMStore tty = readWriteStoreLog (readNtfStore tty) writeNtfStore

readNtfStore :: Bool -> FilePath -> NtfSTMStore -> IO ()
readNtfStore tty f st = readLogLines tty f $ \_ -> processLine
  where
    processLine s = either printError procNtfLogRecord (strDecode s)
      where
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> B.take 100 s
        procNtfLogRecord = \case
          CreateToken r@NtfTknRec {ntfTknId} -> do
            tkn <- mkTknData r
            atomically $ stmAddNtfToken st ntfTknId tkn
          TokenStatus tknId status -> do
            tkn_ <- stmGetNtfTokenIO st tknId
            forM_ tkn_ $ \tkn@NtfTknData {tknStatus} -> do
              atomically $ writeTVar tknStatus status
              when (status == NTActive) $ void $ atomically $ stmRemoveInactiveTokenRegistrations st tkn
          UpdateToken tknId token' tknRegCode -> do
            stmGetNtfTokenIO st tknId
              >>= mapM_
                ( \tkn@NtfTknData {tknStatus} -> do
                    atomically $ stmRemoveTokenRegistration st tkn
                    atomically $ writeTVar tknStatus NTRegistered
                    atomically $ stmAddNtfToken st tknId tkn {token = token', tknRegCode}
                )
          TokenCron tknId cronInt ->
            stmGetNtfTokenIO st tknId
              >>= mapM_ (\NtfTknData {tknCronInterval} -> atomically $ writeTVar tknCronInterval cronInt)
          DeleteToken tknId ->
            atomically $ void $ stmDeleteNtfToken st tknId
          UpdateTokenTime tknId t ->
            stmGetNtfTokenIO st tknId
              >>= mapM_ (\NtfTknData {tknUpdatedAt} -> atomically $ writeTVar tknUpdatedAt $ Just t)
          CreateSubscription r@NtfSubRec {ntfSubId} -> do
            sub <- mkSubData r
            void $ atomically $ stmAddNtfSubscription st ntfSubId sub
          SubscriptionStatus subId status -> do
            stmGetNtfSubscriptionIO st subId
              >>= mapM_ (\NtfSubData {subStatus} -> atomically $ writeTVar subStatus status)
          DeleteSubscription subId ->
            atomically $ stmDeleteNtfSubscription st subId

writeNtfStore :: StoreLog 'WriteMode -> NtfSTMStore -> IO ()
writeNtfStore s NtfSTMStore {tokens, subscriptions} = do
  mapM_ (logCreateToken s) =<< readTVarIO tokens
  mapM_ (logCreateSubscription s) =<< readTVarIO subscriptions
