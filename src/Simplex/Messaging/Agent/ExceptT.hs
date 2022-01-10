{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.ExceptT where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import UnliftIO.Exception (Exception)
import qualified UnliftIO.Exception as E

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO :: ((forall a. ExceptT e m a -> IO a) -> IO b) -> ExceptT e m b
  withRunInIO exceptToIO =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        exceptToIO $ run . (either (E.throwIO . InternalException) return <=< runExceptT)
