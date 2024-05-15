{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.Stats.Timeline where

import Data.IntMap (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntPSQ (IntPSQ)
import qualified Data.IntPSQ as IP
import Data.List (find, sortOn)
import Data.Maybe (listToMaybe)
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word32)
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
