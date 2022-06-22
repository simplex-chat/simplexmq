{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Notifications.Server.Store where

import Control.Concurrent.STM
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (NtfPrivateSignKey)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))

data NtfStore = NtfStore
  { tokens :: TMap NtfTokenId NtfTknData,
    -- multiple registrations exist to protect from malicious registrations if token is compromised
    tokenRegistrations :: TMap DeviceToken (TMap ByteString NtfTokenId),
    subscriptions :: TMap NtfSubscriptionId NtfSubData,
    tokenSubscriptions :: TMap NtfTokenId (TVar (Set NtfSubscriptionId)),
    subscriptionLookup :: TMap SMPQueueNtf NtfSubscriptionId
  }

newNtfStore :: STM NtfStore
newNtfStore = do
  tokens <- TM.empty
  tokenRegistrations <- TM.empty
  subscriptions <- TM.empty
  tokenSubscriptions <- TM.empty
  subscriptionLookup <- TM.empty
  pure NtfStore {tokens, tokenRegistrations, subscriptions, tokenSubscriptions, subscriptionLookup}

data NtfTknData = NtfTknData
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: TVar NtfTknStatus,
    tknVerifyKey :: C.APublicVerifyKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode
  }

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.KeyPair 'C.X25519 -> C.DhSecretX25519 -> NtfRegCode -> STM NtfTknData
mkNtfTknData ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhKeys tknDhSecret tknRegCode = do
  tknStatus <- newTVar NTRegistered
  pure NtfTknData {ntfTknId, token, tknStatus, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode}

-- data NtfSubscriptionsStore = NtfSubscriptionsStore

-- { subscriptions :: TMap NtfSubsciptionId NtfSubsciption,
--   activeSubscriptions :: TMap (SMPServer, NotifierId) NtfSubsciptionId
-- }
-- do
-- subscriptions <- newTVar M.empty
-- activeSubscriptions <- newTVar M.empty
-- pure NtfSubscriptionsStore {subscriptions, activeSubscriptions}

data NtfSubData = NtfSubData
  { smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateSignKey,
    tokenId :: NtfTokenId,
    subStatus :: TVar NtfSubStatus
  }

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknData -> NtfEntityRec 'Token
  NtfSub :: NtfSubData -> NtfEntityRec 'Subscription

getNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe NtfTknData)
getNtfToken st tknId = TM.lookup tknId (tokens st)

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
      pure $ map snd tIds

deleteNtfToken :: NtfStore -> NtfTokenId -> STM ()
deleteNtfToken st tknId = do
  TM.lookupDelete tknId (tokens st)
    >>= mapM_
      ( \NtfTknData {token, tknVerifyKey} ->
          TM.lookup token regs
            >>= mapM_
              ( \tIds -> do
                  TM.delete (regKey tknVerifyKey) tIds
                  whenM (TM.null tIds) $ TM.delete token regs
              )
      )
  where
    regs = tokenRegistrations st
    regKey = C.toPubKey C.pubKeyBytes

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

mkNtfSubData :: NewNtfEntity 'Subscription -> STM NtfSubData
mkNtfSubData (NewNtfSub tokenId smpQueue notifierKey) = do
  subStatus <- newTVar NSNew
  pure NtfSubData {smpQueue, tokenId, subStatus, notifierKey}

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

-- getNtfRec :: NtfStore -> SNtfEntity e -> NtfEntityId -> STM (Maybe (NtfEntityRec e))
-- getNtfRec st ent entId = case ent of
--   SToken -> NtfTkn <$$> TM.lookup entId (tokens st)
--   SSubscription -> pure Nothing

-- getNtfVerifyKey :: NtfStore -> SNtfEntity e -> NtfEntityId -> STM (Maybe (NtfEntityRec e, C.APublicVerifyKey))
-- getNtfVerifyKey st ent entId =
--   getNtfRec st ent entId >>= \case
--     Just r@(NtfTkn NtfTknData {tknVerifyKey}) -> pure $ Just (r, tknVerifyKey)
--     Just r@(NtfSub NtfSubData {tokenId}) ->
--       getNtfRec st SToken tokenId >>= \case
--         Just (NtfTkn NtfTknData {tknVerifyKey}) -> pure $ Just (r, tknVerifyKey)
--         _ -> pure Nothing
--     _ -> pure Nothing

-- mkNtfSubsciption :: SMPQueueNtf -> NtfTokenId -> STM NtfSubsciption
-- mkNtfSubsciption smpQueue tokenId = do
--   subStatus <- newTVar NSNew
--   pure NtfSubsciption {smpQueue, tokenId, subStatus}

-- getNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> STM (Maybe NtfSubsciption)
-- getNtfSub st subId = pure Nothing -- maybe (pure $ Left AUTH) (fmap Right . readTVar) . M.lookup subId . subscriptions =<< readTVar st

-- getNtfSubViaSMPQueue :: NtfSubscriptionsStore -> SMPQueueNtf -> STM (Maybe NtfSubsciption)
-- getNtfSubViaSMPQueue st smpQueue = pure Nothing

-- -- replace keeping status
-- updateNtfSub :: NtfSubscriptionsStore -> NtfSubsciption -> SMPQueueNtf -> NtfTokenId -> C.DhSecretX25519 -> STM (Maybe ())
-- updateNtfSub st sub smpQueue tokenId dhSecret = pure Nothing

-- addNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> NtfSubsciption -> STM (Maybe ())
-- addNtfSub st subId sub = pure Nothing

-- deleteNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> STM ()
-- deleteNtfSub st subId = pure ()
