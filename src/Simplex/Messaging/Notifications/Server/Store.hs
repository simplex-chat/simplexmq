{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Server.Store
  ( NtfSTMStore (..),
    NtfTknData (..),
    NtfSubData (..),
    TokenNtfMessageRecord (..),
    newNtfSTMStore,
    mkNtfTknData,
    ntfSubServer,
    stmGetNtfTokenIO,
    stmAddNtfToken,
    stmRemoveInactiveTokenRegistrations,
    stmRemoveTokenRegistration,
    stmDeleteNtfToken,
    stmGetNtfSubscriptionIO,
    stmAddNtfSubscription,
    stmDeleteNtfSubscription,
    stmStoreTokenLastNtf,
    stmSetNtfService,
  )
where

import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer, ServiceId)
import Simplex.Messaging.SystemTime
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

data NtfSTMStore = NtfSTMStore
  { tokens :: TMap NtfTokenId NtfTknData,
    -- multiple registrations exist to protect from malicious registrations if token is compromised
    tokenRegistrations :: TMap DeviceToken (TMap ByteString NtfTokenId),
    subscriptions :: TMap NtfSubscriptionId NtfSubData,
    tokenSubscriptions :: TMap NtfTokenId (TVar (Set NtfSubscriptionId)),
    subscriptionLookup :: TMap SMPQueueNtf NtfSubscriptionId,
    tokenLastNtfs :: TMap NtfTokenId (TVar (NonEmpty PNMessageData)),
    ntfServices :: TMap SMPServer ServiceId
  }

newNtfSTMStore :: IO NtfSTMStore
newNtfSTMStore = do
  tokens <- TM.emptyIO
  tokenRegistrations <- TM.emptyIO
  subscriptions <- TM.emptyIO
  tokenSubscriptions <- TM.emptyIO
  subscriptionLookup <- TM.emptyIO
  tokenLastNtfs <- TM.emptyIO
  ntfServices <- TM.emptyIO
  pure NtfSTMStore {tokens, tokenRegistrations, subscriptions, tokenSubscriptions, subscriptionLookup, tokenLastNtfs, ntfServices}

data NtfTknData = NtfTknData
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: TVar NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhKeys :: C.KeyPairX25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: TVar Word16,
    tknUpdatedAt :: TVar (Maybe SystemDate)
  }

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.KeyPairX25519 -> C.DhSecretX25519 -> NtfRegCode -> SystemDate -> IO NtfTknData
mkNtfTknData ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhKeys tknDhSecret tknRegCode ts = do
  tknStatus <- newTVarIO NTRegistered
  tknCronInterval <- newTVarIO 0
  tknUpdatedAt <- newTVarIO $ Just ts
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval, tknUpdatedAt}

data NtfSubData = NtfSubData
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    tokenId :: NtfTokenId,
    subStatus :: TVar NtfSubStatus,
    ntfServiceAssoc :: TVar Bool
  }

ntfSubServer :: NtfSubData -> SMPServer
ntfSubServer NtfSubData {smpQueue = SMPQueueNtf {smpServer}} = smpServer

stmGetNtfTokenIO :: NtfSTMStore -> NtfTokenId -> IO (Maybe NtfTknData)
stmGetNtfTokenIO st tknId = TM.lookupIO tknId (tokens st)

stmAddNtfToken :: NtfSTMStore -> NtfTokenId -> NtfTknData -> STM ()
stmAddNtfToken st tknId tkn@NtfTknData {token, tknVerifyKey} = do
  TM.insert tknId tkn $ tokens st
  TM.lookup token regs >>= \case
    Just tIds -> TM.insert regKey tknId tIds
    _ -> do
      tIds <- TM.singleton regKey tknId
      TM.insert token tIds regs
  where
    regs = tokenRegistrations st
    regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

stmRemoveInactiveTokenRegistrations :: NtfSTMStore -> NtfTknData -> STM [NtfTokenId]
stmRemoveInactiveTokenRegistrations st NtfTknData {ntfTknId = tId, token} =
  TM.lookup token (tokenRegistrations st)
    >>= maybe (pure []) removeRegs
  where
    removeRegs :: TMap ByteString NtfTokenId -> STM [NtfTokenId]
    removeRegs tknRegs = do
      tIds <- filter ((/= tId) . snd) . M.assocs <$> readTVar tknRegs
      forM_ tIds $ \(regKey, tId') -> do
        TM.delete regKey tknRegs
        TM.delete tId' $ tokens st
        TM.delete tId' $ tokenLastNtfs st
        void $ deleteTokenSubs st tId'
      pure $ map snd tIds

stmRemoveTokenRegistration :: NtfSTMStore -> NtfTknData -> STM ()
stmRemoveTokenRegistration st NtfTknData {ntfTknId = tId, token, tknVerifyKey} =
  TM.lookup token (tokenRegistrations st) >>= mapM_ removeReg
  where
    removeReg regs =
      TM.lookup k regs
        >>= mapM_ (\tId' -> when (tId == tId') $ TM.delete k regs)
    k = C.toPubKey C.pubKeyBytes tknVerifyKey

stmDeleteNtfToken :: NtfSTMStore -> NtfTokenId -> STM [SMPQueueNtf]
stmDeleteNtfToken st tknId = do
  void $
    TM.lookupDelete tknId (tokens st) $>>= \NtfTknData {token, tknVerifyKey} ->
      TM.lookup token regs $>>= \tIds ->
        TM.delete (regKey tknVerifyKey) tIds
          >> whenM (TM.null tIds) (TM.delete token regs) $> Just ()
  TM.delete tknId $ tokenLastNtfs st
  deleteTokenSubs st tknId
  where
    regs = tokenRegistrations st
    regKey = C.toPubKey C.pubKeyBytes

deleteTokenSubs :: NtfSTMStore -> NtfTokenId -> STM [SMPQueueNtf]
deleteTokenSubs st tknId = do
  qs <-
    TM.lookupDelete tknId (tokenSubscriptions st)
      >>= mapM (readTVar >=> mapM deleteSub . S.toList)
  pure $ maybe [] catMaybes qs
  where
    deleteSub subId = do
      TM.lookupDelete subId (subscriptions st)
        $>>= \NtfSubData {smpQueue} ->
          TM.delete smpQueue (subscriptionLookup st) $> Just smpQueue

stmGetNtfSubscriptionIO :: NtfSTMStore -> NtfSubscriptionId -> IO (Maybe NtfSubData)
stmGetNtfSubscriptionIO st subId = TM.lookupIO subId (subscriptions st)

stmAddNtfSubscription :: NtfSTMStore -> NtfSubscriptionId -> NtfSubData -> STM (Maybe ())
stmAddNtfSubscription st subId sub@NtfSubData {smpQueue, tokenId} =
  TM.lookup tokenId (tokenSubscriptions st) >>= maybe newTokenSub pure >>= insertSub
  where
    newTokenSub = do
      ts <- newTVar S.empty
      TM.insert tokenId ts $ tokenSubscriptions st
      pure ts
    insertSub ts = do
      modifyTVar' ts $ S.insert subId
      TM.insert subId sub $ subscriptions st
      TM.insert smpQueue subId (subscriptionLookup st)
      -- return Nothing if subscription existed before
      pure $ Just ()

stmDeleteNtfSubscription :: NtfSTMStore -> NtfSubscriptionId -> STM ()
stmDeleteNtfSubscription st subId = do
  TM.lookupDelete subId (subscriptions st)
    >>= mapM_
      ( \NtfSubData {smpQueue, tokenId} -> do
          TM.delete smpQueue $ subscriptionLookup st
          ts_ <- TM.lookup tokenId (tokenSubscriptions st)
          forM_ ts_ $ \ts -> modifyTVar' ts $ S.delete subId
      )

-- This function is expected to be called after store log is read,
-- as it checks for token existence when adding last notification.
stmStoreTokenLastNtf :: NtfSTMStore -> NtfTokenId -> PNMessageData -> IO ()
stmStoreTokenLastNtf (NtfSTMStore {tokens, tokenLastNtfs}) tknId ntf = do
  TM.lookupIO tknId tokenLastNtfs >>= atomically . maybe newTokenLastNtfs (`modifyTVar'` (ntf <|))
  where
    newTokenLastNtfs = TM.lookup tknId tokenLastNtfs >>= maybe insertForExistingToken (`modifyTVar'` (ntf <|))
    insertForExistingToken =
      whenM (TM.member tknId tokens) $
        TM.insertM tknId (newTVar [ntf]) tokenLastNtfs

stmSetNtfService :: NtfSTMStore -> SMPServer -> Maybe ServiceId -> STM ()
stmSetNtfService (NtfSTMStore {ntfServices}) srv serviceId =
  maybe (TM.delete srv) (TM.insert srv) serviceId ntfServices

data TokenNtfMessageRecord = TNMRv1 NtfTokenId PNMessageData

instance StrEncoding TokenNtfMessageRecord where
  strEncode (TNMRv1 tknId ntf) = strEncode (Str "v1", tknId, ntf)
  strP = "v1 " *> (TNMRv1 <$> strP_ <*> strP)
