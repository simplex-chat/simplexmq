{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( NtfSubSupervisor (..),
    RcvQueueNtfCommand (..),
    newNtfSubSupervisor,
    addNtfSubWorker,
    addNtfSubSMPWorker,
    nsUpdateNtfToken,
    nsUpdateNtfToken',
    nsRemoveNtfToken,
    addRcvQueueToNtfSubQueue,
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
    ntfSubQ :: TBQueue (RcvQueue, RcvQueueNtfCommand),
    ntfSubWorkers :: TMap NtfServer (TMVar (), Async ()),
    ntfSubSMPWorkers :: TMap SMPServer (TMVar (), Async ())
  }

data RcvQueueNtfCommand = RQNCCreate | RQNCDelete

newNtfSubSupervisor :: Env -> STM NtfSubSupervisor
newNtfSubSupervisor agentEnv = do
  let qSize = tbqSize $ config agentEnv
  ntfTkn <- newTVar Nothing
  ntfSubQ <- newTBQueue qSize -- bigger queue size?
  ntfSubWorkers <- TM.empty
  ntfSubSMPWorkers <- TM.empty
  pure
    NtfSubSupervisor
      { ntfTkn,
        ntfSubQ,
        ntfSubWorkers,
        ntfSubSMPWorkers
      }

addNtfSubWorker :: MonadUnliftIO m => NtfSubSupervisor -> NtfServer -> (TMVar () -> m ()) -> m ()
addNtfSubWorker ns = addNtfSubWorker_ $ ntfSubWorkers ns

addNtfSubSMPWorker :: MonadUnliftIO m => NtfSubSupervisor -> SMPServer -> (TMVar () -> m ()) -> m ()
addNtfSubSMPWorker ns = addNtfSubWorker_ $ ntfSubSMPWorkers ns

addNtfSubWorker_ :: MonadUnliftIO m => TMap NtfServer (TMVar (), Async ()) -> ProtocolServer -> (TMVar () -> m ()) -> m ()
addNtfSubWorker_ workerMap srv action =
  atomically (TM.lookup srv workerMap) >>= \case
    Nothing -> do
      workerSemaphore <- newTMVarIO ()
      ntfSubWorker <- async $ action workerSemaphore
      atomically $ TM.insert srv (workerSemaphore, ntfSubWorker) workerMap
    Just (workerSemaphore, _) -> void . atomically $ tryPutTMVar workerSemaphore ()

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
      writeTBQueue (ntfSubQ ns) (rq, RQNCCreate)

closeNtfSubSupervisor :: NtfSubSupervisor -> IO ()
closeNtfSubSupervisor ns = do
  cancelNtfSubWorkers_ $ ntfSubWorkers ns
  cancelNtfSubWorkers_ $ ntfSubSMPWorkers ns

cancelNtfSubWorkers_ :: TMap NtfServer (TMVar (), Async ()) -> IO ()
cancelNtfSubWorkers_ workerMap = do
  workers <- readTVarIO workerMap
  forM_ workers $ \(_, action) -> uninterruptibleCancel action
  atomically $ writeTVar workerMap mempty
