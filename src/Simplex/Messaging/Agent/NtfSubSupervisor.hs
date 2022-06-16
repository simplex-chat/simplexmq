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
import Data.Fixed (Fixed (MkFixed), Pico)
import qualified Data.Map.Strict as M
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (ConnId)
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

processNtfSub :: forall m. AgentMonad m => AgentClient -> (ConnId, NtfSupervisorCommand) -> m ()
processNtfSub c (connId, cmd) = do
  ntfServer_ <- getNtfServer c
  case cmd of
    NSCCreate -> do
      -- TODO merge getNtfSubscription and getRcvQueue into one method to read both in same transaction?
      sub_ <- withStore c $ \st -> getNtfSubscription st connId
      RcvQueue {notifierId, server = smpServer} <- withStore c $ \st -> getRcvQueue st connId
      case (sub_, ntfServer_) of
        (Nothing, Just ntfServer) -> do
          currentTime <- liftIO getCurrentTime
          case notifierId of
            (Just nId) -> do
              let newSub = newNtfSubscription connId smpServer (Just nId) ntfServer NASKey currentTime
              withStore c $ \st -> createNtfSubscription st newSub (NtfSubAction NSACreate)
            _ -> do
              let newSub = newNtfSubscription connId smpServer Nothing ntfServer NASNew currentTime
              withStore c $ \st -> createNtfSubscription st newSub (NtfSubSMPAction NSAKey)
          -- TODO optimize?
          -- TODO - read action in getNtfSubscription and decide which worker to create
          -- TODO - SMP worker can create Ntf worker on NKEY completion
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        (Just _, Just ntfServer) -> do
          -- TODO subscription may have to be updated depending on current state:
          -- TODO - e.g., if it was previously marked for deletion action has to be updated
          -- TODO - should action depend on subscription status or always be NSAKey (NSACreate if notifierId exists)
          -- TODO   in case worker is currently deleting it? When deleting worker should check for updated_by_supervisor
          -- TODO   and if it is set perform update instead of delete. If worker was not deleting it yet it should
          -- TODO   idempotently replay commands.
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        _ -> pure () -- error - notification server not configured
    NSCDelete -> do
      -- TODO delete notifier ID and Key from SMP server (SDEL, then NDEL)
      withStore c $ \st -> markNtfSubscriptionForDeletion st connId
      case ntfServer_ of
        (Just ntfServer) -> addNtfWorker ntfServer
        _ -> pure ()
    NSCNtfWorker ntfServer ->
      addNtfWorker ntfServer
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
        Just (doWork, _) ->
          void . atomically $ tryPutTMVar doWork ()

runNtfWorker :: AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
runNtfWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  getNtfToken >>= \case
    Just tkn@NtfToken {ntfTokenId = Just tknId, ntfTknStatus} -> do
      nextSub_ <- withStore c (`getNextNtfSubAction` srv)
      ts <- liftIO getCurrentTime
      case nextSub_ of
        Just (ntfSub@NtfSubscription {connId, smpServer, ntfSubId, ntfSubActionTs}, ntfSubAction, RcvQueue {ntfPrivateKey, notifierId})
          | ntfSubActionTs > ts -> do
            noWorkToDo
            let wakeUpAfter = diffInMillis ntfSubActionTs ts
            void . async $ do
              liftIO $ threadDelay wakeUpAfter
              void . atomically $ tryPutTMVar doWork ()
          | otherwise ->
            case ntfSubAction of
              NSACreate -> case (ntfPrivateKey, notifierId) of
                (Just ntfPrivKey, Just nId)
                  | ntfTknStatus == NTActive -> do
                    nSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer nId) ntfPrivKey
                    let actionTs = addUTCTime 30 ts
                    withStore c $ \st ->
                      updateNtfSubscription st connId ntfSub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated, ntfSubActionTs = actionTs} (NtfSubAction NSACheck)
                  | otherwise -> updateSubFutureTs -- error
                _ -> updateSubFutureTs -- error
              NSACheck -> case ntfSubId of
                Just nSubId ->
                  agentNtfCheckSubscription c nSubId tkn >>= \case
                    NSNew -> updateSubNextCheck NASCreated
                    NSPending -> updateSubNextCheck NASCreated
                    NSActive -> updateSubNextCheck NASActive
                    NSEnd -> updateSubNextCheck NASEnded
                    NSSMPAuth -> updateSub NASSMPAuth (NtfSubAction NSADelete) ts
                Nothing -> updateSubFutureTs -- error
              NSADelete -> pure ()
          where
            updateSubNextCheck toStatus = do
              checkInterval <- asks $ ntfSubCheckInterval . config
              let nextCheckTs = addUTCTime checkInterval ts
              updateSub toStatus (NtfSubAction NSACheck) nextCheckTs
            updateSub toStatus toAction actionTs =
              withStore c $ \st ->
                updateNtfSubscription st connId ntfSub {ntfSubStatus = toStatus, ntfSubActionTs = actionTs} toAction
            updateSubFutureTs = do
              let retryTs = addUTCTime 300 ts
              withStore c $ \st ->
                updateNtfSubscription st connId ntfSub {ntfSubActionTs = retryTs} (NtfSubAction ntfSubAction)
        Nothing -> noWorkToDo
    _ -> noWorkToDo
  delay <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay delay
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork

runNtfSMPWorker :: forall m. AgentMonad m => AgentClient -> SMPServer -> TMVar () -> m ()
runNtfSMPWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  getNtfToken >>= \case
    Just NtfToken {ntfTknStatus} -> do
      nextSub_ <- withStore c (`getNextNtfSubSMPAction` srv)
      ts <- liftIO getCurrentTime
      case nextSub_ of
        Just (ntfSub@NtfSubscription {connId, ntfServer, ntfSubActionTs}, ntfSubAction, rq@RcvQueue {ntfPublicKey})
          | ntfSubActionTs > ts -> do
            noWorkToDo
            let wakeUpAfter = diffInMillis ntfSubActionTs ts
            void . async $ do
              liftIO $ threadDelay wakeUpAfter
              void . atomically $ tryPutTMVar doWork ()
          | otherwise ->
            case ntfSubAction of
              NSAKey
                | ntfTknStatus == NTActive ->
                  case ntfPublicKey of
                    Just ntfPubKey ->
                      enableNotificationsWithNKey ntfPubKey
                    _ -> do
                      C.SignAlg a <- asks (cmdSignAlg . config)
                      (ntfPubKey, ntfPrivKey) <- liftIO $ C.generateSignatureKeyPair a
                      withStore c $ \st -> setRcvQueueNotifierKey st connId ntfPubKey ntfPrivKey
                      enableNotificationsWithNKey ntfPubKey
                | otherwise -> updateSubFutureTs -- error
                where
                  enableNotificationsWithNKey ntfPubKey = do
                    nId <- enableQueueNotifications c rq ntfPubKey
                    withStore c $ \st -> do
                      setRcvQueueNotifierId st connId nId
                      updateNtfSubscription st connId ntfSub {ntfQueueId = Just nId, ntfSubStatus = NASKey, ntfSubActionTs = ts} (NtfSubAction NSACreate)
                    ns <- asks ntfSupervisor
                    atomically $ sendNtfSubCommand ns (connId, NSCNtfWorker ntfServer)
          where
            updateSubFutureTs = do
              let retryTs = addUTCTime 300 ts
              withStore c $ \st ->
                updateNtfSubscription st connId ntfSub {ntfSubActionTs = retryTs} (NtfSubSMPAction ntfSubAction)
        Nothing -> noWorkToDo
    _ -> noWorkToDo
  delay <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay delay
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork

fromPico :: Pico -> Integer
fromPico (MkFixed i) = i

diffInMillis :: UTCTime -> UTCTime -> Int
diffInMillis a b = (`div` 1000000) . fromInteger . fromPico . nominalDiffTimeToSeconds $ diffUTCTime a b

getNtfToken :: AgentMonad m => m (Maybe NtfToken)
getNtfToken = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> (ConnId, NtfSupervisorCommand) -> STM ()
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
