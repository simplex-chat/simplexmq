{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.RetryInterval
  ( RetryInterval (..),
    RetryInterval2 (..),
    RetryIntervalMode (..),
    RI2State (..),
    withRetryInterval,
    withRetryIntervalCount,
    withRetryEpoch,
    withRetryEpochCount,
    withRetryEpoch2,
    withRetryForeground,
    withRetryInterval2,
    withRetryLock2,
    updateRetryInterval2,
    nextRetryDelay,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (retry)
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Int (Int64)
import Simplex.Messaging.Util (threadDelay', unlessM, whenM)
import UnliftIO.STM

data RetryInterval = RetryInterval
  { initialInterval :: Int64,
    increaseAfter :: Int64,
    maxInterval :: Int64
  }

data RetryInterval2 = RetryInterval2
  { riSlow :: RetryInterval,
    riFast :: RetryInterval
  }

data RI2State = RI2State
  { slowInterval :: Int64,
    fastInterval :: Int64
  }
  deriving (Show)

updateRetryInterval2 :: RI2State -> RetryInterval2 -> RetryInterval2
updateRetryInterval2 RI2State {slowInterval, fastInterval} RetryInterval2 {riSlow, riFast} =
  RetryInterval2
    { riSlow = riSlow {initialInterval = slowInterval, increaseAfter = 0},
      riFast = riFast {initialInterval = fastInterval, increaseAfter = 0}
    }

data RetryIntervalMode = RISlow | RIFast
  deriving (Eq, Show)

withRetryInterval :: forall m a. MonadIO m => RetryInterval -> (Int64 -> m a -> m a) -> m a
withRetryInterval ri = withRetryIntervalCount ri . const

withRetryIntervalCount :: forall m a. MonadIO m => RetryInterval -> (Int -> Int64 -> m a -> m a) -> m a
withRetryIntervalCount ri action = callAction 0 0 $ initialInterval ri
  where
    callAction :: Int -> Int64 -> Int64 -> m a
    callAction n elapsed delay = action n delay loop
      where
        loop = do
          liftIO $ threadDelay' delay
          let elapsed' = elapsed + delay
          callAction (n + 1) elapsed' $ nextRetryDelay elapsed' delay ri

-- The delay restarts from the initial interval when the epoch changes (the agent increments it when the network changes)
-- while the loop waits; when it changed while the action was running the next attempt is made without any delay.
withRetryEpoch :: forall m a. MonadIO m => RetryInterval -> STM Int -> (Int64 -> m a -> m a) -> m a
withRetryEpoch ri getEpoch = withRetryEpochCount ri getEpoch . const

withRetryEpochCount :: forall m a. MonadIO m => RetryInterval -> STM Int -> (Int -> Int64 -> m a -> m a) -> m a
withRetryEpochCount ri getEpoch action = callAction 0 0 $ initialInterval ri
  where
    callAction :: Int -> Int64 -> Int64 -> m a
    callAction n elapsed delay = do
      epoch <- atomically getEpoch
      action n delay $ do
        reset <- waitEpoch' epoch delay
        let (elapsed', delay')
              | reset = (0, initialInterval ri)
              | otherwise = (elapsed + delay, nextRetryDelay elapsed' delay ri)
        callAction (n + 1) elapsed' delay'
    waitEpoch' = waitEpoch getEpoch

-- returns True when the epoch changed before the delay expired
waitEpoch :: MonadIO m => STM Int -> Int -> Int64 -> m Bool
waitEpoch getEpoch epoch delay = do
  -- limit delay to max Int value (~36 minutes on for 32 bit architectures)
  d <- registerDelay $ fromIntegral $ min delay (fromIntegral (maxBound :: Int))
  atomically $ do
    changed <- (epoch /=) <$> getEpoch
    unlessM ((changed ||) <$> readTVar d) retry
    pure changed

withRetryForeground :: forall m a. MonadIO m => RetryInterval -> STM Bool -> STM Bool -> STM Int -> (Int64 -> m a -> m a) -> m a
withRetryForeground ri isForeground isOnline getEpoch action = callAction 0 $ initialInterval ri
  where
    callAction :: Int64 -> Int64 -> m a
    callAction elapsed delay = action delay . loop =<< atomically getEpoch
      where
        loop epoch = do
          -- limit delay to max Int value (~36 minutes on for 32 bit architectures)
          d <- registerDelay $ fromIntegral $ min delay (fromIntegral (maxBound :: Int))
          (wasForeground, wasOnline) <- atomically $ (,) <$> isForeground <*> isOnline
          reset <- atomically $ do
            foreground <- isForeground
            online <- isOnline
            epochChanged <- (epoch /=) <$> getEpoch
            let reset = (not wasForeground && foreground) || (not wasOnline && online) || epochChanged
            unlessM ((reset ||) <$> readTVar d) retry
            pure reset
          let (elapsed', delay')
                | reset = (0, initialInterval ri)
                | otherwise = (elapsed + delay, nextRetryDelay elapsed' delay ri)
          callAction elapsed' delay'

withRetryInterval2 :: forall m. MonadIO m => RetryInterval2 -> (RI2State -> (RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryInterval2 = withRetryWait2 (pure ()) $ \_ _ delay -> False <$ liftIO (threadDelay' delay)

-- This function allows action to toggle between slow and fast retry intervals.
-- The fast interval restarts on the epoch change, as in withRetryEpoch; once the action chose the slow
-- interval (recipient queue quota) the epoch change is not applied to the fast interval - neither the one
-- that happened during that action nor during the wait.
withRetryLock2 :: forall m. MonadIO m => RetryInterval2 -> STM Int -> TMVar () -> (RI2State -> (RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryLock2 ri getEpoch lock = withRetryWait2 (atomically getEpoch) wait ri
  where
    wait mode epoch delay = do
      waiting <- newTVarIO True
      _ <- liftIO . forkIO $ do
        threadDelay' delay
        atomically $ whenM (readTVar waiting) $ void $ tryPutTMVar lock ()
      atomically $ do
        reset <- (epochChanged <* tryTakeTMVar lock) `orElse` (False <$ takeTMVar lock)
        writeTVar waiting False
        pure reset
      where
        epochChanged = case mode of
          RIFast -> unlessM ((epoch /=) <$> getEpoch) retry >> pure True
          RISlow -> retry

-- As withRetryLock2, without the lock: the fast interval restarts on the epoch change, the slow one
-- (recipient queue quota) does not.
withRetryEpoch2 :: forall m. MonadIO m => RetryInterval2 -> STM Int -> (RI2State -> (RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryEpoch2 ri getEpoch = withRetryWait2 (atomically getEpoch) wait ri
  where
    wait mode epoch delay = case mode of
      RISlow -> False <$ liftIO (threadDelay' delay)
      RIFast -> waitEpoch getEpoch epoch delay

-- the value sampled before the action is passed to wait, so that a change that happened during the
-- action resets the interval as one during the wait does
withRetryWait2 :: forall m e. Monad m => m e -> (RetryIntervalMode -> e -> Int64 -> m Bool) -> RetryInterval2 -> (RI2State -> (RetryIntervalMode -> m ()) -> m ()) -> m ()
withRetryWait2 sample wait RetryInterval2 {riSlow, riFast} action =
  callAction (0, initialInterval riSlow) (0, initialInterval riFast)
  where
    callAction :: (Int64, Int64) -> (Int64, Int64) -> m ()
    callAction slow fast = sample >>= \e -> action (RI2State (snd slow) (snd fast)) (loop e)
      where
        loop e = \case
          RISlow -> run RISlow e slow riSlow (`callAction` fast)
          RIFast -> run RIFast e fast riFast (callAction slow)
        run mode e (elapsed, delay) ri call = do
          reset <- wait mode e delay
          let (elapsed', delay')
                | reset = (0, initialInterval ri)
                | otherwise = (elapsed + delay, nextRetryDelay elapsed' delay ri)
          call (elapsed', delay')

nextRetryDelay :: Int64 -> Int64 -> RetryInterval -> Int64
nextRetryDelay elapsed delay RetryInterval {increaseAfter, maxInterval} =
  if elapsed < increaseAfter || delay == maxInterval
    then delay
    else min (delay * 3 `div` 2) maxInterval
