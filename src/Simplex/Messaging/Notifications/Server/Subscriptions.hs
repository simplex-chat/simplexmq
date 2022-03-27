module Simplex.Messaging.Notifications.Server.Subscriptions where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), NotifierId, NtfPrivateSignKey, SMPServer)

type NtfSubscriptionsData = Map NtfSubsciptionId NtfSubsciptionRec

type NtfSubscriptions = TVar NtfSubscriptionsData

data NtfSubsciptionRec = NtfSubsciptionRec
  { smpServer :: SMPServer,
    notifierId :: NotifierId,
    notifierKey :: NtfPrivateSignKey,
    token :: DeviceToken,
    status :: TVar NtfStatus,
    subVerifyKey :: C.APublicVerifyKey,
    subDHSecret :: C.DhSecretX25519
  }

getNtfSubscription :: NtfSubscriptions -> NtfSubsciptionId -> STM (Either ErrorType NtfSubsciptionRec)
getNtfSubscription st subId = maybe (Left AUTH) Right . M.lookup subId <$> readTVar st
