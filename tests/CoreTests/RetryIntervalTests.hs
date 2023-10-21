{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.RetryIntervalTests where

import Control.Concurrent.STM
import Control.Monad (when)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Simplex.Messaging.Agent.RetryInterval
import Test.Hspec

retryIntervalTests :: Spec
retryIntervalTests = do
  describe "Retry interval with 2 modes and lock" $ do
    testRetryIntervalSameMode
    testRetryIntervalSwitchMode

testRI :: RetryInterval2
testRI =
  RetryInterval2
    { riSlow =
        RetryInterval
          { initialInterval = 20000,
            increaseAfter = 40000,
            maxInterval = 40000
          },
      riFast =
        RetryInterval
          { initialInterval = 10000,
            increaseAfter = 20000,
            maxInterval = 40000
          }
    }

testRetryIntervalSameMode :: Spec
testRetryIntervalSameMode =
  it "should increase elapased time and interval when the mode stays the same" $ do
    lock <- newEmptyTMVarIO
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    withRetryLock2 testRI lock $ \(RI2State slow fast) loop -> do
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

testRetryIntervalSwitchMode :: Spec
testRetryIntervalSwitchMode =
  it "should increase elapased time and interval when the mode stays the same" $ do
    lock <- newEmptyTMVarIO
    intervals <- newTVarIO []
    reportedIntervals <- newTVarIO []
    ts <- newTVarIO =<< getCurrentTime
    withRetryLock2 testRI lock $ \(RI2State slow fast) loop -> do
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

addInterval :: TVar [Int] -> TVar UTCTime -> IO [Int]
addInterval intervals ts = do
  ts' <- getCurrentTime
  atomically $ do
    int :: Int <- truncate . (* 100) . nominalDiffTimeToSeconds <$> stateTVar ts (\t -> (diffUTCTime ts' t, ts'))
    stateTVar intervals $ \ints -> (int : ints, int : ints)
