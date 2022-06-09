{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( NtfSubSupervisor (..),
    newNtfSubSupervisor,
    -- addNtfSubSupervisor,
    addNtfSubWorker,
    setNtfSubWorkerSemaphore,
    nsUpdateNtfToken,
    nsUpdateNtfToken',
    nsRemoveNtfToken,
    addRcvQueueToNtfSubQueue,
  )
where

import Control.Concurrent.Async (Async)
import Control.Monad
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Monad (AgentMonad)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (NtfTknStatus (NTActive))
import Simplex.Messaging.Protocol (ProtocolServer (..))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO (async)
import UnliftIO.STM

data NtfSubSupervisor = NtfSubSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue RcvQueue, -- TODO command type to support deletion via supervisor
    ntfSubWorkers :: TMap ProtocolServer (TMVar (), Async ())
  }

newNtfSubSupervisor :: Env -> STM NtfSubSupervisor
newNtfSubSupervisor agentEnv = do
  let qSize = tbqSize $ config agentEnv
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize -- bigger queue size?
  ntfSubWorkers <- TM.empty
  pure
    NtfSubSupervisor
      { ntfTkn,
        -- ntfSubSupervisor,
        ntfSubQ,
        ntfSubWorkers
      }

addNtfSubWorker :: MonadUnliftIO m => NtfSubSupervisor -> ProtocolServer -> (TMVar () -> m ()) -> m ()
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

nsUpdateNtfToken :: AgentMonad m => NtfSubSupervisor -> NtfToken -> m ()
nsUpdateNtfToken ns tkn =
  atomically $ writeTVar (ntfTkn ns) (Just tkn)

nsUpdateNtfToken' :: NtfSubSupervisor -> NtfToken -> STM ()
nsUpdateNtfToken' ns tkn =
  writeTVar (ntfTkn ns) (Just tkn)

nsRemoveNtfToken :: AgentMonad m => NtfSubSupervisor -> m ()
nsRemoveNtfToken ns =
  atomically $ writeTVar (ntfTkn ns) Nothing

addRcvQueueToNtfSubQueue :: NtfSubSupervisor -> RcvQueue -> STM ()
addRcvQueueToNtfSubQueue ns rq = do
  tkn_ <- readTVar $ ntfTkn ns
  forM_ tkn_ $ \NtfToken {ntfTknStatus} ->
    when (ntfTknStatus == NTActive) $
      writeTBQueue (ntfSubQ ns) rq
