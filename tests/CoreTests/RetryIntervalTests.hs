{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.RetryIntervalTests where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Monad (when)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Simplex.Messaging.Agent.RetryInterval
import Test.Hspec hiding (fit, it)
import Util

retryIntervalTests :: Spec
retryIntervalTests = do
  describe "Retry interval with 2 modes and lock" $ do
    testRetryIntervalSameMode withRetryNewLock2
    testRetryIntervalSwitchMode withRetryNewLock2
  describe "Retry interval with 2 modes" $ do
    testRetryIntervalSameMode withRetryInterval2
    testRetryIntervalSwitchMode withRetryInterval2
  describe "Foreground retry interval" $ do
    testRetryForeground
    testRetryToBackground
    testRetrySkipWhenForeground

testRI :: RetryInterval2
testRI =
  RetryInterval2
    { riSlow =
        RetryInterval
          { initialInterval = 100000,
            increaseAfter = 200000,
            maxInterval = 200000
          },
      riFast = testFastRI
    }

testFastRI :: RetryInterval
testFastRI =
  RetryInterval
    { initialInterval = 50000,
      increaseAfter = 100000,
      maxInterval = 200000
    }

type WithRetry2 = RetryInterval2 -> (RI2State -> (RetryIntervalMode -> IO ()) -> IO ()) -> IO ()

withRetryNewLock2 :: WithRetry2
withRetryNewLock2 ri action = newEmptyTMVarIO >>= \lock -> withRetryLock2 ri lock action

testRetryIntervalSameMode :: WithRetry2 -> Spec
testRetryIntervalSameMode withRetry =
  it "should increase elapased time and interval when the mode stays the same" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    withRetry testRI $ \(RI2State slow fast) loop -> do
      ints <- addInterval intervals ts
      atomically $ modifyTVar' reportedIntervals ((slow, fast) :)
      when (length ints < 9) $ loop RIFast
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [ (100000, 50000),
                       (100000, 50000),
                       (100000, 75000),
                       (100000, 112500),
                       (100000, 168750),
                       (100000, 200000),
                       (100000, 200000),
                       (100000, 200000),
                       (100000, 200000)
                     ]

testRetryIntervalSwitchMode :: WithRetry2 -> Spec
testRetryIntervalSwitchMode withRetry =
  it "should increase elapased time and interval when the mode switches" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    withRetry testRI $ \(RI2State slow fast) loop -> do
      ints <- addInterval intervals ts
      atomically $ modifyTVar' reportedIntervals ((slow, fast) :)
      when (length ints < 11) $ loop $ if length ints <= 5 then RIFast else RISlow
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 2, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [ (100000, 50000),
                       (100000, 50000),
                       (100000, 75000),
                       (100000, 112500),
                       (100000, 168750),
                       (100000, 200000),
                       (100000, 200000),
                       (150000, 200000),
                       (200000, 200000),
                       (200000, 200000),
                       (200000, 200000)
                     ]

testRetryForeground :: Spec
testRetryForeground =
  it "should increase elapased time and interval" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    let isForeground = pure True
    withRetryForeground testFastRI isForeground (pure True) $ \delay loop -> do
      ints <- addInterval intervals ts
      atomically $ modifyTVar' reportedIntervals (delay :)
      when (length ints < 8) $ loop
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [50000, 50000, 75000, 112500, 168750, 200000, 200000, 200000]

testRetryToBackground :: Spec
testRetryToBackground =
  it "should not change interval when moving to background" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    foreground <- newTVarIO True
    concurrently_
      ( do
          threadDelay 250000
          atomically $ writeTVar foreground False
      )
      ( withRetryForeground testFastRI (readTVar foreground) (pure True) $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 8) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [50000, 50000, 75000, 112500, 168750, 200000, 200000, 200000]

testRetrySkipWhenForeground :: Spec
testRetrySkipWhenForeground =
  it "should repeat loop as soon as moving to foreground" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    foreground <- newTVarIO False
    concurrently_
      ( do
          threadDelay 312500
          atomically $ writeTVar foreground True
          threadDelay 150000
          atomically $ writeTVar foreground False
          threadDelay 381250
          atomically $ writeTVar foreground True
      )
      ( withRetryForeground testFastRI (readTVar foreground) (pure True) $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 12) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 0, 1, 1, 1, 2, 3, 1]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [50000, 50000, 75000, 112500, 168750, 50000, 50000, 75000, 112500, 168750, 200000, 50000]

addInterval :: TVar [Int] -> TVar UTCTime -> IO [Int]
addInterval intervals ts = do
  ts' <- getCurrentTime
  atomically $ do
    int :: Int <- truncate . (* 20) . nominalDiffTimeToSeconds <$> stateTVar ts (\t -> (diffUTCTime ts' t, ts'))
    stateTVar intervals $ \ints -> (int : ints, int : ints)
