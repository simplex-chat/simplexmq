{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Lock
  ( Lock,
    createLock,
    withLock,
    withGetLock,
    withGetLocks,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
import UnliftIO.Async (forConcurrently_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar String

createLock :: STM Lock
createLock = newEmptyTMVar
{-# INLINE createLock #-}

withLock :: MonadUnliftIO m => Lock -> String -> m a -> m a
withLock lock name =
  E.bracket_
    (atomically $ putTMVar lock name)
    (void . atomically $ takeTMVar lock)

withGetLock :: MonadUnliftIO m => (k -> STM Lock) -> k -> String -> m a -> m a
withGetLock getLock key name a =
  E.bracket
    -- getLock and putTMVar are split to two transactions, as getLock should be fast,
    -- but it can be accessing a shared resource (in fact, passed getLock accesses a global TMap),
    -- while putTMVar is blocking, and it can be preventing other locks from being taken / created
    (atomically (getLock key) >>= \l -> atomically (putTMVar l name) $> l)
    (atomically . takeTMVar)
    (const a)

withGetLocks :: MonadUnliftIO m => (k -> STM Lock) -> [k] -> String -> m a -> m a
withGetLocks getLock keys name = E.bracket holdLocks releaseLocks . const
  where
    holdLocks = do
      locks <- atomically $ mapM getLock keys
      forConcurrently_ locks $ \l -> atomically $ putTMVar l name
      pure locks
    -- only this withGetLocks would be holding the locks,
    -- so it's safe to combine all lock releases into one transaction
    releaseLocks = atomically . mapM_ takeTMVar
