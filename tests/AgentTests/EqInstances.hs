{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module AgentTests.EqInstances where

import Data.Type.Equality
import Simplex.Messaging.Agent.Protocol (ConnLinkData (..), OwnerAuth (..), UserLinkData (..))
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client (ProxiedRelay (..))

instance (Eq rq, Eq sq) => Eq (SomeConn' rq sq) where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance (Eq rq, Eq sq) => Eq (Connection' d rq sq)

deriving instance Eq (SConnType d)

deriving instance Eq (StoredRcvQueue s)

deriving instance Eq (StoredSndQueue q)

deriving instance Eq RcvQueueSub

deriving instance Eq ClientNtfCreds

deriving instance Eq ShortLinkCreds

deriving instance Show (ConnLinkData c)

deriving instance Eq (ConnLinkData c)

deriving instance Show UserLinkData

deriving instance Eq UserLinkData

deriving instance Show OwnerAuth

deriving instance Eq OwnerAuth

deriving instance Show ProxiedRelay

deriving instance Eq ProxiedRelay
