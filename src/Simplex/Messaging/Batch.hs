{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Batch where

import Control.Monad (unless)
import Control.Monad.Error.Class (MonadError (..), liftEither)
import Control.Monad.Except (runExceptT)
import Control.Monad.Trans (MonadTrans (..))
import Control.Monad.Trans.Except (ExceptT)
import GHC.Stack (HasCallStack)
import UnliftIO

-- * ContT fused with ExceptT to provide natural MonadError

newtype EContT e x m r = EContT {runEContT :: (Either e r -> m x) -> m x}

-- pretty straight-forward embedding of ExceptT
instance MonadError e (EContT e x m) where
  throwError e = EContT $ \er_mx -> er_mx $ Left e
  {-# INLINE throwError #-}

  catchError ma e_ma = EContT $ \er_mx ->
    runEContT ma $ \case
      Left e -> runEContT (e_ma e) er_mx
      Right r -> er_mx (Right r)
  {-# INLINE catchError #-}

liftEContError :: Monad m => ExceptT e m r -> EContT e x m r
liftEContError action = lift (runExceptT action) >>= liftEither

instance Functor (EContT e x m) where
  fmap f ma = EContT $ \er_mx -> runEContT ma $ er_mx . fmap f
  {-# INLINE fmap #-}

instance Applicative (EContT e x m) where
  pure x = EContT $ \er_mx -> er_mx (Right x)
  {-# INLINE pure #-}

  mf <*> ma = EContT $ \er_mx ->
    runEContT mf $ \case
      Left e -> er_mx (Left e)
      Right f -> runEContT ma $ \case
        Left e -> er_mx (Left e)
        Right a -> er_mx (Right $ f a)
  {-# INLINE (<*>) #-}

instance Monad (EContT e x m) where
  ma >>= amb = EContT $ \er_mx ->
    runEContT ma $ \case
      Right a -> runEContT (amb a) er_mx
      Left e -> er_mx (Left e)
  {-# INLINE (>>=) #-}

instance MonadTrans (EContT e x) where
  lift a = EContT $ \er_mx -> a >>= er_mx . Right
  {-# INLINE lift #-}

instance MonadIO m => MonadIO (EContT e x m) where
  liftIO io = EContT $ \er_mx -> liftIO io >>= er_mx . Right
  {-# INLINE liftIO #-}

-- XXX: The errors can be subsumed, but the monads are still ISO
-- Should not be a problem, as the ISO is most likely "dropping to IO and applying a different ReaderT"
isoEContT :: (forall a. n a -> m a) -> (forall a. m a -> n a) -> (e -> f) -> EContT e x n r -> EContT f x m r
isoEContT n_m m_n e_f xner = EContT $ \fr_mx ->
  n_m $ runEContT xner $ \case
    Left e -> m_n $ fr_mx (Left $ e_f e)
    Right r -> m_n $ fr_mx (Right r)

-- Much easier, with shared m (which is common base like IO, from which other context can be restored)
mapEContT :: (e -> f) -> EContT e x m r -> EContT f x m r
mapEContT e_f xmer = EContT $ \er_mx ->
  runEContT xmer $ \case
    Left e -> er_mx (Left $ e_f e)
    Right r -> er_mx (Right r)

-- | Recover final continuation result via mutable var.
execEContT :: (HasCallStack, MonadIO m) => EContT e () m r -> m (m (Either e r))
execEContT action = do
  result <- newEmptyMVar
  runEContT action $ \r -> liftIO (tryPutMVar result r) >>= \ok -> unless ok (error "already ran")
  pure $ tryTakeMVar result >>= maybe (error "did not run") pure

-- * Continuation batching

type BatchT e m = EContT e () m

type BatchVar op m = TVar [Batch op m]

data Batch op m = forall a.
  Batch
  { step :: BatchStep op a,
    next :: Either (BatchError op) a -> BatchT (BatchError op) m ()
  }

-- | Basic step structure for `batchOperation` wrappers.
type BatchStep op a = BatchArgs op -> IO (Either (BatchError op) a)

type family BatchArgs op
type family BatchError op

batchOperation :: forall op m r. MonadIO m => TVar [Batch op m] -> BatchStep op r -> BatchT (BatchError op) m r
batchOperation st step = do
  EContT $ \er_Mu -> do
    let next er = EContT $ \eu_Mu__Mu -> eu_Mu__Mu (Right ()) >> er_Mu er
    atomically $ modifyTVar' st (Batch {step, next} :)
