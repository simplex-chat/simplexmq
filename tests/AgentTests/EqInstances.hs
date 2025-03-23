{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module AgentTests.EqInstances where

import Data.Type.Equality
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Client (ProxiedRelay (..))

instance Eq SomeConn where
  SomeConn d c == SomeConn d' c' = case testEquality d d' of
    Just Refl -> c == c'
    _ -> False

deriving instance Eq (Connection d)

deriving instance Eq (SConnType d)

deriving instance Eq (StoredRcvQueue q)

deriving instance Eq (StoredSndQueue q)

deriving instance Eq (DBQueueId q)

deriving instance Eq ClientNtfCreds

deriving instance Eq ShortLinkCreds

deriving instance Eq LinkKey

deriving instance Show ProxiedRelay

deriving instance Eq ProxiedRelay
