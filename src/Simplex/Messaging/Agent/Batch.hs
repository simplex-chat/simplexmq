{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Batch where

import Control.Monad.Except
import Data.Composition ((.:), (.:.))
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..), ConnId)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.Store

data AgentBatch m a
  = ABPure (Either AgentErrorType a)
  | ABLock {lockConnId :: ConnId, lockName :: String, next_ :: m (AgentBatch m a)}
  | forall b. ABDatabase {dbAction :: DB.Connection -> IO (Either StoreError b), next :: b -> m (AgentBatch m a)}
  | forall b. ABBind {bindAction :: m (AgentBatch m b), next :: b -> m (AgentBatch m a)}
  -- | forall b. ABBatch_ {actions_ :: [m (AgentBatch m b)], next_ :: m (AgentBatch m a)}

runAgentBatch :: forall a m. AgentMonad m => AgentClient -> [m (AgentBatch m a)] -> m [Either AgentErrorType a]
runAgentBatch c as = mapM batchResult =<< execAgentBatch c as
  where
    batchResult :: AgentBatch m a -> m (Either AgentErrorType a)
    batchResult = \case
      ABPure r -> pure r
      _ -> throwError $ INTERNAL "incomplete batch processing"

execAgentBatch :: AgentMonad m => AgentClient -> [m (AgentBatch m a)] -> m [AgentBatch m a]
execAgentBatch c [a] = run =<< tryError a 
  where
    run (Left e) = pure [ABPure $ Left e]
    run (Right r) = case r of
      ABPure r' -> pure [ABPure r']
      ABLock {lockConnId, lockName, next_} -> withConnLock c lockConnId lockName $ execAgentBatch c [next_]
      ABDatabase {dbAction, next} -> do
        runExceptT (withStore c dbAction) >>= \case
          Left e -> pure [ABPure $ Left e]
          Right r' -> execAgentBatch c [next r']
      ABBind {bindAction, next} -> tryError bindAction >>= \case
        Left e -> pure [ABPure $ Left e]
        Right r' -> case r' of
          ABPure (Right r'') -> execAgentBatch c [next r'']
          ABPure (Left e) -> pure [ABPure $ Left e]
          r'' -> do
            r3 <- runAgentBatch c [pure r'']
            case r3 of
              (Right r4 : _) -> execAgentBatch c [next r4]
              (Left e : _) -> pure [ABPure $ Left e]
              _ -> pure [ABPure $ Left $ INTERNAL "bad batch processing"]
            
        
      -- ABBatch_ {actions_, next_} -> do
      --   rs <- mapM run actions
      --   forM_ rs $ \r -> execAgentBatch c [pure r]
      --   next_
execAgentBatch _ _ = throwError $ INTERNAL "not implemented"

-- mapMB_ :: Monad m => (b -> m (AgentBatch m a)) -> [b] -> m (AgentBatch m ()) -> m (AgentBatch m ())
-- mapMB_ f as next = (`ABBatch_` next) <$> mapM f as

pureB :: Monad m => a -> m (AgentBatch m a)
pureB = pure . ABPure . Right

withConnLockB :: Monad m => ConnId -> String -> m (AgentBatch m a) -> m (AgentBatch m a)
withConnLockB = pure .:. ABLock

withStoreB :: Monad m => (DB.Connection -> IO (Either StoreError b)) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
withStoreB = pure .: ABDatabase

bindB :: Monad m => m (AgentBatch m b) -> (b -> m (AgentBatch m a)) -> m (AgentBatch m a)
bindB = pure .: ABBind
