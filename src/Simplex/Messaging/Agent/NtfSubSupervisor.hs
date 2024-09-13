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
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.Either (rights)
import Data.Foldable (foldr')
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock (diffUTCTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AEvent (..), AEvt (..), AgentErrorType (..), BrokerErrorType (..), ConnId, NotificationsMode (..), SAEntity (..))
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Stats
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (NtfSubStatus (..), NtfTknStatus (..), SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, SMPServer, sameSrvAddr)
import Simplex.Messaging.Util (diffToMicroseconds, threadDelay', tshow, unlessM)
import System.Random (randomR)
import UnliftIO
import UnliftIO.Concurrent (forkIO)
import qualified UnliftIO.Exception as E

runNtfSupervisor :: AgentClient -> AM' ()
runNtfSupervisor c = do
  ns <- asks ntfSupervisor
  forever $ do
    cmd <- atomically . readTBQueue $ ntfSubQ ns
    handleErr . agentOperationBracket c AONtfNetwork waitUntilActive $
      runExceptT (processNtfCmd c cmd) >>= \case
        Left e -> notifyErr e
        Right _ -> return ()
  where
    handleErr :: AM' () -> AM' ()
    handleErr = E.handle $ \(e :: E.SomeException) -> do
      logError $ "runNtfSupervisor error " <> tshow e
      notifyErr e
    notifyErr e = notifyInternalError' c $ "runNtfSupervisor error " <> show e

-- TODO [batch ntf] notify ERRS
processNtfCmd :: AgentClient -> (NtfSupervisorCommand, NonEmpty ConnId) -> AM ()
processNtfCmd c (cmd, connIds) = do
  logInfo $ "processNtfCmd - cmd = " <> tshow cmd
  case cmd of
    NSCCreate -> do
      rqSubActions <- lift $ rights <$> withStoreBatch c (\db -> map (getQueueSub db) (L.toList connIds))
      logInfo $ "processNtfCmd, NSCCreate - length rqSubs = " <> tshow (length rqSubActions)
      let (ns, rs, css, cns) = partitionQueueSubActions rqSubActions
      createNewSubs ns
      resetSubs rs
      lift $ do
        forM_ (S.fromList css) $ \srv -> getNtfSMPWorker True c srv
        forM_ (S.fromList cns) $ \srv -> getNtfNTFWorker True c srv
      where
        getQueueSub ::
          DB.Connection ->
          ConnId ->
          IO (Either AgentErrorType (RcvQueue, Maybe NtfSupervisorSub))
        getQueueSub db connId = fmap (first storeError) $ runExceptT $ do
          rq <- ExceptT $ getPrimaryRcvQueue db connId
          sub <- liftIO $ getNtfSubscription db connId
          pure (rq, sub)
        createNewSubs :: [RcvQueue] -> AM ()
        createNewSubs rqs = do
          withTokenServer $ \ntfServer -> do
            let newSubs = map (rqToNewSub ntfServer) rqs
            void $ lift $ withStoreBatch c (\db -> map (storeNewSub db) newSubs)
            kickSMPWorkers rqs
          where
            rqToNewSub :: NtfServer -> RcvQueue -> NtfSubscription
            rqToNewSub ntfServer RcvQueue {userId, connId, server} = newNtfSubscription userId connId server Nothing ntfServer NASNew
            storeNewSub :: DB.Connection -> NtfSubscription -> IO (Either AgentErrorType ())
            storeNewSub db sub = first storeError <$> createNtfSubscription db sub (NSASMP NSASmpKey)
        resetSubs :: [(RcvQueue, NtfSubscription)] -> AM ()
        resetSubs rqSubs = do
          withTokenServer $ \ntfServer -> do
            let subsToReset = map (toResetSub ntfServer) rqSubs
            lift $ void $ withStoreBatch' c (\db -> map (\sub -> supervisorUpdateNtfSub db sub (NSASMP NSASmpKey)) subsToReset)
            let rqs = map fst rqSubs
            kickSMPWorkers rqs
          where
            toResetSub :: NtfServer -> (RcvQueue, NtfSubscription) -> NtfSubscription
            toResetSub ntfServer (rq, sub) =
              let RcvQueue {server = smpServer} = rq
               in sub {smpServer, ntfQueueId = Nothing, ntfServer, ntfSubId = Nothing, ntfSubStatus = NASNew}
        partitionQueueSubActions ::
          [(RcvQueue, Maybe NtfSupervisorSub)] ->
          ( [RcvQueue], -- new subs
            [(RcvQueue, NtfSubscription)], -- reset subs
            [SMPServer], -- continue work (SMP)
            [NtfServer] -- continue work (Ntf)
          )
        partitionQueueSubActions = foldr' decideSubWork ([], [], [], [])
          where
            decideSubWork (rq, Nothing) (ns, rs, css, cns) = (rq : ns, rs, css, cns)
            decideSubWork
              ( rq@RcvQueue {server = rqSMPServer},
                Just (sub@NtfSubscription {ntfServer = subNtfServer, smpServer = subSMPServer}, subAction_)
                )
              (ns, rs, css, cns) =
                case (clientNtfCreds rq, ntfQueueId sub) of
                  (Just ClientNtfCreds {notifierId}, Just ntfQueueId')
                    | sameSrvAddr rqSMPServer subSMPServer && notifierId == ntfQueueId' -> contOrReset
                    | otherwise -> reset
                  (Nothing, Nothing) -> contOrReset
                  _ -> reset
                where
                  contOrReset = case subAction_ of
                    Nothing -> reset
                    Just (action, _)
                      | isDeleteNtfSubAction action -> reset
                      | otherwise -> case action of
                          NSASMP _ -> (ns, rs, rqSMPServer : css, cns)
                          NSANtf _ -> (ns, rs, css, subNtfServer : cns)
                  reset = (ns, (rq, sub) : rs, css, cns)
    NSCSmpDelete -> do
      rqs <- lift $ rights <$> withStoreBatch c (\db -> map (fmap (first storeError) . getPrimaryRcvQueue db) (L.toList connIds))
      logInfo $ "processNtfCmd, NSCSmpDelete - length rqs = " <> tshow (length rqs)
      lift $ void $ withStoreBatch' c (\db -> map (\RcvQueue {connId} -> supervisorUpdateNtfAction db connId (NSASMP NSASmpDelete)) rqs)
      kickSMPWorkers rqs
    NSCNtfWorker ntfServer -> lift . void $ getNtfNTFWorker True c ntfServer
    NSCNtfSMPWorker smpServer -> lift . void $ getNtfSMPWorker True c smpServer
    NSCDeleteSub -> void $ lift $ withStoreBatch' c $ \db -> map (deleteNtfSubscription' db) (L.toList connIds)
  where
    kickSMPWorkers :: [RcvQueue] -> AM ()
    kickSMPWorkers rqs = do
      let smpServers = S.fromList (map (\RcvQueue {server} -> server) rqs)
      forM_ smpServers $ \srv -> lift $ getNtfSMPWorker True c srv

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
runNtfWorker c srv Worker {doWork} =
  forever $ do
    waitForWork doWork
    ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfOperation
  where
    runNtfOperation :: AM ()
    runNtfOperation =
      withWork c doWork (`getNextNtfSubNTFAction` srv) $
        \nextSub@(NtfSubscription {connId}, _, _) -> do
          logInfo $ "runNtfWorker, nextSub " <> tshow nextSub
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            processSub nextSub
              `catchAgentError` retryOnError c "NtfWorker" loop (workerInternalError c connId . show)
    processSub :: (NtfSubscription, NtfSubNTFAction, NtfActionTs) -> AM ()
    processSub (sub@NtfSubscription {userId, connId, smpServer, ntfSubId}, action, actionTs) = do
      ts <- liftIO getCurrentTime
      unlessM (lift $ rescheduleAction doWork ts actionTs) $
        case action of
          NSACreate ->
            lift getNtfToken >>= \case
              Just tkn@NtfToken {ntfServer, ntfTokenId = Just tknId, ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
                RcvQueue {clientNtfCreds} <- withStore c (`getPrimaryRcvQueue` connId)
                case clientNtfCreds of
                  Just ClientNtfCreds {ntfPrivateKey, notifierId} -> do
                    atomically $ incNtfServerStat c userId ntfServer ntfCreateAttempts
                    nSubId <- agentNtfCreateSubscription c tknId tkn (SMPQueueNtf smpServer notifierId) ntfPrivateKey
                    atomically $ incNtfServerStat c userId ntfServer ntfCreated
                    -- possible improvement: smaller retry until Active, less frequently (daily?) once Active
                    let actionTs' = addUTCTime 30 ts
                    withStore' c $ \db ->
                      updateNtfSubscription db sub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew} (NSANtf NSACheck) actionTs'
                  _ -> workerInternalError c connId "NSACreate - no notifier queue credentials"
              _ -> workerInternalError c connId "NSACreate - no active token"
          NSACheck ->
            lift getNtfToken >>= \case
              Just tkn@NtfToken {ntfServer} ->
                case ntfSubId of
                  Just nSubId -> do
                    atomically $ incNtfServerStat c userId ntfServer ntfCheckAttempts
                    agentNtfCheckSubscription c nSubId tkn >>= \case
                      NSAuth -> do
                        withStore' c $ \db ->
                          updateNtfSubscription db sub {ntfServer, ntfQueueId = Nothing, ntfSubId = Nothing, ntfSubStatus = NASNew} (NSASMP NSASmpKey) ts
                        ns <- asks ntfSupervisor
                        atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfSMPWorker smpServer, connId :| [])
                      status -> updateSubNextCheck ts status
                    atomically $ incNtfServerStat c userId ntfServer ntfChecked
                  Nothing -> workerInternalError c connId "NSACheck - no subscription ID"
              _ -> workerInternalError c connId "NSACheck - no active token"
          -- NSADelete and NSARotate are deprecated, but their processing is kept for legacy db records
          NSADelete ->
            deleteNtfSub $ do
              let sub' = sub {ntfSubId = Nothing, ntfSubStatus = NASOff}
              withStore' c $ \db -> updateNtfSubscription db sub' (NSASMP NSASmpDelete) ts
              ns <- asks ntfSupervisor
              atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfSMPWorker smpServer, connId :| []) -- TODO [batch ntf] loop
          NSARotate ->
            deleteNtfSub $ do
              withStore' c $ \db -> deleteNtfSubscription db connId
              ns <- asks ntfSupervisor
              atomically $ writeTBQueue (ntfSubQ ns) (NSCCreate, connId :| []) -- TODO [batch ntf] loop
      where
        -- deleteNtfSub is only used in NSADelete and NSARotate, so also deprecated
        deleteNtfSub continue = case ntfSubId of
          Just nSubId ->
            lift getNtfToken >>= \case
              Just tkn@NtfToken {ntfServer} -> do
                atomically $ incNtfServerStat c userId ntfServer ntfDelAttempts
                tryAgentError (agentNtfDeleteSubscription c nSubId tkn) >>= \case
                  Left e | temporaryOrHostError e -> throwE e
                  _ -> continue
                atomically $ incNtfServerStat c userId ntfServer ntfDeleted
              Nothing -> continue
          _ -> continue
        updateSubNextCheck ts toStatus = do
          checkInterval <- asks $ ntfSubCheckInterval . config
          let nextCheckTs = addUTCTime checkInterval ts
          updateSub (NASCreated toStatus) (NSANtf NSACheck) nextCheckTs
        updateSub toStatus toAction actionTs' =
          withStore' c $ \db ->
            updateNtfSubscription db sub {ntfSubStatus = toStatus} toAction actionTs'

runNtfSMPWorker :: AgentClient -> SMPServer -> Worker -> AM ()
runNtfSMPWorker c srv Worker {doWork} = do
  env <- ask
  forever $ do
    waitForWork doWork
    ExceptT . liftIO . agentOperationBracket c AONtfNetwork throwWhenInactive $
      runReaderT (runExceptT runNtfSMPOperation) env
  where
    runNtfSMPOperation =
      withWork c doWork (`getNextNtfSubSMPAction` srv) $
        \nextSub@(NtfSubscription {connId}, _, _) -> do
          logInfo $ "runNtfSMPWorker, nextSub " <> tshow nextSub
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
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
                  updateNtfSubscription db sub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey} (NSANtf NSACreate) ts
                ns <- asks ntfSupervisor
                atomically $ sendNtfSubCommand ns (NSCNtfWorker ntfServer, connId :| [])
              _ -> workerInternalError c connId "NSASmpKey - no active token"
          NSASmpDelete -> do
            -- TODO should we remove it after successful removal from the server?
            rq_ <- withStore' c $ \db -> do
              setRcvQueueNtfCreds db connId Nothing
              getPrimaryRcvQueue db connId
            mapM_ (disableQueueNotifications c) rq_
            withStore' c $ \db -> deleteNtfSubscription db connId

rescheduleAction :: TMVar () -> UTCTime -> UTCTime -> AM' Bool
rescheduleAction doWork ts actionTs
  | actionTs <= ts = pure False
  | otherwise = do
      void . atomically $ tryTakeTMVar doWork
      void . forkIO $ do
        liftIO $ threadDelay' $ diffToMicroseconds $ diffUTCTime actionTs ts
        atomically $ hasWorkToDo' doWork
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
      atomically $ endAgentOperation c AONtfNetwork
      liftIO $ throwWhenInactive c
      atomically $ beginAgentOperation c AONtfNetwork
      loop

workerInternalError :: AgentClient -> ConnId -> String -> AM ()
workerInternalError c connId internalErrStr = do
  withStore' c $ \db -> setNullNtfSubscriptionAction db connId
  notifyInternalError c connId internalErrStr

-- TODO change error
notifyInternalError :: MonadIO m => AgentClient -> ConnId -> String -> m ()
notifyInternalError AgentClient {subQ} connId internalErrStr = atomically $ writeTBQueue subQ ("", connId, AEvt SAEConn $ ERR $ INTERNAL internalErrStr)
{-# INLINE notifyInternalError #-}

notifyInternalError' :: MonadIO m => AgentClient -> String -> m ()
notifyInternalError' AgentClient {subQ} internalErrStr = atomically $ writeTBQueue subQ ("", "", AEvt SAEConn $ ERR $ INTERNAL internalErrStr)
{-# INLINE notifyInternalError' #-}

getNtfToken :: AM' (Maybe NtfToken)
getNtfToken = do
  tkn <- asks $ ntfTkn . ntfSupervisor
  readTVarIO tkn

nsUpdateToken :: NtfSupervisor -> NtfToken -> STM ()
nsUpdateToken ns tkn = writeTVar (ntfTkn ns) $ Just tkn

nsRemoveNtfToken :: NtfSupervisor -> STM ()
nsRemoveNtfToken ns = writeTVar (ntfTkn ns) Nothing

sendNtfSubCommand :: NtfSupervisor -> (NtfSupervisorCommand, NonEmpty ConnId) -> STM ()
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
    stopWorkers workers = atomically (swapTVar workers M.empty) >>= mapM_ (liftIO . cancelWorker)

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
