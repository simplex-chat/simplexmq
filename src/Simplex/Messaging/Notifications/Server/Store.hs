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
{-# LANGUAGE StandaloneDeriving #-}

module Simplex.Messaging.Notifications.Server.Store where

import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..), (<|))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word16)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer)
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

data NtfSTMStore = NtfSTMStore
  { tokens :: TMap NtfTokenId NtfTknData,
    -- multiple registrations exist to protect from malicious registrations if token is compromised
    tokenRegistrations :: TMap DeviceToken (TMap ByteString NtfTokenId),
    subscriptions :: TMap NtfSubscriptionId NtfSubData,
    -- the first set is used to delete from `subscriptions` when token is deleted, the second - to cancel SMP subsriptions.
    -- TODO [notifications] it can be simplified once NtfSubData is fully removed.
    tokenSubscriptions :: TMap NtfTokenId (TMap SMPServer (TVar (Set NtfSubscriptionId), TVar (Set NotifierId))),
    -- TODO [notifications] for subscriptions that "migrated" to server subscription, we may replace NtfSubData with NtfTokenId here (Either NtfSubData NtfTokenId).
    subscriptionLookup :: TMap SMPServer (TMap NotifierId NtfSubData),
    tokenLastNtfs :: TMap NtfTokenId (TVar (NonEmpty PNMessageData))
  }

newNtfSTMStore :: IO NtfSTMStore
newNtfSTMStore = do
  tokens <- TM.emptyIO
  tokenRegistrations <- TM.emptyIO
  subscriptions <- TM.emptyIO
  tokenSubscriptions <- TM.emptyIO
  subscriptionLookup <- TM.emptyIO
  tokenLastNtfs <- TM.emptyIO
  pure NtfSTMStore {tokens, tokenRegistrations, subscriptions, tokenSubscriptions, subscriptionLookup, tokenLastNtfs}

data NtfTknData = NtfTknData
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: TVar NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: TVar Word16,
    tknUpdatedAt :: TVar (Maybe RoundedSystemTime)
  }

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.KeyPair 'C.X25519 -> C.DhSecretX25519 -> NtfRegCode -> RoundedSystemTime -> IO NtfTknData
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
    subStatus :: TVar NtfSubStatus
  }

ntfSubServer :: NtfSubData -> SMPServer
ntfSubServer NtfSubData {smpQueue = SMPQueueNtf {smpServer}} = smpServer

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknData -> NtfEntityRec 'Token
  NtfSub :: NtfSubData -> NtfEntityRec 'Subscription

getNtfToken :: NtfSTMStore -> NtfTokenId -> STM (Maybe NtfTknData)
getNtfToken st tknId = TM.lookup tknId (tokens st)

getNtfTokenIO :: NtfSTMStore -> NtfTokenId -> IO (Maybe NtfTknData)
getNtfTokenIO st tknId = TM.lookupIO tknId (tokens st)

addNtfToken :: NtfSTMStore -> NtfTokenId -> NtfTknData -> STM ()
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

getNtfTokenRegistration :: NtfSTMStore -> NewNtfEntity 'Token -> STM (Maybe NtfTknData)
getNtfTokenRegistration st (NewNtfTkn token tknVerifyKey _) =
  TM.lookup token (tokenRegistrations st)
    $>>= TM.lookup regKey
    $>>= (`TM.lookup` tokens st)
  where
    regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

removeInactiveTokenRegistrations :: NtfSTMStore -> NtfTknData -> STM [NtfTokenId]
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

removeTokenRegistration :: NtfSTMStore -> NtfTknData -> STM ()
removeTokenRegistration st NtfTknData {ntfTknId = tId, token, tknVerifyKey} =
  TM.lookup token (tokenRegistrations st) >>= mapM_ removeReg
  where
    removeReg regs =
      TM.lookup k regs
        >>= mapM_ (\tId' -> when (tId == tId') $ TM.delete k regs)
    k = C.toPubKey C.pubKeyBytes tknVerifyKey

deleteNtfToken :: NtfSTMStore -> NtfTokenId -> STM (Map SMPServer (Set NotifierId))
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

deleteTokenSubs :: NtfSTMStore -> NtfTokenId -> STM (Map SMPServer (Set NotifierId))
deleteTokenSubs st tknId =
  TM.lookupDelete tknId (tokenSubscriptions st)
    >>= maybe (pure M.empty) (readTVar >=> deleteSrvSubs)
  where
    deleteSrvSubs :: Map SMPServer (TVar (Set NtfSubscriptionId), TVar (Set NotifierId)) -> STM (Map SMPServer (Set NotifierId))
    deleteSrvSubs = M.traverseWithKey $ \smpServer (sVar, nVar) -> do
      sIds <- readTVar sVar
      modifyTVar' (subscriptions st) (`M.withoutKeys` sIds)
      nIds <- readTVar nVar
      TM.lookup smpServer (subscriptionLookup st) >>= mapM_ (`modifyTVar'` (`M.withoutKeys` nIds))
      pure nIds    

getNtfSubscriptionIO :: NtfSTMStore -> NtfSubscriptionId -> IO (Maybe NtfSubData)
getNtfSubscriptionIO st subId = TM.lookupIO subId (subscriptions st)

findNtfSubscription :: NtfSTMStore -> SMPQueueNtf -> STM (Maybe NtfSubData)
findNtfSubscription st SMPQueueNtf {smpServer, notifierId} =
  TM.lookup smpServer (subscriptionLookup st) $>>= TM.lookup notifierId 

findNtfSubscriptionToken :: NtfSTMStore -> SMPQueueNtf -> STM (Maybe NtfTknData)
findNtfSubscriptionToken st smpQueue = do
  findNtfSubscription st smpQueue
    $>>= \NtfSubData {tokenId} -> getActiveNtfToken st tokenId

getActiveNtfToken :: NtfSTMStore -> NtfTokenId -> STM (Maybe NtfTknData)
getActiveNtfToken st tknId =
  getNtfToken st tknId $>>= \tkn@NtfTknData {tknStatus} -> do
    tStatus <- readTVar tknStatus
    pure $ if tStatus == NTActive then Just tkn else Nothing

mkNtfSubData :: NtfSubscriptionId -> NewNtfEntity 'Subscription -> STM NtfSubData
mkNtfSubData ntfSubId (NewNtfSub tokenId smpQueue notifierKey) = do
  subStatus <- newTVar NSNew
  pure NtfSubData {ntfSubId, smpQueue, tokenId, subStatus, notifierKey}

-- returns False if subscription existed before
addNtfSubscription :: NtfSTMStore -> NtfSubscriptionId -> NtfSubData -> STM Bool
addNtfSubscription st subId sub@NtfSubData {smpQueue = SMPQueueNtf {smpServer, notifierId}, tokenId} =
  TM.lookup tokenId (tokenSubscriptions st)
    >>= maybe newTokenSubs pure
    >>= \ts -> TM.lookup smpServer ts
    >>= maybe (newTokenSrvSubs ts) pure
    >>= insertSub
  where
    newTokenSubs = do
      ts <- newTVar M.empty
      TM.insert tokenId ts $ tokenSubscriptions st
      pure ts
    newTokenSrvSubs ts = do
      tss <- (,) <$> newTVar S.empty <*> newTVar S.empty
      TM.insert smpServer tss ts
      pure tss
    insertSub  :: (TVar (Set NtfSubscriptionId), TVar (Set NotifierId)) -> STM Bool
    insertSub (sIds, nIds) = do
      modifyTVar' sIds $ S.insert subId
      modifyTVar' nIds $ S.insert notifierId
      TM.insert subId sub $ subscriptions st
      TM.lookup smpServer (subscriptionLookup st)
        >>= maybe newSubs pure
        >>= fmap isNothing . TM.lookupInsert notifierId sub
    newSubs = do
      ss <- newTVar M.empty
      TM.insert smpServer ss $ subscriptionLookup st
      pure ss

deleteNtfSubscription :: NtfSTMStore -> NtfSubscriptionId -> STM ()
deleteNtfSubscription st subId = TM.lookupDelete subId (subscriptions st) >>= mapM_ deleteSubIndices
  where
    deleteSubIndices NtfSubData {smpQueue = SMPQueueNtf {smpServer, notifierId}, tokenId} = do
      TM.lookup smpServer (subscriptionLookup st) >>= mapM_ (TM.delete notifierId)
      tss_ <- TM.lookup tokenId (tokenSubscriptions st) $>>= TM.lookup smpServer
      forM_ tss_ $ \(sIds, nIds) -> do
        modifyTVar' sIds $ S.delete subId
        modifyTVar' nIds $ S.delete notifierId

addTokenLastNtf :: NtfSTMStore -> NtfTokenId -> PNMessageData -> IO (NonEmpty PNMessageData)
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
            keepPrevNtf ntf@PNMessageData {smpQueue} ntfs
              | smpQueue /= newNtfQ && length ntfs < maxNtfs = ntf <| ntfs
              | otherwise = ntfs
        maxNtfs = 6

-- This function is expected to be called after store log is read,
-- as it checks for token existence when adding last notification.
storeTokenLastNtf :: NtfSTMStore -> NtfTokenId -> PNMessageData -> IO ()
storeTokenLastNtf (NtfSTMStore {tokens, tokenLastNtfs}) tknId ntf = do
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
