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
  deriving (Eq, Show)

withRetryInterval :: forall m. MonadIO m => RetryInterval -> (Int -> m () -> m ()) -> m ()
withRetryInterval ri action = callAction 0 $ initialInterval ri
  where
    callAction :: Int -> Int -> m ()
    callAction elapsed delay = action delay loop
      where
        loop = do
          liftIO $ threadDelay delay
          let elapsed' = elapsed + delay
          callAction elapsed' $ nextDelay elapsed' delay ri

-- This function allows action to toggle between slow and fast retry intervals.
withRetryLock2 :: forall m. MonadIO m => RetryInterval2 -> TMVar () -> ((RetryIntervalMode, Int) -> (RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryLock2 RetryInterval2 {riSlow, riFast} lock action =
  callAction (RIFast, 0) (0, initialInterval riSlow) (0, initialInterval riFast)
  where
    callAction :: (RetryIntervalMode, Int) -> (Int, Int) -> (Int, Int) -> m ()
    callAction retryState slow fast = action retryState loop
      where
        loop mode = case mode of
          RISlow -> run slow riSlow (\ri -> callAction (state ri) ri fast)
          RIFast -> run fast riFast (\ri -> callAction (state ri) slow ri)
          where
            state ri = (mode, snd ri)
        run (elapsed, delay) ri call = do
          wait delay
          let elapsed' = elapsed + delay
              delay' = nextDelay elapsed' delay ri
          call (elapsed', delay')
        wait delay = do
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
