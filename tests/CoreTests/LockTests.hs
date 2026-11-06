module CoreTests.LockTests where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM
import Control.Monad (forM)
import qualified Data.Set as S
import Simplex.Messaging.Agent.Client (withLockMap, withLocksMap)
import Simplex.Messaging.Agent.Lock (Lock)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it)
import Util

lockTests :: Spec
lockTests = do
  testInterruptedAcquisitionReleasesLocks
  testConcurrentBatchesDoNotDeadlock

testInterruptedAcquisitionReleasesLocks :: Spec
testInterruptedAcquisitionReleasesLocks =
  it "releases the locks already taken when a multi-lock acquisition is interrupted" $ do
    locks <- TM.emptyIO :: IO (TMap Int Lock)
    acquired <- newEmptyTMVarIO
    holder <- async $ withLockMap locks 5 "processSMP" (atomically (putTMVar acquired ()) >> threadDelay 300000)
    atomically $ takeTMVar acquired
    interrupted <- timeout 100000 $ withLocksMap locks (S.fromList [1 .. 10]) "sendMessages" (pure ())
    interrupted `shouldBe` Nothing
    wait holder
    completed <- timeout 2000000 $ withLocksMap locks (S.fromList [1 .. 10]) "sendMessages" (pure ())
    completed `shouldBe` Just ()

testConcurrentBatchesDoNotDeadlock :: Spec
testConcurrentBatchesDoNotDeadlock =
  it "serialises two concurrent batches that acquire overlapping locks" $ do
    completed <- forM [1 .. 50 :: Int] $ \_ -> do
      locks <- TM.emptyIO :: IO (TMap Int Lock)
      busy <- async $ withLockMap locks 1 "processSMP" (threadDelay 20000)
      threadDelay 1000
      send1 <- async $ withLocksMap locks (S.fromList [1 .. 100]) "sendMessages" (threadDelay 1000)
      threadDelay 5000
      send2 <- async $ withLocksMap locks (S.fromList [1 .. 100]) "sendMessages" (threadDelay 1000)
      r <- timeout 2000000 (wait send1 >> wait send2)
      wait busy
      pure (r == Just ())
    length (filter not completed) `shouldBe` 0
