module Simplex.Messaging.Agent.Lock where

import Control.Monad (void)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
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

withGetLock :: MonadUnliftIO m => STM Lock -> String -> m a -> m a
withGetLock getLock name a =
  E.bracket
    (atomically $ getLock >>= \l -> putTMVar l name $> l)
    (atomically . takeTMVar)
    (const a)
