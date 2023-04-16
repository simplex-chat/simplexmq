{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.Lock where

import Control.Concurrent.STM (retry)
import Control.Monad (unless, void)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
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

waitForLock :: Lock -> STM ()
waitForLock lock = isEmptyTMVar lock >>= (`unless` retry)

withGetLock :: MonadUnliftIO m => STM Lock -> String -> m a -> m a
withGetLock getLock name a =
  E.bracket
    (atomically $ getLock >>= \l -> putTMVar l name $> l)
    (atomically . takeTMVar)
    (const a)

withLockMap :: (Ord k, MonadUnliftIO m) => TMap k Lock -> k -> String -> m a -> m a
withLockMap locks key = withGetLock $ TM.lookup key locks >>= maybe newLock pure
  where
    newLock = createLock >>= \l -> TM.insert key l locks $> l
