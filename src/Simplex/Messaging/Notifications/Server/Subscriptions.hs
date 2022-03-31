{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Notifications.Server.Subscriptions where

import Control.Concurrent.STM
import Control.Monad
import Crypto.PubKey.Curve25519 (dhSecret)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), NotifierId, NtfPrivateSignKey, SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util ((<$$>))

data NtfStore = NtfStore
  { tokens :: TMap NtfTokenId NtfTknData,
    tokenIds :: TMap DeviceToken NtfTokenId
  }

newNtfStore :: STM NtfStore
newNtfStore = do
  tokens <- TM.empty
  tokenIds <- TM.empty
  pure NtfStore {tokens, tokenIds}

data NtfTknData = NtfTknData
  { token :: DeviceToken,
    tknStatus :: TVar NtfTknStatus,
    tknVerifyKey :: C.APublicVerifyKey,
    tknDhSecret :: C.DhSecretX25519
  }

mkNtfTknData :: NewNtfEntity 'Token -> C.DhSecretX25519 -> STM NtfTknData
mkNtfTknData (NewNtfTkn token tknVerifyKey _) tknDhSecret = do
  tknStatus <- newTVar NTNew
  pure NtfTknData {token, tknStatus, tknVerifyKey, tknDhSecret}

data NtfSubscriptionsStore = NtfSubscriptionsStore

-- { subscriptions :: TMap NtfSubsciptionId NtfSubsciption,
--   activeSubscriptions :: TMap (SMPServer, NotifierId) NtfSubsciptionId
-- }
-- do
-- subscriptions <- newTVar M.empty
-- activeSubscriptions <- newTVar M.empty
-- pure NtfSubscriptionsStore {subscriptions, activeSubscriptions}

data NtfSubData = NtfSubData
  { smpQueue :: SMPQueueNtf,
    tokenId :: NtfTokenId,
    subStatus :: TVar NtfSubStatus
  }

data NtfEntityRec (e :: NtfEntity) where
  NtfTkn :: NtfTknData -> NtfEntityRec 'Token
  NtfSub :: NtfSubData -> NtfEntityRec 'Subscription

data ANtfEntityRec = forall e. NtfEntityI e => NER (SNtfEntity e) (NtfEntityRec e)

getNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe (NtfEntityRec 'Token))
getNtfToken st tknId = NtfTkn <$$> TM.lookup tknId (tokens st)

addNtfToken :: NtfStore -> NtfTokenId -> NtfTknData -> STM ()
addNtfToken st tknId tkn = pure ()

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
