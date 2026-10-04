{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.RetryIntervalTests where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Monad (when)
import Data.Int (Int64)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Simplex.Messaging.Agent.RetryInterval
import Test.Hspec hiding (fit, it)
import Util

retryIntervalTests :: Spec
retryIntervalTests = do
  describe "Retry interval with 2 modes and lock" $ do
    testRetryIntervalSameMode withRetryNewLock2
    testRetryIntervalSwitchMode withRetryNewLock2
    testRetryIntervalEpochReset
  describe "Retry interval with 2 modes" $ do
    testRetryIntervalSameMode withRetryInterval2
    testRetryIntervalSwitchMode withRetryInterval2
  describe "Retry interval with 2 modes and epoch" $ do
    testRetryIntervalSameMode (`withRetryEpoch2` pure 0)
    testRetryIntervalSwitchMode (`withRetryEpoch2` pure 0)
  describe "Foreground retry interval" $ do
    testRetryForeground
    testRetryToBackground
    testRetrySkipWhenForeground
    testRetryForegroundEpoch
  describe "Retry interval with epoch" $ do
    testRetryEpochSameValue
    testRetrySkipOnEpochChange
    testRetryEpochChangedInAction
    testRetryEpochKeepsCount

testRI :: RetryInterval2
testRI =
  RetryInterval2
    { riSlow =
        RetryInterval
          { initialInterval = 20000,
            increaseAfter = 40000,
            maxInterval = 40000
          },
      riFast = testFastRI
    }

testFastRI :: RetryInterval
testFastRI =
  RetryInterval
    { initialInterval = 10000,
      increaseAfter = 20000,
      maxInterval = 40000
    }

type WithRetry2 = RetryInterval2 -> (RI2State -> (RetryIntervalMode -> IO ()) -> IO ()) -> IO ()

withRetryNewLock2 :: WithRetry2
withRetryNewLock2 ri action = newEmptyTMVarIO >>= \lock -> withRetryLock2 ri (pure 0) lock action

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
      `shouldReturn` [ (20000, 10000),
                       (20000, 10000),
                       (20000, 15000),
                       (20000, 22500),
                       (20000, 33750),
                       (20000, 40000),
                       (20000, 40000),
                       (20000, 40000),
                       (20000, 40000)
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
      `shouldReturn` [ (20000, 10000),
                       (20000, 10000),
                       (20000, 15000),
                       (20000, 22500),
                       (20000, 33750),
                       (20000, 40000),
                       (20000, 40000),
                       (30000, 40000),
                       (40000, 40000),
                       (40000, 40000),
                       (40000, 40000)
                     ]

testRetryIntervalEpochReset :: Spec
testRetryIntervalEpochReset =
  it "should restart fast interval when epoch changes, but not slow interval" $ do
    lock <- newEmptyTMVarIO
    epoch <- newTVarIO (0 :: Int)
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    concurrently_
      ( do
          -- fast mode: waiting for 33750, restarts immediately at 65ms with the initial interval
          threadDelay 65000
          atomically $ modifyTVar' epoch (+ 1)
          -- slow mode: waiting for 20000 from 95ms, the change is ignored
          threadDelay 40000
          atomically $ modifyTVar' epoch (+ 1)
      )
      ( withRetryLock2 testRI (readTVar epoch) lock $ \(RI2State slow fast) loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals ((slow, fast) :)
          when (length ints < 9) $ loop $ if length ints <= 6 then RIFast else RISlow
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 0, 1, 2, 2]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [ (20000, 10000),
                       (20000, 10000),
                       (20000, 15000),
                       (20000, 22500),
                       (20000, 33750),
                       (20000, 10000),
                       (20000, 10000),
                       (20000, 10000),
                       (30000, 10000)
                     ]

testRetryForeground :: Spec
testRetryForeground =
  it "should increase elapased time and interval" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    let isForeground = pure True
    withRetryForeground testFastRI isForeground (pure True) (pure 0) $ \delay loop -> do
      ints <- addInterval intervals ts
      atomically $ modifyTVar' reportedIntervals (delay :)
      when (length ints < 8) $ loop
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 22500, 33750, 40000, 40000, 40000]

testRetryToBackground :: Spec
testRetryToBackground =
  it "should not change interval when moving to background" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    foreground <- newTVarIO True
    concurrently_
      ( do
          threadDelay 50000
          atomically $ writeTVar foreground False
      )
      ( withRetryForeground testFastRI (readTVar foreground) (pure True) (pure 0) $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 8) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 22500, 33750, 40000, 40000, 40000]

testRetrySkipWhenForeground :: Spec
testRetrySkipWhenForeground =
  it "should repeat loop as soon as moving to foreground" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    foreground <- newTVarIO False
    concurrently_
      ( do
          threadDelay 65000
          atomically $ writeTVar foreground True
          threadDelay 10000
          atomically $ writeTVar foreground False
          threadDelay 100000
          atomically $ writeTVar foreground True
      )
      ( withRetryForeground testFastRI (readTVar foreground) (pure True) (pure 0) $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 12) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 0, 1, 1, 1, 2, 3, 1]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 22500, 33750, 10000, 10000, 15000, 22500, 33750, 40000, 10000]

testRetryForegroundEpoch :: Spec
testRetryForegroundEpoch =
  testEpochRestartsLoop "should repeat foreground loop as soon as epoch changes" $ \e ->
    withRetryForeground testFastRI (pure True) (pure True) (readTVar e)

testRetryEpochSameValue :: Spec
testRetryEpochSameValue =
  it "should not change interval when epoch is written with the same value" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    epoch <- newTVarIO (0 :: Int)
    concurrently_
      ( do
          threadDelay 50000
          atomically $ writeTVar epoch 0
      )
      ( withRetryEpoch testFastRI (readTVar epoch) $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 8) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 3, 4, 4]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 22500, 33750, 40000, 40000, 40000]

testRetryEpochChangedInAction :: Spec
testRetryEpochChangedInAction =
  it "should restart interval when epoch changes while action runs" $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    epoch <- newTVarIO (0 :: Int)
    withRetryEpoch testFastRI (readTVar epoch) $ \delay loop -> do
      ints <- addInterval intervals ts
      atomically $ modifyTVar' reportedIntervals (delay :)
      when (length ints == 3) $ atomically $ modifyTVar' epoch (+ 1)
      when (length ints < 6) $ loop
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 0, 1, 1]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 10000, 10000, 15000]

testRetryEpochKeepsCount :: Spec
testRetryEpochKeepsCount =
  it "should not reset attempt count when epoch changes" $ do
    counts <- newTVarIO ([] :: [Int])
    epoch <- newTVarIO (0 :: Int)
    withRetryEpochCount testFastRI (readTVar epoch) $ \n _ loop -> do
      ns <- atomically $ stateTVar counts $ \ns -> (n : ns, n : ns)
      when (length ns == 2) $ atomically $ modifyTVar' epoch (+ 1)
      when (length ns < 4) loop
    (reverse <$> readTVarIO counts) `shouldReturn` [0, 1, 2, 3]

testRetrySkipOnEpochChange :: Spec
testRetrySkipOnEpochChange =
  testEpochRestartsLoop "should repeat loop as soon as epoch changes" $ \e ->
    withRetryEpoch testFastRI (readTVar e)

-- the epoch changes twice while the loop waits, so the interval restarts from the initial one twice
testEpochRestartsLoop :: String -> (TVar Int -> (Int64 -> IO () -> IO ()) -> IO ()) -> Spec
testEpochRestartsLoop name withRetry =
  it name $ do
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    epoch <- newTVarIO (0 :: Int)
    concurrently_
      ( do
          threadDelay 65000
          atomically $ modifyTVar' epoch (+ 1)
          threadDelay 110000
          atomically $ modifyTVar' epoch (+ 1)
      )
      ( withRetry epoch $ \delay loop -> do
          ints <- addInterval intervals ts
          atomically $ modifyTVar' reportedIntervals (delay :)
          when (length ints < 12) $ loop
      )
    (reverse <$> readTVarIO intervals) `shouldReturn` [0, 1, 1, 1, 2, 0, 1, 1, 1, 2, 3, 1]
    (reverse <$> readTVarIO reportedIntervals)
      `shouldReturn` [10000, 10000, 15000, 22500, 33750, 10000, 10000, 15000, 22500, 33750, 40000, 10000]

addInterval :: TVar [Int] -> TVar UTCTime -> IO [Int]
addInterval intervals ts = do
  ts' <- getCurrentTime
  atomically $ do
    int :: Int <- truncate . (* 100) . nominalDiffTimeToSeconds <$> stateTVar ts (\t -> (diffUTCTime ts' t, ts'))
    stateTVar intervals $ \ints -> (int : ints, int : ints)
