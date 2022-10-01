{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.RetryInterval where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (MonadIO, liftIO)

data RetryInterval = RetryInterval
  { initialInterval :: Int,
    increaseAfter :: Int,
    maxInterval :: Int
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
