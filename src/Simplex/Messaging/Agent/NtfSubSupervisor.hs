{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
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

import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.Fixed (Fixed (MkFixed), Pico)
import qualified Data.Map.Strict as M
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import qualified Simplex.Messaging.Agent.Protocol as AP
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (NtfSubStatus (..), NtfTknStatus (..), SMPQueueNtf (..))
import Simplex.Messaging.Protocol
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (unlessM)
import System.Random (randomR)
import UnliftIO (async)
import UnliftIO.Concurrent (forkIO, threadDelay)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

runNtfSupervisor :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runNtfSupervisor c = forever $ do
  ns <- asks ntfSupervisor
  cmd <- atomically . readTBQueue $ ntfSubQ ns
  runExceptT (processNtfSub c cmd) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processNtfSub :: forall m. AgentMonad m => AgentClient -> NtfSupervisorCommand -> m ()
processNtfSub c cmd = do
  ntfServer_ <- getNtfServer c
  case cmd of
    NSCCreate connId -> do
      -- TODO merge getNtfSubscription and getRcvQueue into one method to read both in same transaction?
      (sub_, RcvQueue {server = smpServer, clientNtfCreds}) <- withStore c $ \db -> runExceptT $ do
        sub_ <- liftIO $ getNtfSubscription db connId
        q <- ExceptT $ getRcvQueue db connId
        pure (sub_, q)
      case (sub_, ntfServer_) of
        (Nothing, Just ntfServer) -> do
          currentTime <- liftIO getCurrentTime
          case clientNtfCreds of
            Just ClientNtfCreds {notifierId} -> do
              let newSub = newNtfSubscription connId smpServer (Just notifierId) ntfServer NASKey currentTime
              withStore' c $ \db -> createNtfSubscription db newSub (NtfSubAction NSACreate)
            _ -> do
              let newSub = newNtfSubscription connId smpServer Nothing ntfServer NASNew currentTime
              withStore' c $ \db -> createNtfSubscription db newSub (NtfSubSMPAction NSASmpKey)
          -- TODO optimize?
          -- TODO - read action in getNtfSubscription and decide which worker to create
          -- TODO - SMP worker can create Ntf worker on NKEY completion
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        (Just _, Just ntfServer) -> do
          -- TODO subscription may have to be updated depending on current state:
          -- TODO - e.g., if it was previously marked for deletion action has to be updated
          -- TODO - should action depend on subscription status or always be NSASmpKey (NSACreate if notifierId exists)
          -- TODO   in case worker is currently deleting it? When deleting worker should check for updated_by_supervisor
          -- TODO   and if it is set perform update instead of delete. If worker was not deleting it yet it should
          -- TODO   idempotently replay commands.
          addNtfSMPWorker smpServer
          addNtfWorker ntfServer
        _ -> pure () -- error - notification server not configured
    NSCDelete connId -> do
      withStore' c (`markNtfSubscriptionForDeletion` connId)
      case ntfServer_ of
        (Just ntfServer) -> addNtfWorker ntfServer
        _ -> pure ()
    NSCNtfWorker ntfServer ->
      addNtfWorker ntfServer
    NSCNtfSMPWorker smpServer ->
      addNtfSMPWorker smpServer
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
      nextSub_ <- withStore' c (`getNextNtfSubAction` srv)
      ts <- liftIO getCurrentTime
      case nextSub_ of
        Nothing -> noWorkToDo
        Just (ntfSub@NtfSubscription {ntfSubRcvQueue, smpServer, ntfSubId}, ntfSubAction) ->
          unlessM (rescheduleAction doWork ts ntfSub) $
            case ntfSubAction of
              NSACreate
                | ntfTknStatus == NTActive ->
                  case ntfSubRcvQueue of
                    Just NtfSubRcvQueue {rcvQueue = RcvQueue {clientNtfCreds}} -> case clientNtfCreds of
                      Just ClientNtfCreds {ntfPrivateKey, notifierId} -> do
                        nSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer notifierId) ntfPrivateKey
                        let actionTs = addUTCTime 30 ts
                        withStore' c $ \db ->
                          updateNtfSubscription db ntfSub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew, ntfSubActionTs = actionTs} (NtfSubAction NSACheck)
                      _ -> ntfInternalError c ntfSub "NSACreate - no notifier key or ID"
                    Nothing -> ntfInternalError c ntfSub "NSACreate - no rcv queue"
                | otherwise -> ntfInternalError c ntfSub "NSACreate - token not active"
              NSACheck -> case ntfSubId of
                Just nSubId ->
                  agentNtfCheckSubscription c nSubId tkn >>= \case
                    NSNew -> updateSubNextCheck NSNew
                    NSPending -> updateSubNextCheck NSPending
                    NSActive -> updateSubNextCheck NSActive
                    NSEnd -> updateSubNextCheck NSEnd
                    NSSMPAuth -> updateSub (NASCreated NSSMPAuth) (NtfSubAction NSADelete) ts
                Nothing -> ntfInternalError c ntfSub "NSACheck - no subscription ID"
              NSADelete -> do
                case ntfSubId of
                  Just nSubId ->
                    agentNtfDeleteSubscription c nSubId tkn
                      `E.finally` do
                        withStore' c $ \db ->
                          updateNtfSubscription db ntfSub {ntfSubId = Nothing, ntfSubStatus = NASOff, ntfSubActionTs = ts} (NtfSubSMPAction NSASmpDelete)
                        ns <- asks ntfSupervisor
                        atomically $ sendNtfSubCommand ns (NSCNtfSMPWorker smpServer)
                  Nothing -> ntfInternalError c ntfSub "NSADelete - no subscription ID"
          where
            updateSubNextCheck toStatus = do
              checkInterval <- asks $ ntfSubCheckInterval . config
              let nextCheckTs = addUTCTime checkInterval ts
              updateSub (NASCreated toStatus) (NtfSubAction NSACheck) nextCheckTs
            updateSub toStatus toAction actionTs =
              withStore' c $ \db ->
                updateNtfSubscription db ntfSub {ntfSubStatus = toStatus, ntfSubActionTs = actionTs} toAction
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
      nextSub_ <- withStore' c (`getNextNtfSubSMPAction` srv)
      ts <- liftIO getCurrentTime
      case nextSub_ of
        Nothing -> noWorkToDo
        Just (ntfSub@NtfSubscription {ntfSubInternalId, ntfSubRcvQueue, ntfServer}, ntfSubAction) ->
          unlessM (rescheduleAction doWork ts ntfSub) $
            case ntfSubAction of
              NSASmpKey
                | ntfTknStatus == NTActive ->
                  case ntfSubRcvQueue of
                    Just NtfSubRcvQueue {connId, rcvQueue} -> do
                      C.SignAlg a <- asks (cmdSignAlg . config)
                      (ntfPublicKey, ntfPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
                      (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- liftIO C.generateKeyPair'
                      (notifierId, rcvNtfSrvPubDhKey) <- enableQueueNotifications c rcvQueue ntfPublicKey rcvNtfPubDhKey
                      let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
                      withStore' c $ \st -> do
                        setRcvQueueNtfCreds st connId ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
                        updateNtfSubscription st ntfSub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey, ntfSubActionTs = ts} (NtfSubAction NSACreate)
                      ns <- asks ntfSupervisor
                      atomically $ sendNtfSubCommand ns (NSCNtfWorker ntfServer)
                    Nothing -> ntfInternalError c ntfSub "NSASmpKey - no rcv queue"
                | otherwise -> ntfInternalError c ntfSub "NSASmpKey - token not active"
              NSASmpDelete -> do
                forM_ ntfSubRcvQueue $ \NtfSubRcvQueue {rcvQueue} -> disableQueueNotifications c rcvQueue
                withStore' c $ \db -> deleteNtfSubscription db ntfSubInternalId
    _ -> noWorkToDo
  delay <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay delay
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork

rescheduleAction :: AgentMonad m => TMVar () -> UTCTime -> NtfSubscription -> m Bool
rescheduleAction doWork ts NtfSubscription {ntfSubActionTs}
  | ntfSubActionTs <= ts = pure False
  | otherwise = do
    void . atomically $ tryTakeTMVar doWork
    void . forkIO $ do
      threadDelay $ diffInMicros ntfSubActionTs ts
      void . atomically $ tryPutTMVar doWork ()
    pure True

fromPico :: Pico -> Integer
fromPico (MkFixed i) = i

diffInMicros :: UTCTime -> UTCTime -> Int
diffInMicros a b = (`div` 1000000) . fromInteger . fromPico . nominalDiffTimeToSeconds $ diffUTCTime a b

ntfInternalError :: AgentMonad m => AgentClient -> NtfSubscription -> String -> m ()
ntfInternalError c@AgentClient {subQ} NtfSubscription {ntfSubInternalId, ntfSubRcvQueue} internalErrStr = do
  withStore' c $ \db -> setNullNtfSubscriptionAction db ntfSubInternalId
  forM_ ntfSubRcvQueue $ \NtfSubRcvQueue {connId} -> atomically $ writeTBQueue subQ ("", connId, AP.ERR $ AP.INTERNAL internalErrStr)

getNtfToken :: AgentMonad m => m (Maybe NtfToken)
getNtfToken = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> NtfSupervisorCommand -> STM ()
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
