{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Agent.NtfSubSupervisor
  ( runNtfSupervisor,
    nsUpdateToken,
    nsRemoveNtfToken,
    sendNtfSubCommand,
    instantNotifications,
    closeNtfSupervisor,
    getNtfServer,
  )
where

import Control.Logger.Simple (logError, logInfo)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Bifunctor (first)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock (diffUTCTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (ACommand (..), APartyCmd (..), AgentErrorType (..), BrokerErrorType (..), ConnId, NotificationsMode (..), SAEntity (..))
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (NtfSubStatus (..), NtfTknStatus (..), SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, SMPServer, sameSrvAddr)
import Simplex.Messaging.Util (diffToMicroseconds, threadDelay', tshow, unlessM, atomically')
import System.Random (randomR)
import UnliftIO
import UnliftIO.Concurrent (forkIO, threadDelay)
import qualified UnliftIO.Exception as E

runNtfSupervisor :: AgentClient -> AM' ()
runNtfSupervisor c = do
  ns <- asks ntfSupervisor
  forever $ do
    cmd@(connId, _) <- atomically' . readTBQueue $ ntfSubQ ns
    handleErr connId . agentOperationBracket c AONtfNetwork waitUntilActive $
      runExceptT (processNtfSub c cmd) >>= \case
        Left e -> notifyErr connId e
        Right _ -> return ()
  where
    handleErr :: ConnId -> AM' () -> AM' ()
    handleErr connId = E.handle $ \(e :: E.SomeException) -> do
      logError $ "runNtfSupervisor error " <> tshow e
      notifyErr connId e
    notifyErr connId e = notifyInternalError c connId $ "runNtfSupervisor error " <> show e

processNtfSub :: AgentClient -> (ConnId, NtfSupervisorCommand) -> AM ()
processNtfSub c (connId, cmd) = do
  logInfo $ "processNtfSub - connId = " <> tshow connId <> " - cmd = " <> tshow cmd
  case cmd of
    NSCCreate -> do
      (a, RcvQueue {server = smpServer, clientNtfCreds}) <- withStore c $ \db -> runExceptT $ do
        a <- liftIO $ getNtfSubscription db connId
        q <- ExceptT $ getPrimaryRcvQueue db connId
        pure (a, q)
      logInfo $ "processNtfSub, NSCCreate - a = " <> tshow a
      case a of
        Nothing -> do
          withTokenServer $ \ntfServer -> do
            case clientNtfCreds of
              Just ClientNtfCreds {notifierId} -> do
                let newSub = newNtfSubscription connId smpServer (Just notifierId) ntfServer NASKey
                withStore c $ \db -> createNtfSubscription db newSub $ NtfSubNTFAction NSACreate
                lift . void $ getNtfNTFWorker True c ntfServer
              Nothing -> do
                let newSub = newNtfSubscription connId smpServer Nothing ntfServer NASNew
                withStore c $ \db -> createNtfSubscription db newSub $ NtfSubSMPAction NSASmpKey
                lift . void $ getNtfSMPWorker True c smpServer
        (Just (sub@NtfSubscription {ntfSubStatus, ntfServer = subNtfServer, smpServer = smpServer', ntfQueueId}, action_)) -> do
          case (clientNtfCreds, ntfQueueId) of
            (Just ClientNtfCreds {notifierId}, Just ntfQueueId')
              | sameSrvAddr smpServer smpServer' && notifierId == ntfQueueId' -> create
              | otherwise -> rotate
            (Nothing, Nothing) -> create
            _ -> rotate
          where
            create :: AM ()
            create = case action_ of
              -- action was set to NULL after worker internal error
              Nothing -> resetSubscription
              Just (action, _)
                -- subscription was marked for deletion / is being deleted
                | isDeleteNtfSubAction action -> do
                    if ntfSubStatus == NASNew || ntfSubStatus == NASOff || ntfSubStatus == NASDeleted
                      then resetSubscription
                      else withTokenServer $ \ntfServer -> do
                        withStore' c $ \db -> supervisorUpdateNtfSub db sub {ntfServer} (NtfSubNTFAction NSACreate)
                        lift . void $ getNtfNTFWorker True c ntfServer
                | otherwise -> case action of
                    NtfSubNTFAction _ -> lift . void $ getNtfNTFWorker True c subNtfServer
                    NtfSubSMPAction _ -> lift . void $ getNtfSMPWorker True c smpServer
            rotate :: AM ()
            rotate = do
              withStore' c $ \db -> supervisorUpdateNtfSub db sub (NtfSubNTFAction NSARotate)
              lift . void $ getNtfNTFWorker True c subNtfServer
            resetSubscription :: AM ()
            resetSubscription =
              withTokenServer $ \ntfServer -> do
                let sub' = sub {ntfQueueId = Nothing, ntfServer, ntfSubId = Nothing, ntfSubStatus = NASNew}
                withStore' c $ \db -> supervisorUpdateNtfSub db sub' (NtfSubSMPAction NSASmpKey)
                lift . void $ getNtfSMPWorker True c smpServer
    NSCDelete -> do
      sub_ <- withStore' c $ \db -> do
        supervisorUpdateNtfAction db connId (NtfSubNTFAction NSADelete)
        getNtfSubscription db connId
      logInfo $ "processNtfSub, NSCDelete - sub_ = " <> tshow sub_
      case sub_ of
        (Just (NtfSubscription {ntfServer}, _)) -> lift . void $ getNtfNTFWorker True c ntfServer
        _ -> pure () -- err "NSCDelete - no subscription"
    NSCSmpDelete -> do
      withStore' c (`getPrimaryRcvQueue` connId) >>= \case
        Right rq@RcvQueue {server = smpServer} -> do
          logInfo $ "processNtfSub, NSCSmpDelete - rq = " <> tshow rq
          withStore' c $ \db -> supervisorUpdateNtfAction db connId (NtfSubSMPAction NSASmpDelete)
          lift . void $ getNtfSMPWorker True c smpServer
        _ -> notifyInternalError c connId "NSCSmpDelete - no rcv queue"
    NSCNtfWorker ntfServer -> lift . void $ getNtfNTFWorker True c ntfServer
    NSCNtfSMPWorker smpServer -> lift . void $ getNtfSMPWorker True c smpServer

getNtfNTFWorker :: Bool -> AgentClient -> NtfServer -> AM' Worker
getNtfNTFWorker hasWork c server = do
  ws <- asks $ ntfWorkers . ntfSupervisor
  getAgentWorker "ntf_ntf" hasWork c server ws $ runNtfWorker c server

getNtfSMPWorker :: Bool -> AgentClient -> SMPServer -> AM' Worker
getNtfSMPWorker hasWork c server = do
  ws <- asks $ ntfSMPWorkers . ntfSupervisor
  getAgentWorker "ntf_smp" hasWork c server ws $ runNtfSMPWorker c server

withTokenServer :: (NtfServer -> AM ()) -> AM ()
withTokenServer action = lift getNtfToken >>= mapM_ (\NtfToken {ntfServer} -> action ntfServer)

runNtfWorker :: AgentClient -> NtfServer -> Worker -> AM ()
runNtfWorker c srv Worker {doWork} = do
  delay <- asks $ ntfWorkerDelay . config
  forever $ do
    waitForWork doWork
    ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfOperation
    threadDelay delay
  where
    runNtfOperation :: AM ()
    runNtfOperation =
      withWork c doWork (`getNextNtfSubNTFAction` srv) $
        \nextSub@(NtfSubscription {connId}, _, _) -> do
          logInfo $ "runNtfWorker, nextSub " <> tshow nextSub
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop ->
            processSub nextSub
              `catchAgentError` retryOnError c "NtfWorker" loop (workerInternalError c connId . show)
    processSub :: (NtfSubscription, NtfSubNTFAction, NtfActionTs) -> AM ()
    processSub (sub@NtfSubscription {connId, smpServer, ntfSubId}, action, actionTs) = do
      ts <- liftIO getCurrentTime
      unlessM (lift $ rescheduleAction doWork ts actionTs) $
        case action of
          NSACreate ->
            lift getNtfToken >>= \case
              Just tkn@NtfToken {ntfTokenId = Just tknId, ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
                RcvQueue {clientNtfCreds} <- withStore c (`getPrimaryRcvQueue` connId)
                case clientNtfCreds of
                  Just ClientNtfCreds {ntfPrivateKey, notifierId} -> do
                    nSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer notifierId) ntfPrivateKey
                    -- possible improvement: smaller retry until Active, less frequently (daily?) once Active
                    let actionTs' = addUTCTime 30 ts
                    withStore' c $ \db ->
                      updateNtfSubscription db sub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew} (NtfSubNTFAction NSACheck) actionTs'
                  _ -> workerInternalError c connId "NSACreate - no notifier queue credentials"
              _ -> workerInternalError c connId "NSACreate - no active token"
          NSACheck ->
            lift getNtfToken >>= \case
              Just tkn ->
                case ntfSubId of
                  Just nSubId ->
                    agentNtfCheckSubscription c nSubId tkn >>= \case
                      NSAuth -> do
                        lift (getNtfServer c) >>= \case
                          Just ntfServer -> do
                            withStore' c $ \db ->
                              updateNtfSubscription db sub {ntfServer, ntfQueueId = Nothing, ntfSubId = Nothing, ntfSubStatus = NASNew} (NtfSubSMPAction NSASmpKey) ts
                            ns <- asks ntfSupervisor
                            atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCNtfSMPWorker smpServer)
                          _ -> workerInternalError c connId "NSACheck - failed to reset subscription, notification server not configured"
                      status -> updateSubNextCheck ts status
                  Nothing -> workerInternalError c connId "NSACheck - no subscription ID"
              _ -> workerInternalError c connId "NSACheck - no active token"
          NSADelete -> case ntfSubId of
            Just nSubId ->
              (lift getNtfToken >>= mapM_ (agentNtfDeleteSubscription c nSubId))
                `agentFinally` continueDeletion
            _ -> continueDeletion
            where
              continueDeletion = do
                let sub' = sub {ntfSubId = Nothing, ntfSubStatus = NASOff}
                withStore' c $ \db -> updateNtfSubscription db sub' (NtfSubSMPAction NSASmpDelete) ts
                ns <- asks ntfSupervisor
                atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCNtfSMPWorker smpServer)
          NSARotate -> case ntfSubId of
            Just nSubId ->
              (lift getNtfToken >>= mapM_ (agentNtfDeleteSubscription c nSubId))
                `agentFinally` deleteCreate
            _ -> deleteCreate
            where
              deleteCreate = do
                withStore' c $ \db -> deleteNtfSubscription db connId
                ns <- asks ntfSupervisor
                atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCCreate)
      where
        updateSubNextCheck ts toStatus = do
          checkInterval <- asks $ ntfSubCheckInterval . config
          let nextCheckTs = addUTCTime checkInterval ts
          updateSub (NASCreated toStatus) (NtfSubNTFAction NSACheck) nextCheckTs
        updateSub toStatus toAction actionTs' =
          withStore' c $ \db ->
            updateNtfSubscription db sub {ntfSubStatus = toStatus} toAction actionTs'

runNtfSMPWorker :: AgentClient -> SMPServer -> Worker -> AM ()
runNtfSMPWorker c srv Worker {doWork} = do
  env <- ask
  delay <- asks $ ntfSMPWorkerDelay . config
  forever $ do
    waitForWork doWork
    ExceptT . liftIO . agentOperationBracket c AONtfNetwork throwWhenInactive $
      runReaderT (runExceptT runNtfSMPOperation) env
    threadDelay delay
  where
    runNtfSMPOperation =
      withWork c doWork (`getNextNtfSubSMPAction` srv) $
        \nextSub@(NtfSubscription {connId}, _, _) -> do
          logInfo $ "runNtfSMPWorker, nextSub " <> tshow nextSub
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop ->
            processSub nextSub
              `catchAgentError` retryOnError c "NtfSMPWorker" loop (workerInternalError c connId . show)
    processSub :: (NtfSubscription, NtfSubSMPAction, NtfActionTs) -> AM ()
    processSub (sub@NtfSubscription {connId, ntfServer}, smpAction, actionTs) = do
      ts <- liftIO getCurrentTime
      unlessM (lift $ rescheduleAction doWork ts actionTs) $
        case smpAction of
          NSASmpKey ->
            lift getNtfToken >>= \case
              Just NtfToken {ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
                rq <- withStore c (`getPrimaryRcvQueue` connId)
                C.AuthAlg a <- asks (rcvAuthAlg . config)
                g <- asks random
                (ntfPublicKey, ntfPrivateKey) <- atomically $ C.generateAuthKeyPair a g
                (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- atomically $ C.generateKeyPair g
                (notifierId, rcvNtfSrvPubDhKey) <- enableQueueNotifications c rq ntfPublicKey rcvNtfPubDhKey
                let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
                withStore' c $ \db -> do
                  setRcvQueueNtfCreds db connId $ Just ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
                  updateNtfSubscription db sub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey} (NtfSubNTFAction NSACreate) ts
                ns <- asks ntfSupervisor
                atomically' $ sendNtfSubCommand ns (connId, NSCNtfWorker ntfServer)
              _ -> workerInternalError c connId "NSASmpKey - no active token"
          NSASmpDelete -> do
            rq_ <- withStore' c $ \db -> do
              setRcvQueueNtfCreds db connId Nothing
              getPrimaryRcvQueue db connId
            mapM_ (disableQueueNotifications c) rq_
            withStore' c $ \db -> deleteNtfSubscription db connId

rescheduleAction :: TMVar () -> UTCTime -> UTCTime -> AM' Bool
rescheduleAction doWork ts actionTs
  | actionTs <= ts = pure False
  | otherwise = do
      void . atomically' $ tryTakeTMVar doWork
      void . forkIO $ do
        liftIO $ threadDelay' $ diffToMicroseconds $ diffUTCTime actionTs ts
        atomically' $ hasWorkToDo' doWork
      pure True

retryOnError :: AgentClient -> Text -> AM () -> (AgentErrorType -> AM ()) -> AgentErrorType -> AM ()
retryOnError c name loop done e = do
  logError $ name <> " error: " <> tshow e
  case e of
    BROKER _ NETWORK -> retryLoop
    BROKER _ TIMEOUT -> retryLoop
    _ -> done e
  where
    retryLoop = do
      atomically' $ endAgentOperation c AONtfNetwork
      atomically' $ throwWhenInactive c
      atomically' $ beginAgentOperation c AONtfNetwork
      loop

workerInternalError :: AgentClient -> ConnId -> String -> AM ()
workerInternalError c connId internalErrStr = do
  withStore' c $ \db -> setNullNtfSubscriptionAction db connId
  notifyInternalError c connId internalErrStr

-- TODO change error
notifyInternalError :: MonadIO m => AgentClient -> ConnId -> String -> m ()
notifyInternalError AgentClient {subQ} connId internalErrStr = atomically $ writeTBQueue subQ ("", connId, APC SAEConn $ ERR $ INTERNAL internalErrStr)
{-# INLINE notifyInternalError #-}

getNtfToken :: AM' (Maybe NtfToken)
getNtfToken = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> (ConnId, NtfSupervisorCommand) -> STM ()
sendNtfSubCommand ns cmd = do
  tkn <- readTVar (ntfTkn ns)
  when (instantNotifications tkn) $ writeTBQueue (ntfSubQ ns) cmd

instantNotifications :: Maybe NtfToken -> Bool
instantNotifications = \case
  Just NtfToken {ntfTknStatus = NTActive, ntfMode = NMInstant} -> True
  _ -> False

closeNtfSupervisor :: NtfSupervisor -> IO ()
closeNtfSupervisor ns = do
  stopWorkers $ ntfWorkers ns
  stopWorkers $ ntfSMPWorkers ns
  where
    stopWorkers workers = atomically' (swapTVar workers M.empty) >>= mapM_ (liftIO . cancelWorker)

getNtfServer :: AgentClient -> AM' (Maybe NtfServer)
getNtfServer c = do
  ntfServers <- readTVarIO $ ntfServers c
  case ntfServers of
    [] -> pure Nothing
    [srv] -> pure $ Just srv
    servers -> do
      gen <- asks randomServer
      atomically . stateTVar gen $
        first (Just . (servers !!)) . randomR (0, length servers - 1)
