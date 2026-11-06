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
import Data.Text (Text)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar Text

createLock :: STM Lock
createLock = newEmptyTMVar
{-# INLINE createLock #-}

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

withGetLock :: MonadUnliftIO m => (k -> IO Lock) -> k -> Text -> m a -> m a
withGetLock getLock key name a =
  E.bracket
    (liftIO $ getPutLock getLock key name)
    (atomically . takeTMVar)
    (const a)

withGetLocks :: MonadUnliftIO m => (k -> IO Lock) -> Set k -> Text -> m a -> m a
withGetLocks getLock keys name a = go (S.toList keys)
  where
    go [] = a
    go (k : ks) = withGetLock getLock k name (go ks)

getPutLock :: (k -> IO Lock) -> k -> Text -> IO Lock
getPutLock getLock key name = getLock key >>= \l -> atomically (putTMVar l name) $> l
