{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Batch where

import Control.Monad
import Control.Monad.Error.Class (MonadError (..)) -- XXX: see the notes in MonadError instance
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, liftIO)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.State.Strict (MonadState, StateT (..), evalStateT, get, modify')
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Cont (ContT (..))
import Data.Kind (Type)
import UnliftIO (bracket)

type Parent env err m = (MonadReader env m, MonadError err m, MonadUnliftIO m)

example ::
  forall env err m.
  Parent env err m => -- Got to be preserved
  m Int -- produce result in Parent monad
example = do
  finalResult <- runBatched $ do
    -- prepare work
    items <- pure "work items"
    -- start running
    rs <- forM items $ \item -> do
      dbResult <- batchOperation SDB1 $ \ExDB -> do
        liftIO $ putStrLn ("operation on DB1 for item " <> show item)
        pure FancyResult
      batchOperation SNet $ \ExSocket exInt -> do
        liftIO $ putStrLn $ "Sending " <> show dbResult <> " to channel " <> show exInt
      pure (dbResult == FancyResult, item) -- the action that will continue with the results later (can batch more actions)
      -- collect final result?
    liftIO $ print rs
  -- pure ()
  pure $ length $ show finalResult

btwNoBrackets :: MonadUnliftIO m => m ()
btwNoBrackets =
  flip runContT pure $ do
    -- no MonadUnliftIO for ContT
    lift . bracket (liftIO $ putStrLn "preserve unliftio") pure . const $ do
      pure () -- lost ContT - no batching inside brackets

-- a probe type to avoid confusion when reading type elaboration output
data FancyResult = FancyResult
  deriving (Eq, Show)

runBatched :: Parent env err m => BatchT () m () -> m ()
runBatched action = runBatchT $ action <* processAll

-- | Process all batched items until no more items got batched.
processAll :: Parent env err m => BatchT () m ()
processAll =
  get >>= \case
    [] -> pure ()
    batched -> process batched >> processAll

-- * Specific things

-- | Process all currently batched items.
-- Their continuations can produce more operations.
process :: Parent env err m => [ABatch m] -> BatchT () m ()
process batched = do
  -- TODO: partition by op?
  runDb1 batched
  runDb2 batched
  runNet batched

data Op
  = DB1
  | DB2
  | Net

runDb1 :: Parent env err m => [ABatch m] -> BatchT () m ()
runDb1 batch =
  withExDB $ \db ->
    forM_ batch $ \case
      ABatch SDB1 db_ma aBb -> lift (db_ma db) >>= aBb
      _ -> pure ()

runDb2 :: Parent env err m => [ABatch m] -> BatchT () m ()
runDb2 batch =
  withExDB $ \db ->
    forM_ batch $ \case
      ABatch SDB2 action next -> lift (action db) >>= next
      _ -> pure ()

runNet :: Parent env err m => [ABatch m] -> BatchT () m ()
runNet batch =
  withExSocket $ \sock ->
    forM_ (zip [0 :: Int ..] batch) $ \case
      (ix, ABatch SNet action next) -> lift (action sock ix) >>= next
      _ -> pure ()

data ExDB = ExDB

withExDB :: (ExDB -> BatchT r m a) -> BatchT r m a
withExDB = error "produce DB handle, run transcation, commit or abort, close DB handle"

data ExSocket = ExSocket

withExSocket :: (ExSocket -> BatchT r m a) -> BatchT r m a
withExSocket = error "produce DB handle, run transcation, commit or abort, close DB handle"

type family Batched (b :: Op) m a where
  Batched DB1 m a = ExDB -> m a
  Batched DB2 m a = ExDB -> m a
  Batched Net m a = ExSocket -> Int -> m a

data ABatch m = forall op a. ABatch (SOp op) (Batched op m a) (a -> BatchT () m ()) -- XXX: add `TypeRep r` to recover final result?

data SOp :: Op -> Type where
  SDB1 :: SOp DB1
  SDB2 :: SOp DB2
  SNet :: SOp Net

-- the magic (:
batchOperation :: Parent env err m => SOp op -> Batched op m a -> BatchT () m a
batchOperation op action = BatchT $ ContT $ \next ->
  modify' (ABatch op action (stateToBatch . next) :)

-------------

newtype BatchT r m a = BatchT {unBatchT :: ContT r (StateT [ABatch m] m) a}
  deriving newtype (Functor, Applicative, Monad, MonadIO)
  deriving newtype (MonadState [ABatch m]) -- for batch tracking. StateT over IO sucks, should really be a mutable var.
  -- deriving newtype (MonadCont) -- provides callCC, which is not what we want. Use ContT directly.

-- instance (Parent env err m) => MonadError err (BatchT r m) where
--   throwError e = BatchT . lift . lift $ throwError e
--   catchError :: BatchT r m a -> (err -> BatchT r m a) -> BatchT r m a
--   catchError (BatchT csma) ema =
--     BatchT $ ContT $ \next -> StateT $ \s ->
--       -- unroll batch context
--       -- running in m, UnliftIO is possible now
--       runStateT (runContT csma next) s -- unroll initial action
--         `catch` \e ->
--           runStateT (runContT (unBatchT $ ema e) next) s -- unroll catch action
--           -- XXX: all the new batched items from initial action are discarded
--           -- TODO: with mutable state ref the items would be batched up until the fail point

instance MonadTrans (BatchT r) where
  lift :: Monad m => m a -> BatchT r m a
  lift ma = BatchT $ ContT $ \a_sma -> lift ma >>= a_sma

runBatchT :: Monad m => BatchT a m a -> m a
runBatchT = flip evalStateT [] . flip runContT pure . unBatchT

stateToBatch :: Parent env err m => StateT [ABatch m] m () -> BatchT r m ()
stateToBatch smu = BatchT $ ContT $ \next -> smu >>= next
