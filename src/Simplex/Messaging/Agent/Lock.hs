{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Lock
  ( Lock,
    createLock,
    updateLock,
    withLock,
    withGetLock,
    withGetLock',
    withGetLocks,
  )
where

import Control.Monad (void, when)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
import UnliftIO.Async (forConcurrently)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar String

createLock :: STM Lock
createLock = newEmptyTMVar
{-# INLINE createLock #-}

-- only updates lock if it's taken and has the same name
updateLock :: MonadUnliftIO m => Lock -> String -> String -> m ()
updateLock lock oldName newName = atomically $ do
  name <- tryReadTMVar lock
  when (name == Just oldName) $ writeTMVar lock newName

withLock :: MonadUnliftIO m => Lock -> String -> m a -> m a
withLock lock name =
  E.bracket_
    (atomically $ putTMVar lock name)
    (void . atomically $ takeTMVar lock)

withGetLock :: MonadUnliftIO m => (k -> STM Lock) -> k -> String -> m a -> m a
withGetLock getLock key name = withGetLock' getLock key name . const

withGetLock' :: MonadUnliftIO m => (k -> STM Lock) -> k -> String -> (Lock -> m a) -> m a
withGetLock' getLock key name =
  E.bracket
    (atomically $ getPutLock getLock key name)
    (atomically . takeTMVar)

withGetLocks :: MonadUnliftIO m => (k -> STM Lock) -> [k] -> String -> m a -> m a
withGetLocks getLock keys name = E.bracket holdLocks releaseLocks . const
  where
    holdLocks = forConcurrently keys $ \key -> atomically $ getPutLock getLock key name
    -- only this withGetLocks would be holding the locks,
    -- so it's safe to combine all lock releases into one transaction
    releaseLocks = atomically . mapM_ takeTMVar

-- getLock and putTMVar can be in one transaction on the assumption that getLock doesn't write in case the lock already exists,
-- and in case it is created and added to some shared resource (we use TMap) it also helps avoid contention for the newly created lock.
getPutLock :: (k -> STM Lock) -> k -> String -> STM Lock
getPutLock getLock key name = getLock key >>= \l -> putTMVar l name $> l
