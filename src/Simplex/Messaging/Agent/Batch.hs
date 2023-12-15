{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Batch where

import Control.Monad.Except
import Data.Composition ((.:))
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..))
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store

data Batch op e m a
  = BPure (Either e a)
  | forall b. BBind {bindAction :: m (Batch op e m b), next :: b -> m (Batch op e m a)}
  | forall b. BBatch_ {actions_ :: [m (Batch op e m b)], next_ :: m (Batch op e m a)}
  | BEffect (op m a)

class MonadError e m => BatchEffect op cxt e m | op -> cxt, op -> e where
  execBatchEffects :: cxt -> [op m a] -> m [Batch op e m a]
  batchError :: String -> e

type AgentBatch m a = Batch AgentBatchEff AgentErrorType m a

data AgentBatchEff m a = forall b. ABDatabase {dbAction :: DB.Connection -> IO (Either StoreError b), next :: b -> m (AgentBatch m a)}

instance AgentMonad m => BatchEffect AgentBatchEff AgentClient AgentErrorType m where
  execBatchEffects c = \case
    (ABDatabase {dbAction, next} : _) ->
      runExceptT (withStore c dbAction) >>= \case
        Left e -> pure [BPure $ Left e]
        Right r' -> execBatch c [next r']
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

execBatch :: forall a op cxt e m. BatchEffect op cxt e m => cxt -> [m (Batch op e m a)] -> m [Batch op e m a]
execBatch c [a] = run =<< tryError a 
  where
    run (Left e) = pure [BPure $ Left e]
    run (Right r) = case r of
      BPure r' -> pure [BPure r']
      BBind {bindAction, next} -> tryError bindAction >>= \case
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
      BBatch_ {actions_, next_} -> do
        sequence actions_ >>= mapM_ (\r' -> execBatch c [pure r'])
        execBatch c [next_]
      BEffect op -> execBatchEffects c [op]
execBatch _ _ = throwError $ batchError @op @cxt @e @m "not implemented"

pureB :: Monad m => a -> m (Batch op e m a)
pureB = pure . BPure . Right

infixl 0 @>>=, @>>

(@>>=) :: Monad m => m (Batch op e m b) -> (b -> m (Batch op e m a)) -> m (Batch op e m a)
(@>>=) = pure .: BBind

(@>>) :: Monad m => m (Batch op e m b) -> m (Batch op e m a) -> m (Batch op e m a)
(@>>) m = (m @>>=) . const

batch :: Monad m => [m (Batch op e m b)] -> m (Batch op e m a) -> m (Batch op e m a)
batch as = pure . BBatch_ as

withStoreB :: Monad m => (DB.Connection -> IO (Either StoreError b)) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB = pure . BEffect .: ABDatabase

withStoreB' :: Monad m => (DB.Connection -> IO b) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB' f = withStoreB (fmap Right . f)
