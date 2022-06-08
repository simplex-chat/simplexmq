{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( NtfSubSupervisor (..),
    newNtfSubSupervisor,
    addNtfSubSupervisor,
    addNtfSubWorker,
    setNtfSubWorkerSemaphore,
  )
where

import Control.Concurrent.Async (Async)
import Control.Monad
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Monad (AgentMonad)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Protocol (ProtocolServer (..))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO (async)
import UnliftIO.STM

data NtfSubSupervisor = NtfSubSupervisor
  { ntfSubSupervisor :: TVar (Maybe (Async ())),
    ntfSubQ :: TBQueue RcvQueue,
    ntfSubWorkers :: TMap ProtocolServer (TMVar (), Async ())
  }

newNtfSubSupervisor :: Env -> STM NtfSubSupervisor
newNtfSubSupervisor agentEnv = do
  let qSize = tbqSize $ config agentEnv
  ntfSubSupervisor <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize -- bigger queue size?
  ntfSubWorkers <- TM.empty
  return
    NtfSubSupervisor
      { ntfSubSupervisor,
        ntfSubQ,
        ntfSubWorkers
      }

addNtfSubSupervisor :: AgentMonad m => NtfSubSupervisor -> m () -> m ()
addNtfSubSupervisor ns action = do
  supervisor_ <- readTVarIO (ntfSubSupervisor ns)
  case supervisor_ of
    Nothing -> do
      nSubSupervisor <- async action
      atomically $ writeTVar (ntfSubSupervisor ns) $ Just nSubSupervisor
    Just _ -> pure ()

addNtfSubWorker :: AgentMonad m => NtfSubSupervisor -> ProtocolServer -> (TMVar () -> m ()) -> m ()
addNtfSubWorker ns srv action =
  atomically (TM.lookup srv (ntfSubWorkers ns)) >>= \case
    Nothing -> do
      workerSemaphore <- newTMVarIO ()
      ntfSubWorker <- async $ action workerSemaphore
      atomically $ TM.insert srv (workerSemaphore, ntfSubWorker) (ntfSubWorkers ns)
    Just (workerSemaphore, _) -> void . atomically $ tryPutTMVar workerSemaphore ()

setNtfSubWorkerSemaphore :: NtfSubSupervisor -> ProtocolServer -> STM ()
setNtfSubWorkerSemaphore ns srv =
  TM.lookup srv (ntfSubWorkers ns) >>= \case
    Just (workerSemaphore, _) -> void $ tryPutTMVar workerSemaphore ()
    Nothing -> pure ()
