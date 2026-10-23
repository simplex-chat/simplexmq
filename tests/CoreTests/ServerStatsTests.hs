{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module CoreTests.ServerStatsTests where

import Data.Hashable (hash)
import Data.IORef
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Maybe (isNothing)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Protocol (EntityId (..))
import Simplex.Messaging.Server.Stats
import Test.Hspec hiding (fit, it)
import Util

serverStatsTests :: Spec
serverStatsTests =
  describe "pending period stats" $ do
    it "should not track pending hashes when disabled" testNoPending
    it "should track hashes added since the last take" testPendingAdded
    it "should reset pending hashes with period sets" testPendingReset
    it "should merge restored pending hashes" testMergePending

q1, q2, q3, q4, q5 :: EntityId
q1 = EntityId "queue1"
q2 = EntityId "queue2"
q3 = EntityId "queue3"
q4 = EntityId "queue4"
q5 = EntityId "queue5"

hashes :: [EntityId] -> IntSet
hashes = IS.fromList . map (hash . unEntityId)

utcDay :: Integer -> Int -> Int -> UTCTime
utcDay y m d = UTCTime (fromGregorian y m d) 3600

-- 2026-06-10 is Wednesday, 2026-06-08 is Monday, 2026-06-01 is Monday and the 1st
wednesday, monday, monday1st :: UTCTime
wednesday = utcDay 2026 6 10
monday = utcDay 2026 6 8
monday1st = utcDay 2026 6 1

noPending :: PendingHashes
noPending = PendingHashes {pendingReset = False, pendingAdded = IS.empty}

resetPending :: PendingHashes
resetPending = PendingHashes {pendingReset = True, pendingAdded = IS.empty}

added :: [EntityId] -> PendingHashes
added qs = PendingHashes {pendingReset = False, pendingAdded = hashes qs}

testNoPending :: IO ()
testNoPending = do
  ps <- newPeriodStats
  isNothing (pendingPeriods ps) `shouldBe` True
  updatePeriodStats ps q1
  readIORef (day ps) `shouldReturn` hashes [q1]
  ServerStats {activeQueues, activeQueuesNtf} <- newServerStats False wednesday
  isNothing (pendingPeriods activeQueues) `shouldBe` True
  isNothing (pendingPeriods activeQueuesNtf) `shouldBe` True

testPendingAdded :: IO ()
testPendingAdded = do
  ServerStats {activeQueues = ps} <- newServerStats True wednesday
  Just PendingPeriods {pendingDay, pendingWeek, pendingMonth} <- pure $ pendingPeriods ps
  mapM_ (updatePeriodStats ps) [q1, q2, q1]
  takePendingHashes pendingDay `shouldReturn` added [q1, q2]
  takePendingHashes pendingDay `shouldReturn` noPending
  updatePeriodStats ps q1
  takePendingHashes pendingDay `shouldReturn` noPending
  updatePeriodStats ps q3
  takePendingHashes pendingDay `shouldReturn` added [q3]
  takePendingHashes pendingWeek `shouldReturn` added [q1, q2, q3]
  takePendingHashes pendingMonth `shouldReturn` added [q1, q2, q3]
  readIORef (day ps) `shouldReturn` hashes [q1, q2, q3]

testPendingReset :: IO ()
testPendingReset = do
  ps <- newPendingPeriodStats
  Just PendingPeriods {pendingDay, pendingWeek, pendingMonth} <- pure $ pendingPeriods ps
  updatePeriodStats ps q1
  PeriodStatCounts {dayCount, weekCount, monthCount} <- periodStatCounts ps wednesday
  (dayCount, weekCount, monthCount) `shouldBe` ("1", "", "")
  takePendingHashes pendingDay `shouldReturn` resetPending
  takePendingHashes pendingWeek `shouldReturn` added [q1]
  takePendingHashes pendingMonth `shouldReturn` added [q1]
  updatePeriodStats ps q2
  _ <- periodStatCounts ps monday
  takePendingHashes pendingDay `shouldReturn` resetPending
  takePendingHashes pendingWeek `shouldReturn` resetPending
  takePendingHashes pendingMonth `shouldReturn` added [q2]
  readIORef (month ps) `shouldReturn` hashes [q1, q2]
  updatePeriodStats ps q3
  _ <- periodStatCounts ps monday1st
  mapM takePendingHashes [pendingDay, pendingWeek, pendingMonth] `shouldReturn` [resetPending, resetPending, resetPending]
  mapM readIORef [day ps, week ps, month ps] `shouldReturn` [IS.empty, IS.empty, IS.empty]
  updatePeriodStats ps q4
  takePendingHashes pendingMonth `shouldReturn` added [q4]

testMergePending :: IO ()
testMergePending = do
  mergePendingHashes (added [q1]) (added [q2]) `shouldBe` added [q1, q2]
  mergePendingHashes resetPending (added [q2]) `shouldBe` PendingHashes {pendingReset = True, pendingAdded = hashes [q2]}
  ref <- newIORef $ added [q5]
  restorePendingHashes ref PendingHashes {pendingReset = True, pendingAdded = hashes [q3, q4]}
  readIORef ref `shouldReturn` PendingHashes {pendingReset = True, pendingAdded = hashes [q3, q4, q5]}
