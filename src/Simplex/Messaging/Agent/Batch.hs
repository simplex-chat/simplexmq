{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Batch where

import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.Composition ((.:))
import Data.Bifunctor (bimap)
import Data.Either (partitionEithers)
import Data.List (foldl')
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store
import UnliftIO

data Batch op e (m :: * -> *) a
  = BPure (Either e a)
  | BBind (BindCont op e m a)
  | BBatch_ (BatchCont_ op e m a)
  | BEffect (EffectCont op e m a)

-- TODO - type for first pass evaluations to remove binds and batches
-- data Evaluated op e m a
--   = EPure (Either e a)
--   | EBatch_ (EBatchCont_ op e m a)
--   | EEffect (EffectCont op e m a)

data BindCont op e m a = forall b. BindCont {bindAction :: m (Batch op e m b), next :: b -> m (Batch op e m a)}

-- data EvaluaterCont op e m a = 

-- TODO should batch be failable? probably so, it is failable in the current code. but then mixing batch effects with other effects can break the batch?
data BatchCont_ op e m a = forall b. BatchCont_ {actions_ :: [m (Batch op e m b)], next_ :: m (Batch op e m a)}

-- data EBatchCont_ op e m a = forall b. EBatchCont_ {effects :: [op m b]], next_ :: m (Batch op e m a)}

data EffectCont op e m a = forall b. EffectCont {effect :: op m b, next :: b -> m (Batch op e m a)}

class (MonadError e m, MonadIO m) => BatchEffect op cxt e m | op -> cxt, op -> e where
  execBatchEffects :: cxt -> [op m a] -> m [Either e a]
  batchError :: String -> e

type AgentBatch m a = Batch AgentBatchEff AgentErrorType m a

data AgentBatchEff (m :: * -> *) b = ABDatabase {dbAction :: DB.Connection -> IO (Either StoreError b)}

instance AgentMonad m => BatchEffect AgentBatchEff AgentClient AgentErrorType m where
  execBatchEffects c = \case
    (ABDatabase dbAction : _) -> (: []) <$> runExceptT (withStore c dbAction)
    _ -> throwError $ INTERNAL "not implemented"
  batchError = INTERNAL

runBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> [m (Batch op e m a)] -> m [Either e a]
runBatch c as = mapM batchResult =<< execBatch c as
  where
    batchResult :: Batch op e m a -> m (Either e a)
    batchResult = \case
      BPure r -> pure r
      _ -> throwError $ batchError @op @cxt @e @m "incomplete batch processing"

unBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> m (Batch op e m a) -> m a
unBatch c a = runBatch c [a] >>= oneResult
  where
    -- TODO something smarter than "head" to return error if there is more/less results
    oneResult :: [Either e a] -> m a
    oneResult = liftEither . head

type BRef op e m a = IORef (Batch op e m a)

execBatch' :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> [m (Batch op e m a)] -> m [Batch op e m a]
execBatch' c as = do
  rs <- replicateM (length as) $ newIORef notEvaluated
  exec . (zipWith (\r -> bimap (r,) (r,)) rs) =<< mapM tryError as
  mapM readIORef rs
  where
    notEvaluated = BPure $ Left $ batchError @op @cxt @e @m "not evaluated"
    exec :: [Either (BRef op e m a, e) (BRef op e m a, Batch op e m a)] -> m ()
    exec bs = do
      let (es, bs') = partitionEithers bs
          (vs, binds, batches, effs) = foldl' addBatch ([], [], [], []) bs' 
      forM_ es $ \(r, e) -> writeIORef r (BPure $ Left e)
      forM_ vs $ \(r, v) -> writeIORef r (BPure v)
      -- evaluate binds till pure or effect
      -- evaluate batches till pure or effect
      -- let (vs, bs'') = partitionEithers $ map (\case (r, BPure v) -> Left (r, v); b -> Right b) bs
      -- forM_ vs $ \(r, v) -> writeIORef r (BPure v)
      pure ()
    addBatch ::
      ([(BRef op e m a, Either e a)], [(BRef op e m a, BindCont op e m a)], [(BRef op e m a, BatchCont_ op e m a)], [(BRef op e m a, EffectCont op e m a)]) ->
      (BRef op e m a, Batch op e m a) ->
      ([(BRef op e m a, Either e a)], [(BRef op e m a, BindCont op e m a)], [(BRef op e m a, BatchCont_ op e m a)], [(BRef op e m a, EffectCont op e m a)])
    addBatch (vs, bs, bbs, effs) = \case
      (r, BPure v) -> ((r, v) : vs, bs, bbs, effs)
      (r, BBind cont) -> (vs, (r, cont) : bs, bbs, effs)
      (r, BBatch_ cont) -> (vs, bs, (r, cont) : bbs, effs)
      (r, BEffect op) -> (vs, bs, bbs, (r, op) : effs)

execBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> [m (Batch op e m a)] -> m [Batch op e m a]
execBatch c [a] = run =<< tryError a 
  where
    run (Left e) = pure [BPure $ Left e]
    run (Right r) = case r of
      BPure r' -> pure [BPure r']
      BBind (BindCont {bindAction, next}) -> tryError bindAction >>= \case
        Left e -> pure [BPure $ Left e]
        Right r' -> case r' of
          BPure (Right r'') -> execBatch c [next r'']
          BPure (Left e) -> pure [BPure $ Left e]
          r'' -> do
            r3 <- runBatch c [pure r'']
            case r3 of
              (Right r4 : _) -> execBatch c [next r4]
              (Left e : _) -> pure [BPure $ Left e]
              _ -> pure [BPure $ Left $ batchError @op @cxt @e @m "bad batch processing"]
      BBatch_ (BatchCont_ {actions_, next_}) -> do
        sequence actions_ >>= mapM_ (\r' -> execBatch c [pure r'])
        execBatch c [next_]
      BEffect (EffectCont op next) -> execBatchEffects c [op] >>= \case
        Left e : _ -> pure [BPure $ Left e]
        Right r' : _ -> execBatch c [next r']
        _ -> pure [BPure $ Left $ batchError @op @cxt @e @m "not implemented"]
execBatch _ _ = throwError $ batchError @op @cxt @e @m "not implemented"

pureB :: Monad m => a -> m (Batch op e m a)
pureB = pure . BPure . Right

infixl 0 @>>=, @>>

(@>>=) :: Monad m => m (Batch op e m b) -> (b -> m (Batch op e m a)) -> m (Batch op e m a)
(@>>=) = pure . BBind .: BindCont

(@>>) :: Monad m => m (Batch op e m b) -> m (Batch op e m a) -> m (Batch op e m a)
(@>>) m = (m @>>=) . const

batch :: Monad m => [m (Batch op e m b)] -> m (Batch op e m a) -> m (Batch op e m a)
batch = pure . BBatch_ .: BatchCont_

withStoreB :: Monad m => (DB.Connection -> IO (Either StoreError b)) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB f = pure . BEffect . EffectCont (ABDatabase f)

withStoreB' :: Monad m => (DB.Connection -> IO b) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB' f = withStoreB (fmap Right . f)
