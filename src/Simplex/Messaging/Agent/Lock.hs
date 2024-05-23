{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent.Lock
  ( Lock,
    createLock,
    withLock,
    withLock',
    withGetLock,
    withGetLocks,
  )
where

import Control.Logger.Simple
import Control.Monad (void)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Unlift
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import Simplex.Messaging.Util (tshow)
import UnliftIO.Async (forConcurrently)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type Lock = TMVar String

createLock :: STM Lock
createLock = newEmptyTMVar
{-# INLINE createLock #-}

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
    (logDebug ("withGetLock needs lock " <> T.pack name) >> atomically (getPutLock getLock key name))
    (\l -> atomically (takeTMVar l) >> logDebug ("withGetLock released lock " <> T.pack name))
    (\_ -> logDebug ("withGetLock has lock " <> T.pack name) >> a)

withGetLocks :: MonadUnliftIO m => (k -> STM Lock) -> Set k -> String -> m a -> m a
withGetLocks getLock keys name action =
  E.bracket holdLocks releaseLocks $ \_ -> do
    logDebug $ "withGetLocks has locks " <> tshow (length keys) <> " " <> T.pack name
    action
  where
    holdLocks = do
      logDebug $ "withGetLocks needs locks " <> tshow (length keys) <> " " <> T.pack name
      forConcurrently (S.toList keys) $ \key -> atomically $ getPutLock getLock key name
    releaseLocks ls = do
      mapM_ (atomically . takeTMVar) ls
      logDebug $ "withGetLocks released locks " <> tshow (length keys) <> " " <> T.pack name

-- getLock and putTMVar can be in one transaction on the assumption that getLock doesn't write in case the lock already exists,
-- and in case it is created and added to some shared resource (we use TMap) it also helps avoid contention for the newly created lock.
getPutLock :: (k -> STM Lock) -> k -> String -> STM Lock
getPutLock getLock key name = getLock key >>= \l -> putTMVar l name $> l
