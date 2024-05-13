{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.Stats.Timeline where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IntMap (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntPSQ (IntPSQ)
import qualified Data.IntPSQ as IP
import Data.Monoid (getSum)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Calendar.Month (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (NominalDiffTime, UTCTime (..))
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word32)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (RecipientId)
import UnliftIO.STM

-- A time series of counters with an active head
type Timeline a = (TVar SparseSeries, Current a)

newTimeline :: forall a. QuantFun -> POSIXTime -> STM (Timeline a)
newTimeline quantF now = (,current) <$> newTVar IP.empty
  where
    current :: Current a
    current = (quantF, quantF now, mempty)

-- Sparse timeseries with 1 second resolution (or more coarse):
--   priotity - time/bucket
--   key -- PeerId
--   value -- final counter value of the bucket that was current
-- May be combined with bucket width to produce rolling rates.
type SparseSeries = IntPSQ BucketId Int

-- POSIXTime, or quantized
type BucketId = Word32

type QuantFun = POSIXTime -> BucketId

-- Current bucket that gets filled
type Current a = (QuantFun, BucketId, IntMap (TVar a))

perSecond :: POSIXTime -> BucketId
perSecond = truncate

perMinute :: POSIXTime -> BucketId
perMinute = (60 `secondsWidth`)

secondsWidth :: NominalDiffTime -> POSIXTime -> BucketId
secondsWidth w t = truncate $ t / w

finishCurrent :: POSIXTime -> Timeline a -> STM (Timeline a)
finishCurrent now (series, current) = error "TODO: read/reset current, push into series, evict minimal when it falls out of scope"

type WindowData = IntMap Int -- PeerId -> counter

window :: BucketId -> BucketId -> SparseSeries -> WindowData
window = error "TODO: pick elements inside the range and drop bucket ids"

-- counter -> occurences
type Histogram = IntMap Int

histogram :: WindowData -> Histogram
histogram = fmap getSum . IM.fromListWith (<>) . map (,1) . IM.elems

distribution :: Histogram -> Distribution Int
distribution = error "TODO: unroll histogram, sample elements at percentiles"

data Distribution a = Distribution
  { minimal :: a,
    bottom50p :: a,
    top50p :: a,
    top20p :: a,
    top10p :: a,
    top5p :: a,
    top1p :: a,
    maximal :: a
  }
  deriving (Show)
