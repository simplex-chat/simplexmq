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
import Data.Kind (Type)
import Data.List (foldl')
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store
import UnliftIO

data Batch op e m a
  = BEff (Eff op e m a)
  | BBind (BindCont op e m a)

data Eff op e m a
  = BPure (Either e a)
  | BEffect (EffectCont op e m a)
  | BEffects_ (EffectsCont_ op e m a)

data BindCont op e m a = forall b. BindCont {bindAction :: m (Batch op e m b), next :: b -> m (Batch op e m a)}

data EffectCont op e m a = forall b. EffectCont {effect :: op m b, next :: b -> m (Batch op e m a)}

data EffectsCont_ op e m a = EffectsCont_ {effects_ :: [op m ()], next_ :: m (Batch op e m a)}

class (MonadIO m, MonadError e m) => BatchEffect op cxt e m | op -> cxt, op -> e where
  execBatchConts :: cxt -> [EffectCont op e m a] -> m [m (Batch op e m a)]
  execBatchEffects :: cxt -> [op m a] -> m [Either e a]
  batchError :: String -> e

type AgentBatch m a = Batch AgentBatchEff AgentErrorType m a

data AgentBatchEff (m :: Type -> Type) b = ABDatabase {dbAction :: DB.Connection -> IO (Either StoreError b)}

instance AgentMonad m => BatchEffect AgentBatchEff AgentClient AgentErrorType m where
  execBatchConts c conts = mapM (\(EffectCont (ABDatabase a) next) -> either (pureB_ . Left) next <$> tryError (withStore c a)) conts
  execBatchEffects c as = mapM (\(ABDatabase a) -> runExceptT $ withStore c a) as
  batchError = INTERNAL

unBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> m (Batch op e m a) -> m a
unBatch c a = runBatch c [a] >>= oneResult
  where
    -- TODO something smarter than "head" to return error if there is more/less results
    oneResult :: [Either e a] -> m a
    oneResult = liftEither . head

evaluateB :: forall op e m a. MonadError e m => m (Batch op e m a) -> m (Eff op e m a)
evaluateB b = tryEval b evalB
  where
    tryEval :: m (Batch op e m c) -> (Batch op e m c -> m (Eff op e m d)) -> m (Eff op e m d)
    tryEval a eval = tryError a >>= either evalErr eval
    evalB = \case
      BBind (BindCont a next) -> evaluateBind a next
      BEff r -> pure r
    evaluateBind :: forall b. m (Batch op e m b) -> (b -> m (Batch op e m a)) -> m (Eff op e m a)
    evaluateBind a next = tryEval a evalBind
      where
        evalBind :: Batch op e m b -> m (Eff op e m a)
        evalBind = \case
          BBind (BindCont a' next') -> evaluateBind a' (next' @>=> next)
          BEff r -> case r of
            BPure v -> either evalErr (evaluateB . next) v
            BEffect (EffectCont op next') -> pure $ BEffect $ EffectCont op (next' @>=> next)
            BEffects_ (EffectsCont_ ops next_') -> pure $ BEffects_ $ EffectsCont_ ops (next_' @>>= next)
    evalErr = pure . BPure . Left

type EIORef e a = IORef (Either e a)

runBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> [m (Batch op e m a)] -> m [Either e a]
runBatch c as = do
  rs <- replicateM (length as) $ newIORef notEvaluated
  exec $ zip rs as
  mapM readIORef rs
  where
    notEvaluated = Left $ batchError @op @cxt @e @m "not evaluated"
    exec :: [(EIORef e b, m (Batch op e m b))] -> m ()
    exec [] = pure ()
    exec as' = do
      (es, bs) <- partitionSndEithers <$> mapM (\(r, a) -> (r,) <$> tryError (evaluateB a)) as'
      forM_ es $ \(r, e) -> writeIORef r $ Left e
      unless (null bs) $ do
        let (vs, effs, effs_) = foldl' addBatch ([], [], []) bs
        forM_ vs $ \(r, v) -> writeIORef r v
        bs' <- execEffs effs
        bs'' <- execEffs_ effs_
        exec $ bs' <> bs''
        where
          execEffs [] = pure []
          execEffs effs =
            let (rs, conts) = unzip effs
             in zip rs <$> execBatchConts c conts
          execEffs_ [] = pure []
          execEffs_ effs_ = do
            let ops_ = concatMap (\(_, EffectsCont_ ops _) -> ops) effs_
            void $ execBatchEffects c ops_
            pure $ map (\(r, EffectsCont_ _ next_) -> (r, next_)) effs_
    partitionSndEithers :: [(c, Either e d)] -> ([(c, e)], [(c, d)])
    partitionSndEithers = foldl' add ([], [])
      where
        add (es, ds) (r, v) = either (\e -> ((r, e) : es, ds)) (\d -> (es, (r, d) : ds)) v
    addBatch ::
      ([(EIORef e b, Either e b)], [(EIORef e b, EffectCont op e m b)], [(EIORef e b, EffectsCont_ op e m b)]) ->
      (EIORef e b, Eff op e m b) ->
      ([(EIORef e b, Either e b)], [(EIORef e b, EffectCont op e m b)], [(EIORef e b, EffectsCont_ op e m b)])
    addBatch (vs, effs, effs_) = \case
      (r, BPure v) -> ((r, v) : vs, effs, effs_)
      (r, BEffect cont) -> (vs, (r, cont) : effs, effs_)
      (r, BEffects_ cont) -> (vs, effs, (r, cont) : effs_)

pureB_ :: Monad m => Either e a -> m (Batch op e m a)
pureB_ = pure . BEff . BPure

pureB :: Monad m => a -> m (Batch op e m a)
pureB = pureB_ . Right

infixl 0 @>>=, @>>, @>=>

(@>>=) :: Monad m => m (Batch op e m b) -> (b -> m (Batch op e m a)) -> m (Batch op e m a)
(@>>=) = pure . BBind .: BindCont

(@>>) :: Monad m => m (Batch op e m b) -> m (Batch op e m a) -> m (Batch op e m a)
(@>>) f = (f @>>=) . const

(@>=>) :: Monad m => (c -> m (Batch op e m b)) -> (b -> m (Batch op e m a)) -> c -> m (Batch op e m a)
(@>=>) f g x = f x @>>= g

withStoreB :: Monad m => (DB.Connection -> IO (Either StoreError b)) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB f = pure . BEff . BEffect . EffectCont (ABDatabase f)

withStoreB' :: Monad m => (DB.Connection -> IO b) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB' f = withStoreB (fmap Right . f)

withStoreBatchB' :: Monad m => [DB.Connection -> IO ()] -> m (AgentBatch m a) -> m (AgentBatch m a)
withStoreBatchB' fs = pure . BEff . BEffects_ . EffectsCont_ (map (ABDatabase . (fmap Right .)) fs)
