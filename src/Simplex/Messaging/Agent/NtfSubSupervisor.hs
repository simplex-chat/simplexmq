{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( NtfSubSupervisor (..),
    NtfSubSupervisorInstruction (..),
    newNtfSubSupervisor,
    addNtfSubWorker,
    addNtfSubSMPWorker,
    removeNtfSubWorker,
    removeNtfSubSMPWorker,
    nsUpdateToken,
    nsUpdateToken',
    nsRemoveNtfToken,
    addNtfSubSupervisorInstruction,
    addNtfSubSupervisorInstruction',
    closeNtfSubSupervisor,
  )
where

import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Monad
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Monad (AgentMonad)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (NtfTknStatus (NTActive))
import Simplex.Messaging.Protocol (ProtocolServer (..), SMPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO (async)
import UnliftIO.STM

data NtfSubSupervisor = NtfSubSupervisor
  { ntfTkn :: TVar (Maybe NtfToken),
    ntfSubQ :: TBQueue (RcvQueue, NtfSubSupervisorInstruction),
    ntfSubWorkers :: TMap NtfServer (TMVar (), Async ()),
    ntfSubSMPWorkers :: TMap SMPServer (TMVar (), Async ())
  }

data NtfSubSupervisorInstruction = NSICreate | NSIDelete

newNtfSubSupervisor :: Env -> STM NtfSubSupervisor
newNtfSubSupervisor agentEnv = do
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue (ntfSubTbqSize $ config agentEnv)
  ntfSubWorkers <- TM.empty
  ntfSubSMPWorkers <- TM.empty
  pure NtfSubSupervisor {ntfTkn, ntfSubQ, ntfSubWorkers, ntfSubSMPWorkers}

addNtfSubWorker :: MonadUnliftIO m => NtfSubSupervisor -> NtfServer -> (TMVar () -> m ()) -> m ()
addNtfSubWorker ns = addNtfSubWorker_ $ ntfSubWorkers ns

addNtfSubSMPWorker :: MonadUnliftIO m => NtfSubSupervisor -> SMPServer -> (TMVar () -> m ()) -> m ()
addNtfSubSMPWorker ns = addNtfSubWorker_ $ ntfSubSMPWorkers ns

addNtfSubWorker_ :: MonadUnliftIO m => TMap NtfServer (TMVar (), Async ()) -> ProtocolServer -> (TMVar () -> m ()) -> m ()
addNtfSubWorker_ workerMap srv action =
  atomically (TM.lookup srv workerMap) >>= \case
    Nothing -> do
      workAvailable <- newTMVarIO ()
      ntfSubWorker <- async $ action workAvailable
      atomically $ TM.insert srv (workAvailable, ntfSubWorker) workerMap
    Just (workAvailable, _) -> void . atomically $ tryPutTMVar workAvailable ()

removeNtfSubWorker :: MonadUnliftIO m => NtfSubSupervisor -> NtfServer -> m ()
removeNtfSubWorker ns srv = atomically $ TM.delete srv (ntfSubWorkers ns)

removeNtfSubSMPWorker :: MonadUnliftIO m => NtfSubSupervisor -> SMPServer -> m ()
removeNtfSubSMPWorker ns srv = atomically $ TM.delete srv (ntfSubSMPWorkers ns)

nsUpdateToken :: AgentMonad m => NtfSubSupervisor -> NtfToken -> m ()
nsUpdateToken ns tkn =
  atomically $ writeTVar (ntfTkn ns) (Just tkn)

nsUpdateToken' :: NtfSubSupervisor -> NtfToken -> STM ()
nsUpdateToken' ns tkn =
  writeTVar (ntfTkn ns) (Just tkn)

nsRemoveNtfToken :: AgentMonad m => NtfSubSupervisor -> m ()
nsRemoveNtfToken ns =
  atomically $ writeTVar (ntfTkn ns) Nothing

addNtfSubSupervisorInstruction :: NtfSubSupervisor -> RcvQueue -> STM ()
addNtfSubSupervisorInstruction ns rq = addNtfSubSupervisorInstruction' ns (rq, NSICreate)

addNtfSubSupervisorInstruction' :: NtfSubSupervisor -> (RcvQueue, NtfSubSupervisorInstruction) -> STM ()
addNtfSubSupervisorInstruction' ns rqc = do
  tkn_ <- readTVar $ ntfTkn ns
  forM_ tkn_ $ \NtfToken {ntfTknStatus} ->
    when (ntfTknStatus == NTActive) $ -- don't check if token is active when deleting subscription?
      writeTBQueue (ntfSubQ ns) rqc

closeNtfSubSupervisor :: NtfSubSupervisor -> IO ()
closeNtfSubSupervisor ns = do
  cancelNtfSubWorkers_ $ ntfSubWorkers ns
  cancelNtfSubWorkers_ $ ntfSubSMPWorkers ns

cancelNtfSubWorkers_ :: TMap NtfServer (TMVar (), Async ()) -> IO ()
cancelNtfSubWorkers_ workerMap = do
  workers <- readTVarIO workerMap
  forM_ workers $ \(_, action) -> uninterruptibleCancel action
  atomically $ writeTVar workerMap mempty
