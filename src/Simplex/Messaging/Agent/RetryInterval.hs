{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.RetryInterval
  ( RetryInterval (..),
    RetryInterval2 (..),
    RetryIntervalMode (..),
    withRetryInterval,
    withRetryLock2,
  )
where

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

data RetryIntervalMode = RISlow | RIFast
  deriving (Eq)

withRetryInterval :: forall m. MonadIO m => RetryInterval -> (m () -> m ()) -> m ()
withRetryInterval ri action = callAction 0 $ initialInterval ri
  where
    callAction :: Int -> Int -> m ()
    callAction elapsed delay = action loop
      where
        loop = do
          liftIO $ threadDelay delay
          callAction (elapsed + delay) (nextDelay elapsed delay ri)

-- This function allows action to toggle between slow and fast retry intervals.
withRetryLock2 :: forall m. MonadIO m => RetryInterval2 -> TMVar () -> ((RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryLock2 RetryInterval2 {riSlow, riFast} lock action =
  callAction (0, initialInterval riSlow) (0, initialInterval riFast)
  where
    callAction :: (Int, Int) -> (Int, Int) -> m ()
    callAction slow fast = action loop
      where
        loop = \case
          RISlow -> runLoop slow (`callAction` fast) riSlow
          RIFast -> runLoop fast (callAction slow) riFast
        runLoop (elapsed, delay) call ri = do
          waitForDelay delay
          call (elapsed + delay, nextDelay elapsed delay ri)
        waitForDelay delay = do
          waiting <- newTVarIO True
          _ <- liftIO . forkIO $ do
            threadDelay delay
            atomically $ whenM (readTVar waiting) $ void $ tryPutTMVar lock ()
          atomically $ do
            takeTMVar lock
            writeTVar waiting False

nextDelay :: Int -> Int -> RetryInterval -> Int
nextDelay elapsed delay RetryInterval {increaseAfter, maxInterval} =
  if elapsed < increaseAfter || delay == maxInterval
    then delay
    else min (delay * 3 `div` 2) maxInterval
