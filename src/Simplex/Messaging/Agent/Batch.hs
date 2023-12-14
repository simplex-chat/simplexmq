{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Agent.Batch where

import Control.Logger.Simple
import Control.Monad (unless)
import Control.Monad.Except (throwError, tryError)
import Control.Monad.Reader (ReaderT)
import Data.Traversable (for)
import GHC.Stack (HasCallStack)
import Simplex.Messaging.Agent.Client (AgentClient, withStore')
import Simplex.Messaging.Agent.Env.SQLite (AgentMonad, AgentMonad', Env)
import Simplex.Messaging.Agent.Protocol (AgentErrorType)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Batch
import Simplex.Messaging.Util (tshow)
import UnliftIO (atomically, newTVarIO, stateTVar)

data AgentDB
type instance BatchArgs AgentDB = DB.Connection
type instance BatchError AgentDB = AgentErrorType
type AgentBatch m = BatchVar AgentDB m
type AgentEnvBatch m = AgentBatch (ReaderT Env m)

execAgentBatch :: (AgentMonad m, HasCallStack) => AgentClient -> (AgentBatch m -> BatchT AgentErrorType m a) -> m a
execAgentBatch c action = execAgentBatch' c action >>= either throwError pure

execAgentBatch' :: (AgentMonad' m, HasCallStack) => AgentClient -> (AgentBatch m -> BatchT AgentErrorType m a) -> m (Either AgentErrorType a)
execAgentBatch' c action = do
  b <- newTVarIO []
  getResult <- execEContT $ action b
  processAgentBatchAll c b
  getResult

processAgentBatchAll :: AgentMonad' m => AgentClient -> AgentBatch m -> m ()
processAgentBatchAll c agentBatch = do
  agents <- atomically $ stateTVar agentBatch (,[])
  unless (null agents) $ do
    runEContT (processAgentBatch c agents) $ either (logError . tshow) pure
    processAgentBatchAll c agentBatch

processAgentBatch :: AgentMonad' m => AgentClient -> [BatchOperation AgentDB m] -> BatchT AgentErrorType m ()
processAgentBatch c batch = do
  actions <- liftEContError . withStore' c $ \db -> do
    -- XXX: may throw SEInternal when its `withTransaction` failed somehow.
    -- XXX: perhaps that error should be broadcasted to all the actions depending on it (may trigger handler stampede)
    for batch $ \BatchOperation {step, next} -> do
      tryError (step db) >>= \case
        Right ok -> pure $ next ok
        Left err -> pure $ logError (tshow err)
  sequence_ actions
