{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.SystemTime where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Typeable (Proxy (..))
import GHC.TypeLits (KnownNat, Nat, natVal)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..))
import Simplex.Messaging.Encoding.String

newtype RoundedSystemTime (t :: Nat) = RoundedSystemTime Int64
  deriving (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromField, ToField)

type SystemDate = RoundedSystemTime 86400

type SystemHours = RoundedSystemTime 3600

type SystemSeconds = RoundedSystemTime 1

instance StrEncoding (RoundedSystemTime t) where
  strEncode (RoundedSystemTime t) = strEncode t
  strP = RoundedSystemTime <$> strP

getRoundedSystemTime :: forall t. KnownNat t => IO (RoundedSystemTime t)
getRoundedSystemTime = (\t -> RoundedSystemTime $ (systemSeconds t `div` prec) * prec) <$> getSystemTime
  where
    prec = fromIntegral $ natVal $ Proxy @t

getSystemDate :: IO SystemDate
getSystemDate = getRoundedSystemTime
{-# INLINE getSystemDate #-}

getSystemSeconds :: IO SystemSeconds
getSystemSeconds = getRoundedSystemTime
{-# INLINE getSystemSeconds #-}
