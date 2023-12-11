{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Batch where

import Control.Monad.IO.Class (MonadIO)
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

data Batch op m = forall a. Batch (BatchStep op m a) (a -> BatchT m ()) -- XXX: add `TypeRep r` to recover final result?

type family BatchStep op (m :: Type -> Type) a
