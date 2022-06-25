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
    sendNtfSubCommand',
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
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..), BrokerErrorType (..), ConnId, NotificationsMode (..))
import qualified Simplex.Messaging.Agent.Protocol as AP
import Simplex.Messaging.Agent.RetryInterval
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

processNtfSub :: forall m. AgentMonad m => AgentClient -> (ConnId, NtfSupervisorCommand) -> m ()
processNtfSub c (connId, cmd) = do
  ntfServer_ <- getNtfServer c
  case cmd of
    NSCCreate -> do
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
    NSCDelete -> do
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

runNtfWorker :: forall m. AgentMonad m => AgentClient -> NtfServer -> TMVar () -> m ()
runNtfWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  nextSub_ <- withStore' c (`getNextNtfSubAction` srv)
  case nextSub_ of
    Nothing -> noWorkToDo
    Just ntfSub@(NtfSubscription {connId}, _) -> do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \loop ->
        processAction ntfSub
          `catchError` ( \e ->
                           case e of
                             BROKER NETWORK -> loop
                             BROKER TIMEOUT -> loop
                             _ -> ntfInternalError c connId (show e)
                       )
  throttle <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay throttle
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    processAction :: (NtfSubscription, NtfSubAction) -> m ()
    processAction (ntfSub@NtfSubscription {connId, smpServer, ntfSubId}, ntfSubAction) = do
      ts <- liftIO getCurrentTime
      unlessM (rescheduleAction doWork ts ntfSub) $
        case ntfSubAction of
          NSACreate ->
            getNtfToken >>= \case
              Just tkn@NtfToken {ntfTokenId = Just tknId, ntfTknStatus = NTActive} -> do
                RcvQueue {clientNtfCreds} <- withStore c (`getRcvQueue` connId)
                case clientNtfCreds of
                  Just ClientNtfCreds {ntfPrivateKey, notifierId} -> do
                    nSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer notifierId) ntfPrivateKey
                    let actionTs = addUTCTime 30 ts
                    withStore' c $ \db ->
                      updateNtfSubscription db connId ntfSub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew, ntfSubActionTs = actionTs} (NtfSubAction NSACheck)
                  _ -> ntfInternalError c connId "NSACreate - no notifier queue credentials"
              _ -> ntfInternalError c connId "NSACreate - no active token"
          NSACheck ->
            getNtfToken >>= \case
              Just tkn ->
                case ntfSubId of
                  Just nSubId ->
                    agentNtfCheckSubscription c nSubId tkn >>= \case
                      NSNew -> updateSubNextCheck ts NSNew
                      NSPending -> updateSubNextCheck ts NSPending
                      NSActive -> updateSubNextCheck ts NSActive
                      NSEnd -> updateSubNextCheck ts NSEnd
                      NSSMPAuth -> updateSub (NASCreated NSSMPAuth) (NtfSubAction NSADelete) ts
                  Nothing -> ntfInternalError c connId "NSACheck - no subscription ID"
              _ -> ntfInternalError c connId "NSACheck - no active token"
          NSADelete -> case ntfSubId of
            Just nSubId ->
              (getNtfToken >>= \tkn -> forM_ tkn $ agentNtfDeleteSubscription c nSubId)
                `E.finally` do
                  withStore' c $ \db ->
                    updateNtfSubscription db connId ntfSub {ntfSubId = Nothing, ntfSubStatus = NASOff, ntfSubActionTs = ts} (NtfSubSMPAction NSASmpDelete)
                  ns <- asks ntfSupervisor
                  atomically $ sendNtfSubCommand' ns (const True) (connId, NSCNtfSMPWorker smpServer)
            Nothing -> ntfInternalError c connId "NSADelete - no subscription ID"
      where
        updateSubNextCheck ts toStatus = do
          checkInterval <- asks $ ntfSubCheckInterval . config
          let nextCheckTs = addUTCTime checkInterval ts
          updateSub (NASCreated toStatus) (NtfSubAction NSACheck) nextCheckTs
        updateSub toStatus toAction actionTs =
          withStore' c $ \db ->
            updateNtfSubscription db connId ntfSub {ntfSubStatus = toStatus, ntfSubActionTs = actionTs} toAction

runNtfSMPWorker :: forall m. AgentMonad m => AgentClient -> SMPServer -> TMVar () -> m ()
runNtfSMPWorker c srv doWork = forever $ do
  void . atomically $ readTMVar doWork
  nextSub_ <- withStore' c (`getNextNtfSubSMPAction` srv)
  case nextSub_ of
    Nothing -> noWorkToDo
    Just ntfSub@(NtfSubscription {connId}, _) -> do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \loop ->
        processAction ntfSub
          `catchError` ( \e ->
                           case e of
                             BROKER NETWORK -> loop
                             BROKER TIMEOUT -> loop
                             _ -> ntfInternalError c connId (show e)
                       )
  throttle <- asks $ ntfWorkerThrottle . config
  liftIO $ threadDelay throttle
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    processAction :: (NtfSubscription, NtfSubSMPAction) -> m ()
    processAction (ntfSub@NtfSubscription {connId, ntfServer}, ntfSubAction) = do
      ts <- liftIO getCurrentTime
      unlessM (rescheduleAction doWork ts ntfSub) $
        case ntfSubAction of
          NSASmpKey ->
            getNtfToken >>= \case
              Just NtfToken {ntfTknStatus = NTActive} -> do
                rq <- withStore c (`getRcvQueue` connId)
                C.SignAlg a <- asks (cmdSignAlg . config)
                (ntfPublicKey, ntfPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
                (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- liftIO C.generateKeyPair'
                (notifierId, rcvNtfSrvPubDhKey) <- enableQueueNotifications c rq ntfPublicKey rcvNtfPubDhKey
                let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
                withStore' c $ \st -> do
                  setRcvQueueNtfCreds st connId ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
                  updateNtfSubscription st connId ntfSub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey, ntfSubActionTs = ts} (NtfSubAction NSACreate)
                ns <- asks ntfSupervisor
                atomically $ sendNtfSubCommand ns (connId, NSCNtfWorker ntfServer)
              _ -> ntfInternalError c connId "NSASmpKey - no active token"
          NSASmpDelete -> do
            rq_ <- withStore' c (`getRcvQueue` connId)
            forM_ rq_ $ \rq -> disableQueueNotifications c rq
            withStore' c $ \db -> deleteNtfSubscription db connId

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

ntfInternalError :: AgentMonad m => AgentClient -> ConnId -> String -> m ()
ntfInternalError c@AgentClient {subQ} connId internalErrStr = do
  withStore' c $ \db -> setNullNtfSubscriptionAction db connId
  atomically $ writeTBQueue subQ ("", connId, AP.ERR $ AP.INTERNAL internalErrStr)

getNtfToken :: AgentMonad m => m (Maybe NtfToken)
getNtfToken = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> (ConnId, NtfSupervisorCommand) -> STM ()
sendNtfSubCommand ns = sendNtfSubCommand' ns $
  \NtfToken {ntfTknStatus, ntfMode} -> ntfTknStatus == NTActive && ntfMode == NMInstant

sendNtfSubCommand' :: NtfSupervisor -> (NtfToken -> Bool) -> (ConnId, NtfSupervisorCommand) -> STM ()
sendNtfSubCommand' ns tknCondition cmd =
  readTVar (ntfTkn ns)
    >>= mapM_ (\tkn -> when (tknCondition tkn) $ writeTBQueue (ntfSubQ ns) cmd)

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
