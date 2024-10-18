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

module Simplex.Messaging.Notifications.Server.Store where

import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

data NtfStore = NtfStore
  { tokens :: TMap NtfTokenId NtfTknData,
    -- multiple registrations exist to protect from malicious registrations if token is compromised
    tokenRegistrations :: TMap DeviceToken (TMap ByteString NtfTokenId),
    subscriptions :: TMap NtfSubscriptionId NtfSubData,
    tokenSubscriptions :: TMap NtfTokenId (TVar (Set NtfSubscriptionId)),
    subscriptionLookup :: TMap SMPQueueNtf NtfSubscriptionId,
    tokenLastNtfs :: TMap NtfTokenId (TVar (NonEmpty PNMessageData))
  }

newNtfStore :: IO NtfStore
newNtfStore = do
  tokens <- TM.emptyIO
  tokenRegistrations <- TM.emptyIO
  subscriptions <- TM.emptyIO
  tokenSubscriptions <- TM.emptyIO
  subscriptionLookup <- TM.emptyIO
  tokenLastNtfs <- TM.emptyIO
  pure NtfStore {tokens, tokenRegistrations, subscriptions, tokenSubscriptions, subscriptionLookup, tokenLastNtfs}

data NtfTknData = NtfTknData
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: TVar NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: TVar Word16
  }

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.KeyPair 'C.X25519 -> C.DhSecretX25519 -> NtfRegCode -> STM NtfTknData
mkNtfTknData ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhKeys tknDhSecret tknRegCode = do
  tknStatus <- newTVar NTRegistered
  tknCronInterval <- newTVar 0
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval}

data NtfSubData = NtfSubData
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    tokenId :: NtfTokenId,
    subStatus :: TVar NtfSubStatus
  }

ntfSubServer :: NtfSubData -> SMPServer
ntfSubServer NtfSubData {smpQueue = SMPQueueNtf {smpServer}} = smpServer

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknData -> NtfEntityRec 'Token
  NtfSub :: NtfSubData -> NtfEntityRec 'Subscription

getNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe NtfTknData)
getNtfToken st tknId = TM.lookup tknId (tokens st)

getNtfTokenIO :: NtfStore -> NtfTokenId -> IO (Maybe NtfTknData)
getNtfTokenIO st tknId = TM.lookupIO tknId (tokens st)

addNtfToken :: NtfStore -> NtfTokenId -> NtfTknData -> STM ()
addNtfToken st tknId tkn@NtfTknData {token, tknVerifyKey} = do
  TM.insert tknId tkn $ tokens st
  TM.lookup token regs >>= \case
    Just tIds -> TM.insert regKey tknId tIds
    _ -> do
      tIds <- TM.singleton regKey tknId
      TM.insert token tIds regs
  where
    regs = tokenRegistrations st
    regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

getNtfTokenRegistration :: NtfStore -> NewNtfEntity 'Token -> STM (Maybe NtfTknData)
getNtfTokenRegistration st (NewNtfTkn token tknVerifyKey _) =
  TM.lookup token (tokenRegistrations st)
    $>>= TM.lookup regKey
    $>>= (`TM.lookup` tokens st)
  where
    regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

removeInactiveTokenRegistrations :: NtfStore -> NtfTknData -> STM [NtfTokenId]
removeInactiveTokenRegistrations st NtfTknData {ntfTknId = tId, token} =
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

removeTokenRegistration :: NtfStore -> NtfTknData -> STM ()
removeTokenRegistration st NtfTknData {ntfTknId = tId, token, tknVerifyKey} =
  TM.lookup token (tokenRegistrations st) >>= mapM_ removeReg
  where
    removeReg regs =
      TM.lookup k regs
        >>= mapM_ (\tId' -> when (tId == tId') $ TM.delete k regs)
    k = C.toPubKey C.pubKeyBytes tknVerifyKey

deleteNtfToken :: NtfStore -> NtfTokenId -> STM [SMPQueueNtf]
deleteNtfToken st tknId = do
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

deleteTokenSubs :: NtfStore -> NtfTokenId -> STM [SMPQueueNtf]
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

getNtfSubscription :: NtfStore -> NtfSubscriptionId -> STM (Maybe NtfSubData)
getNtfSubscription st subId =
  TM.lookup subId (subscriptions st)

findNtfSubscription :: NtfStore -> SMPQueueNtf -> STM (Maybe NtfSubData)
findNtfSubscription st smpQueue = do
  TM.lookup smpQueue (subscriptionLookup st)
    $>>= \subId -> TM.lookup subId (subscriptions st)

findNtfSubscriptionToken :: NtfStore -> SMPQueueNtf -> STM (Maybe NtfTknData)
findNtfSubscriptionToken st smpQueue = do
  findNtfSubscription st smpQueue
    $>>= \NtfSubData {tokenId} -> getActiveNtfToken st tokenId

getActiveNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe NtfTknData)
getActiveNtfToken st tknId =
  getNtfToken st tknId $>>= \tkn@NtfTknData {tknStatus} -> do
    tStatus <- readTVar tknStatus
    pure $ if tStatus == NTActive then Just tkn else Nothing

mkNtfSubData :: NtfSubscriptionId -> NewNtfEntity 'Subscription -> STM NtfSubData
mkNtfSubData ntfSubId (NewNtfSub tokenId smpQueue notifierKey) = do
  subStatus <- newTVar NSNew
  pure NtfSubData {ntfSubId, smpQueue, tokenId, subStatus, notifierKey}

addNtfSubscription :: NtfStore -> NtfSubscriptionId -> NtfSubData -> STM (Maybe ())
addNtfSubscription st subId sub@NtfSubData {smpQueue, tokenId} =
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

deleteNtfSubscription :: NtfStore -> NtfSubscriptionId -> STM ()
deleteNtfSubscription st subId = do
  TM.lookupDelete subId (subscriptions st)
    >>= mapM_
      ( \NtfSubData {smpQueue, tokenId} -> do
          TM.delete smpQueue $ subscriptionLookup st
          ts_ <- TM.lookup tokenId (tokenSubscriptions st)
          forM_ ts_ $ \ts -> modifyTVar' ts $ S.delete subId
      )

addTokenLastNtf :: NtfStore -> NtfTokenId -> PNMessageData -> IO (NonEmpty PNMessageData)
addTokenLastNtf st tknId newNtf =
  TM.lookupIO tknId (tokenLastNtfs st) >>= maybe (atomically maybeNewTokenLastNtfs) (atomically . addNtf)
  where
    maybeNewTokenLastNtfs =
      TM.lookup tknId (tokenLastNtfs st) >>= maybe newTokenLastNtfs addNtf
    newTokenLastNtfs = do
      v <- newTVar [newNtf]
      TM.insert tknId v $ tokenLastNtfs st
      pure [newNtf]
    addNtf v =
      stateTVar v $ \ntfs -> let !ntfs' = rebuildList ntfs in (ntfs', ntfs')
      where
        rebuildList :: NonEmpty PNMessageData -> NonEmpty PNMessageData
        rebuildList = foldr keepPrevNtf [newNtf]
          where
            PNMessageData {smpQueue = newNtfQ} = newNtf
            keepPrevNtf PNMessageData {smpQueue} ntfs
              | smpQueue /= newNtfQ && length ntfs < maxNtfs = ntf : ntfs
              | otherwise = ntfs
        maxNtfs = 6

-- This function is expected to be called after store log is read,
-- as it checks for token existence when adding last notification.
storeTokenLastNtf :: NtfStore -> NtfTokenId -> PNMessageData -> IO ()
storeTokenLastNtf (NtfStore {tokens, tokenLastNtfs}) tknId ntf = do
  TM.lookupIO tknId tokenLastNtfs >>= atomically . maybe newTokenLastNtfs (`modifyTVar'` (ntf <|))
  where
    newTokenLastNtfs = TM.lookup tknId tokenLastNtfs >>= maybe insertForExistingToken (`modifyTVar'` (ntf <|))
    insertForExistingToken =
      whenM (TM.member tknId tokens) $
        TM.insertM tknId (newTVar [ntf]) tokenLastNtfs

data TokenNtfMessageRecord = TNMRv1 NtfTokenId PNMessageData

instance StrEncoding TokenNtfMessageRecord where
  strEncode (TNMRv1 tknId ntf) = strEncode (Str "v1", tknId, ntf)
  strP = "v1 " *> (TNMRv1 <$> strP_ <*> strP)
