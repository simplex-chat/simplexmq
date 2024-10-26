module Simplex.Messaging.Agent.Lock
  ( Lock,
    createLock,
    createLockIO,
    withLock,
    withLock',
    withGetLock,
    withGetLocks,
  )
where

import Control.Monad (void)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as S
import UnliftIO.Async (forConcurrently)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar String

createLock :: STM Lock
createLock = newEmptyTMVar
{-# INLINE createLock #-}

createLockIO :: IO Lock
createLockIO = newEmptyTMVarIO
{-# INLINE createLockIO #-}

withLock :: MonadUnliftIO m => Lock -> String -> ExceptT e m a -> ExceptT e m a
withLock lock name = ExceptT . withLock' lock name . runExceptT
{-# INLINE withLock #-}

withLock' :: MonadUnliftIO m => Lock -> String -> m a -> m a
withLock' lock name =
  E.bracket_
    (atomically $ putTMVar lock name)
    (void . atomically $ takeTMVar lock)

withGetLock :: MonadUnliftIO m => (k -> STM Lock) -> k -> String -> m a -> m a
withGetLock getLock key name a =
  E.bracket
    (atomically $ getPutLock getLock key name)
    (atomically . takeTMVar)
    (const a)

withGetLocks :: MonadUnliftIO m => (k -> STM Lock) -> Set k -> String -> m a -> m a
withGetLocks getLock keys name = E.bracket holdLocks releaseLocks . const
  where
    holdLocks = forConcurrently (S.toList keys) $ \key -> atomically $ getPutLock getLock key name
    releaseLocks = mapM_ (atomically . takeTMVar)

-- getLock and putTMVar can be in one transaction on the assumption that getLock doesn't write in case the lock already exists,
-- and in case it is created and added to some shared resource (we use TMap) it also helps avoid contention for the newly created lock.
getPutLock :: (k -> STM Lock) -> k -> String -> STM Lock
getPutLock getLock key name = getLock key >>= \l -> putTMVar l name $> l
