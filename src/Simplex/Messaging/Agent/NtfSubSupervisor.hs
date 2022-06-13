{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( runNtfSupervisor,
    nsUpdateToken,
    nsRemoveNtfToken,
    sendNtfSubCommand,
    closeNtfSupervisor,
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
import qualified Data.Map.Strict as M
import Data.Time (getCurrentTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (NtfSubStatus (..), NtfTknStatus (..), SMPQueueNtf (..))
import Simplex.Messaging.Protocol
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import System.Random (randomR)
import UnliftIO (async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

runNtfSupervisor :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runNtfSupervisor c = forever $ do
  ns <- asks ntfSupervisor
  cmd <- atomically . readTBQueue $ ntfSubQ ns
  runExceptT (processNtfSub c cmd) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processNtfSub :: forall m. AgentMonad m => AgentClient -> (RcvQueue, NtfSupervisorCommand) -> m ()
processNtfSub c (rcvQueue@RcvQueue {server = smpServer, rcvId, notifierId}, cmd) = do
  ntfServer_ <- getNtfServer c
  case cmd of
    NSCCreate -> do
      sub_ <- withStore $ \st -> getNtfSubscription st rcvQueue
      case (sub_, ntfServer_) of
        (Nothing, Just ntfServer) -> do
          currentTime <- liftIO getCurrentTime
          case notifierId of
            (Just nId) -> do
              let newSub = newNtfSubscription smpServer rcvId (Just nId) ntfServer NSKey currentTime
              withStore $ \st -> createNtfSubscription st newSub (NtfSubAction NSANew)
            _ -> do
              let newSub = newNtfSubscription smpServer rcvId Nothing ntfServer NSStarted currentTime
              withStore $ \st -> createNtfSubscription st newSub (NtfSubSMPAction NSAKey)
          -- TODO optimize?
          -- TODO - read action in getNtfSubscription and decide which worker to create
          -- TODO - SMP worker can create Ntf worker on NKEY completion
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        (Just _, Just ntfServer) -> do
          -- TODO subscription may have to be updated depending on current state:
          -- TODO - e.g., if it was previously marked for deletion action has to be updated
          -- TODO - should action depend on subscription status or always be NSAKey (NSANew if notifierId exists)
          -- TODO   in case worker is currently deleting it? When deleting worker should check for updated_by_supervisor
          -- TODO   and if it is set perform update instead of delete. If worker was not deleting it yet it should
          -- TODO   idempotently replay commands.
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        _ -> pure ()
    NSCDelete -> do
      withStore $ \st -> markNtfSubscriptionForDeletion st rcvQueue
      case ntfServer_ of
        (Just ntfServer) -> addNtfWorker ntfServer
        _ -> pure ()
  where
    addNtfWorker = addWorker ntfWorkers runNtfWorker
    addNtfSMPWorker = addWorker ntfSMPWorkers runNtfSMPWorker
    addWorker ::
      (NtfSupervisor -> TMap ProtocolServer (TMVar (), Async ())) ->
      (AgentClient -> ProtocolServer -> TMVar () -> m ()) ->
      ProtocolServer ->
      m ()
    addWorker wsSel runWorker srv = do
      ws <- asks $ wsSel . ntfSupervisor
      atomically (TM.lookup srv ws) >>= \case
        Nothing -> do
          doWork <- newTMVarIO ()
          worker <- async $ runWorker c srv doWork `E.finally` atomically (TM.delete srv ws)
          atomically $ TM.insert srv (doWork, worker) ws
        Just (doWork, _) -> void . atomically $ tryPutTMVar doWork ()

runNtfWorker :: AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
runNtfWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  getNtfToken_ >>= \case
    Just tkn@NtfToken {ntfTokenId = Just tknId, ntfTknStatus} ->
      withStore (`getNextNtfSubAction` srv) >>= \case
        Just (ntfSub@NtfSubscription {smpServer, rcvQueueId}, ntfSubAction, RcvQueue {ntfPrivateKey, notifierId}) -> do
          let rqPK = (smpServer, rcvQueueId)
          case ntfSubAction of
            NSANew -> case (ntfPrivateKey, notifierId) of
              (Just ntfPrivKey, Just nId)
                | ntfTknStatus == NTActive -> do
                  ntfSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer nId) ntfPrivKey
                  ts <- liftIO getCurrentTime
                  withStore $ \st ->
                    updateNtfSubscription st rqPK ntfSub {ntfSubId = Just ntfSubId, ntfSubStatus = NSNew, ntfSubActionTs = ts} (NtfSubAction NSACheck)
                | otherwise -> pure () -- error
              _ -> pure () -- error
            NSACheck -> pure ()
            NSADelete -> pure ()
        Nothing -> noWorkToDo
    _ -> noWorkToDo
  delay <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay delay
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork

runNtfSMPWorker :: forall m. AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
runNtfSMPWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  getNtfToken_ >>= \case
    Just NtfToken {ntfTknStatus} -> do
      withStore (`getNextNtfSubSMPAction` srv) >>= \case
        Just (ntfSub@NtfSubscription {smpServer, rcvQueueId, ntfServer}, ntfSubAction, rq@RcvQueue {ntfPublicKey}) -> do
          let rqPK = (smpServer, rcvQueueId)
          case ntfSubAction of
            NSAKey
              | ntfTknStatus == NTActive ->
                case ntfPublicKey of
                  Just ntfPubKey ->
                    enableNotificationsWithNKey ntfPubKey
                  _ -> do
                    C.SignAlg a <- asks (cmdSignAlg . config)
                    (ntfPubKey, ntfPrivKey) <- liftIO $ C.generateSignatureKeyPair a
                    withStore $ \st -> setRcvQueueNotifierKey st rqPK ntfPubKey ntfPrivKey
                    enableNotificationsWithNKey ntfPubKey
              | otherwise -> pure () -- error
              where
                enableNotificationsWithNKey ntfPubKey = do
                  nId <- enableQueueNotifications c rq ntfPubKey
                  ts <- liftIO getCurrentTime
                  withStore $ \st -> do
                    setRcvQueueNotifierId st rqPK nId
                    updateNtfSubscription st rqPK ntfSub {ntfQueueId = Just nId, ntfSubStatus = NSKey, ntfSubActionTs = ts} (NtfSubAction NSANew)
                  kickNtfWorker_ ntfWorkers ntfServer
        Nothing -> noWorkToDo
    _ -> noWorkToDo
  delay <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay delay
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork

kickNtfWorker_ :: AgentMonad m => (NtfSupervisor -> TMap ProtocolServer (TMVar (), Async ())) -> ProtocolServer -> m ()
kickNtfWorker_ wsSel srv = do
  ws <- asks $ wsSel . ntfSupervisor
  atomically $
    TM.lookup srv ws >>= \case
      Just (doWork, _) -> void $ tryPutTMVar doWork ()
      Nothing -> pure ()

getNtfToken_ :: AgentMonad m => m (Maybe NtfToken)
getNtfToken_ = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> (RcvQueue, NtfSupervisorCommand) -> STM ()
sendNtfSubCommand ns cmd =
  readTVar (ntfTkn ns)
    >>= mapM_ (\NtfToken {ntfTknStatus} -> when (ntfTknStatus == NTActive) $ writeTBQueue (ntfSubQ ns) cmd)

closeNtfSupervisor :: NtfSupervisor -> IO ()
closeNtfSupervisor ns = do
  cancelNtfWorkers_ $ ntfWorkers ns
  cancelNtfWorkers_ $ ntfSMPWorkers ns

cancelNtfWorkers_ :: TMap ProtocolServer (TMVar (), Async ()) -> IO ()
cancelNtfWorkers_ wsVar = do
  ws <- atomically $ stateTVar wsVar $ \ws -> (ws, M.empty)
  forM_ ws $ uninterruptibleCancel . snd

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
