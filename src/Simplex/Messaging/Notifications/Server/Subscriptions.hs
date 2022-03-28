{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Notifications.Server.Subscriptions where

import Control.Concurrent.STM
import Crypto.PubKey.Curve25519 (dhSecret)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), NotifierId, NtfPrivateSignKey, SMPServer)
import Simplex.Messaging.TMap (TMap)

data NtfSubscriptionsStore = NtfSubscriptionsStore
  { subscriptions :: TMap NtfSubsciptionId NtfSubsciption,
    activeSubscriptions :: TMap (SMPServer, NotifierId) NtfSubsciptionId
  }

newNtfSubscriptionsStore :: STM NtfSubscriptionsStore
newNtfSubscriptionsStore = do
  subscriptions <- newTVar M.empty
  activeSubscriptions <- newTVar M.empty
  pure NtfSubscriptionsStore {subscriptions, activeSubscriptions}

data NtfSubsciption = NtfSubsciption
  { smpQueue :: SMPQueueNtf,
    token :: TVar DeviceToken,
    status :: TVar NtfStatus,
    subVerifyKey :: C.APublicVerifyKey,
    subDhSecret :: TVar C.DhSecretX25519
  }

mkNtfSubsciption :: SMPQueueNtf -> DeviceToken -> C.APublicVerifyKey -> C.DhSecretX25519 -> STM NtfSubsciption
mkNtfSubsciption smpQueue t subVerifyKey dh = do
  token <- newTVar t
  status <- newTVar NSNew
  subDhSecret <- newTVar dh
  pure NtfSubsciption {smpQueue, token, status, subVerifyKey, subDhSecret}

getNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> STM (Maybe NtfSubsciption)
getNtfSub st subId = pure Nothing -- maybe (pure $ Left AUTH) (fmap Right . readTVar) . M.lookup subId . subscriptions =<< readTVar st

getNtfSubViaSMPQueue :: NtfSubscriptionsStore -> SMPQueueNtf -> STM (Maybe NtfSubsciption)
getNtfSubViaSMPQueue st smpQueue = pure Nothing

-- replace keeping status
updateNtfSub :: NtfSubscriptionsStore -> NtfSubsciption -> NewNtfSubscription -> C.DhSecretX25519 -> STM (Maybe ())
updateNtfSub st sub newSub dhSecret = pure Nothing

addNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> NtfSubsciption -> STM (Maybe ())
addNtfSub st subId sub = pure Nothing

deleteNtfSub :: NtfSubscriptionsStore -> NtfSubsciptionId -> STM ()
deleteNtfSub st subId = pure ()
