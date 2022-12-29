{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.RetryInterval where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Simplex.Messaging.Util (whenM)
import UnliftIO.STM

data RetryInterval = RetryInterval
  { initialInterval :: Int,
    increaseAfter :: Int,
    maxInterval :: Int
  }

data RetryInterval2 = RetryInterval2
  { riSlow :: RetryInterval,
    riFast :: RetryInterval
  }

withRetryInterval :: forall m. MonadIO m => RetryInterval -> (m () -> m ()) -> m ()
withRetryInterval RetryInterval {initialInterval, increaseAfter, maxInterval} action =
  callAction 0 initialInterval
  where
    callAction :: Int -> Int -> m ()
    callAction elapsedTime delay = action loop
      where
        loop = do
          let newDelay =
                if elapsedTime < increaseAfter || delay == maxInterval
                  then delay
                  else min (delay * 3 `div` 2) maxInterval
          liftIO $ threadDelay delay
          callAction (elapsedTime + delay) newDelay

-- This function allows action to toggle between slow and fast retry intervals, resetting elapsed time to 0 when it switches.
withRetryLock2 :: forall m. MonadIO m => RetryInterval2 -> TMVar () -> ((Bool -> m ()) -> m ()) -> m ()
withRetryLock2 RetryInterval2 {riSlow, riFast} lock action =
  callAction 0 (initialInterval riFast) True
  where
    callAction :: Int -> Int -> Bool -> m ()
    callAction elapsed delay fast = action loop
      where
        loop newFast = do
          let RetryInterval {increaseAfter, maxInterval} = if newFast then riFast else riSlow
              newElapsed = if newFast == fast then elapsed else 0
              newDelay =
                if newElapsed < increaseAfter || delay == maxInterval
                  then delay
                  else min (delay * 3 `div` 2) maxInterval
          waiting <- atomically $ tryTakeTMVar lock >> newTVar True
          _ <- liftIO . forkIO $ do
            threadDelay delay
            atomically $ whenM (readTVar waiting) $ void $ tryPutTMVar lock ()
          atomically $ do
            takeTMVar lock
            writeTVar waiting False
          callAction (newElapsed + delay) newDelay newFast
