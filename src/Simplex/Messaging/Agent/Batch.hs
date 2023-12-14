{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}

module Simplex.Messaging.Agent.Batch where

import Control.Monad (unless)
import Control.Monad.Except (throwError, tryError)
import Data.Traversable (for)
import GHC.Stack (HasCallStack)
import Simplex.Messaging.Agent.Client (AgentClient, withStore')
import Simplex.Messaging.Agent.Env.SQLite (AgentMonad, AgentMonad')
import Simplex.Messaging.Agent.Protocol (AgentErrorType)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Batch
import UnliftIO (atomically, newTVarIO, stateTVar)
import Control.Logger.Simple
import Simplex.Messaging.Util (tshow)

data AgentDB
type instance BatchArgs AgentDB = DB.Connection
type instance BatchError AgentDB = AgentErrorType
type AgentBatch m = BatchVar AgentDB m

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
    runEContT (processAgentBatch c agents) $ either (logError  . tshow) pure
    processAgentBatchAll c agentBatch

processAgentBatch :: AgentMonad' m => AgentClient -> [BatchOperation AgentDB m] -> BatchT AgentErrorType m ()
processAgentBatch c batch = do
  actions <- liftEContError . withStore' c $ \db -> do -- XXX: may throw SEInternal when its `withTransaction` failed somehow.
    -- XXX: perhaps that error should be broadcasted to all the actions depending on it (may trigger handler stampede)
    for batch $ \BatchOperation {step, next} -> do
      tryError (step db) >>= \case
        Right ok -> pure $ next ok
        Left err -> pure $ logError (tshow err)
  sequence_ actions
