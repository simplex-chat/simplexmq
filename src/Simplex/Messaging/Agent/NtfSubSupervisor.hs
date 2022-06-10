{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( ntfSupervisor,
    nsUpdateToken,
    nsUpdateToken',
    nsRemoveNtfToken,
    addNtfSubSupervisorInstruction,
    closeNtfSubSupervisor,
    getNtfServer,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.Time (getCurrentTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Core (AgentMonad, withStore)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (NtfTknStatus (..))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import System.Random (randomR)
import UnliftIO (async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

ntfSupervisor :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
ntfSupervisor c = forever $ do
  ns <- asks ntfSubSupervisor
  rqc <- atomically . readTBQueue $ ntfSubQ ns
  runExceptT (processNtfSub c rqc) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processNtfSub :: AgentMonad m => AgentClient -> (RcvQueue, NtfSubSupervisorInstruction) -> m ()
processNtfSub c (rcvQueue@RcvQueue {server = smpServer, rcvId}, rqc) = do
  ntfServer_ <- getNtfServer c
  ns <- asks ntfSubSupervisor
  ntfToken_ <- readTVarIO $ ntfTkn ns
  case rqc of
    NSICreate -> do
      sub_ <- withStore $ \st -> getNtfSubscription st rcvQueue
      case (sub_, ntfServer_, ntfToken_) of
        (Nothing, Just ntfServer, Just tkn) -> do
          currentTime <- liftIO getCurrentTime
          let newSub = newNtfSubscription ntfServer tkn smpServer rcvId currentTime
          withStore $ \st -> createNtfSubscription st newSub
          -- TODO optimize?
          -- TODO - read action in getNtfSubscription and decide which worker to create
          -- TODO - SMP worker can create Ntf worker on NKEY completion
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        (Just _, Just ntfServer, Just _) -> do
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        _ -> pure ()
    NSIDelete -> do
      withStore $ \st -> markNtfSubscriptionForDeletion st rcvQueue
      case (ntfServer_, ntfToken_) of
        (Just ntfServer, Just _) -> addNtfWorker ntfServer
        _ -> pure ()
  liftIO $ threadDelay 1000000
  where
    addNtfWorker srv = do
      ws <- asks $ ntfSubWorkers . ntfSubSupervisor
      addNtfSubWorker ws srv $
        \w -> ntfSubWorker c srv w `E.finally` atomically (TM.delete srv ws)
    addNtfSMPWorker srv = do
      ws <- asks $ ntfSubSMPWorkers . ntfSubSupervisor
      addNtfSubWorker ws srv $
        \w -> ntfSMPWorker c srv w `E.finally` atomically (TM.delete srv ws)
    addNtfSubWorker ws srv run =
      atomically (TM.lookup srv ws) >>= \case
        Nothing -> do
          workAvailable <- newTMVarIO ()
          ntfWorker <- async $ run workAvailable
          atomically $ TM.insert srv (workAvailable, ntfWorker) ws
        Just (workAvailable, _) -> void . atomically $ tryPutTMVar workAvailable ()

ntfSubWorker :: AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
ntfSubWorker _c srv workAvailable = forever $ do
  void . atomically $ readTMVar workAvailable
  withStore $ \st ->
    getNextNtfSubscriptionAction st srv >>= \case
      Nothing -> void . atomically $ tryTakeTMVar workAvailable
      Just (_sub, ntfSubAction) ->
        forM_ ntfSubAction $ \case
          NSANew _nKey -> pure ()
          NSACheck -> pure ()
          NSADelete -> pure ()
  liftIO $ threadDelay 1000000

ntfSMPWorker :: AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
ntfSMPWorker _c srv workAvailable = forever $ do
  void . atomically $ readTMVar workAvailable
  withStore $ \st ->
    getNextNtfSubscriptionSMPAction st srv >>= \case
      Nothing -> void . atomically $ tryTakeTMVar workAvailable
      Just (_sub, ntfSubAction) ->
        forM_ ntfSubAction $ \case
          NSSAKey -> pure ()
  liftIO $ threadDelay 1000000

nsUpdateToken :: AgentMonad m => NtfSubSupervisor -> NtfToken -> m ()
nsUpdateToken ns tkn = atomically $ nsUpdateToken' ns tkn

nsUpdateToken' :: NtfSubSupervisor -> NtfToken -> STM ()
nsUpdateToken' ns tkn = writeTVar (ntfTkn ns) (Just tkn)

nsRemoveNtfToken :: AgentMonad m => NtfSubSupervisor -> m ()
nsRemoveNtfToken ns = atomically $ writeTVar (ntfTkn ns) Nothing

addNtfSubSupervisorInstruction :: NtfSubSupervisor -> (RcvQueue, NtfSubSupervisorInstruction) -> STM ()
addNtfSubSupervisorInstruction ns rqc = do
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

getNtfServer :: AgentMonad m => AgentClient -> m (Maybe NtfServer)
getNtfServer c = do
  ntfServers <- readTVarIO $ ntfServers c
  case ntfServers of
    [] -> pure Nothing
    [srv] -> pure $ Just srv
    servers -> do
      gen <- asks randomServer
      atomically . stateTVar gen $
        first (Just . (servers !!)) . randomR (0, length servers - 1)
