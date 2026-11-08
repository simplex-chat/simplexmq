{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.SystemTime
  ( RoundedSystemTime (..),
    SystemDate,
    SystemSeconds,
    getRoundedSystemTime,
    getSystemDate,
    getSystemSeconds,
    roundedToUTCTime,
    checkTimeRange,
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds)
import Data.Time.Clock.System (SystemTime (..), getSystemTime, systemToUTCTime)
import Data.Typeable (Proxy (..))
import GHC.TypeLits (KnownNat, Nat, natVal)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..))
import Simplex.Messaging.Encoding.String

newtype RoundedSystemTime (t :: Nat) = RoundedSystemTime {roundedSeconds :: Int64}
  deriving (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromField, ToField)

type SystemDate = RoundedSystemTime 86400

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
getSystemSeconds = RoundedSystemTime . systemSeconds <$> getSystemTime
{-# INLINE getSystemSeconds #-}

roundedToUTCTime :: RoundedSystemTime t -> UTCTime
roundedToUTCTime = systemToUTCTime . (`MkSystemTime` 0) . roundedSeconds
{-# INLINE roundedToUTCTime #-}

checkTimeRange :: UTCTime -> Either String UTCTime
checkTimeRange t@(UTCTime day time)
  | year >= 1 && year <= 9999 && time < 86400 && diffTimeToPicoseconds time `mod` 1000 == 0 = Right t
  | otherwise = Left "time out of range"
  where
    (year, _, _) = toGregorian day
