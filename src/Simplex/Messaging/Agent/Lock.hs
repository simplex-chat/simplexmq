module Simplex.Messaging.Agent.Lock
  ( Lock,
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
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import UnliftIO.Async (forConcurrently)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar Text

createLockIO :: IO Lock
createLockIO = newEmptyTMVarIO
{-# INLINE createLockIO #-}

withLock :: MonadUnliftIO m => Lock -> Text -> ExceptT e m a -> ExceptT e m a
withLock lock name = ExceptT . withLock' lock name . runExceptT
{-# INLINE withLock #-}

withLock' :: MonadUnliftIO m => Lock -> Text -> m a -> m a
withLock' lock name =
  E.bracket_
    (atomically $ putTMVar lock name)
    (void . atomically $ takeTMVar lock)

withGetLock :: MonadUnliftIO m => (k -> Text -> IO Lock) -> k -> Text -> m a -> m a
withGetLock getPutLock key name a =
  E.bracket
    (liftIO $ getPutLock key name)
    (atomically . takeTMVar)
    (const a)

withGetLocks :: MonadUnliftIO m => (k -> Text -> IO Lock) -> Set k -> Text -> m a -> m a
withGetLocks getPutLock keys name = E.bracket holdLocks releaseLocks . const
  where
    holdLocks = forConcurrently (S.toList keys) $ \key -> liftIO $ getPutLock key name
    releaseLocks = mapM_ (atomically . takeTMVar)
