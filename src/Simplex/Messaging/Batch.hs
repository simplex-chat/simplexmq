{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Batch where

import Control.Monad.Error.Class (MonadError (..))
import Control.Monad.Trans
import Control.Monad.Trans.Cont (ContT (..))
import Data.Kind (Type)
import UnliftIO (TVar, atomically, modifyTVar')

type BatchT m = ContT () m

batchOperation :: MonadIO m => BatchVar op m -> BatchStep op m r -> BatchT m r
batchOperation st action = do
  -- traceM $ "batchOperation for " <> show (typeRep op)
  ContT $ \next -> do
    -- traceM $ "batchOperation for " <> show (typeRep op) <> " (inside)"
    let batch = Batch action $ \r -> ContT $ \now -> now () >> next r
    atomically $ modifyTVar' st (batch :)

type BatchVar op m = TVar [Batch op m]

data Batch op m = forall a. Batch (BatchStep op m a) (a -> BatchT m ())

type family BatchStep op (m :: Type -> Type) a

-- XXX: Doesn't appear to work on tests
-- instance MonadError e m => MonadError e (ContT r m) where
--   throwError = lift . throwError
--   {-# INLINE throwError #-}
--   catchError op h = ContT $ \k -> catchError (runContT op k) (\e -> runContT (h e) k)
--   {-# INLINE catchError #-}

-- XXX: Unusable to translate between (MonadError e m, MonadError f n) => ContT x n r -> ContT x m r
-- unless errors `e` and `f` can accomodate each other (which if false in our case, with ChatErrorType > AgentErrorType)
-- can be solved with functor encoding and Fix, but...
isoContT :: (forall a. n a -> m a) -> (forall a. m a -> n a) -> ContT x n r -> ContT x m r
isoContT n_m m_n cxnr = ContT $ \r_mx -> n_m . runContT cxnr $ m_n . r_mx

-- XXX: The errors can be subsumed, but the monads are still ISO
-- Should not be a problem, as the ISO is most likely "dropping to IO and applying a different ReaderT"
isoEContT :: (forall a. n a -> m a) -> (forall a. m a -> n a) -> (e -> f) -> EContT x n e r -> EContT x m f r
isoEContT n_m m_n e_f xner = EContT $ \fr_mx ->
  n_m $ runEContT xner $ \case
    Left e -> m_n $ fr_mx (Left $ e_f e)
    Right r -> m_n $ fr_mx (Right r)

-- Much easier, with shared m (which is common base like IO, from which other context can be restored)
mapEContT :: (e -> f) -> EContT x m e r -> EContT x m f r
mapEContT e_f xmer = EContT $ \er_mx ->
  runEContT xmer $ \case
    Left e -> er_mx (Left $ e_f e)
    Right r -> er_mx (Right r)

newtype EContT x m e r = EContT {runEContT :: (Either e r -> m x) -> m x}

-- pretty straight-forward embedding of ExceptT
instance MonadError e (EContT x m e) where
  throwError e = EContT $ \er_mx -> er_mx $ Left e
  catchError ma e_ma = EContT $ \er_mx ->
    runEContT ma $ \case
      Left e -> runEContT (e_ma e) er_mx
      Right r -> er_mx (Right r)

instance Functor (EContT x m e) where
  fmap f ma = EContT $ \er_mx -> runEContT ma $ er_mx . fmap f

instance Applicative (EContT x m e) where
  pure x = EContT $ \er_mx -> er_mx (Right x)
  mf <*> ma = EContT $ \er_mx ->
    runEContT mf $ \case
      Left e -> er_mx (Left e)
      Right f -> runEContT ma $ \case
        Left e -> er_mx (Left e)
        Right a -> er_mx (Right $ f a)

instance Monad (EContT x m e) where
  ma >>= amb = EContT $ \er_mx ->
    runEContT ma $ \case
      Right a -> runEContT (amb a) er_mx
      Left e -> er_mx (Left e)

-- instance MonadTrans (EContT x e) where
instance MonadIO m => MonadIO (EContT x m e) where
  liftIO io = EContT $ \er_mx ->
    liftIO io >>= er_mx . Right

type EBatchT m e = EContT () m e

type EBatchVar op m = TVar [EBatch op m]

-- data Batch op m = forall a. Batch (BatchStep op m a) (a -> BatchT m ())
data EBatch op m = forall a. EBatch (EBatchStep op a) (Either (EBatchError op) a -> EBatchT m (EBatchError op) ())

type family EBatchArgs op
type family EBatchError op
type EBatchStep op a = EBatchArgs op -> IO (Either (EBatchError op) a) -- enforce step structure

ebatchOperation :: MonadIO m => TVar [EBatch op m] -> (EBatchArgs op -> IO (Either (EBatchError op) r)) -> EBatchT m (EBatchError op) r
ebatchOperation st action =
  EContT $ \er_Mu -> do
    let batch = EBatch action $ \er -> EContT $ \eu_Mu__Mu -> eu_Mu__Mu (Right ()) >> er_Mu er
    atomically $ modifyTVar' st (batch :)

type EContT' x m e r = ContT x m (Either e r) -- sure... but
-- instance MonadError e (ContT x m (Either e r)) where -- XXX: syntactically impossible due to `r` has to be outside so the kind would be `T->T`
-- instance MonadError e (\r -> ContT x m (Either e r)) where -- like this
