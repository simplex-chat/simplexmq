{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
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
import Data.Either (partitionEithers)
import Data.Foldable (foldr')
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock (diffUTCTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Stats
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (NtfSubStatus (..), NtfSubscriptionId, NtfTknStatus (..), SMPQueueNtf (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, sameSrvAddr)
import qualified Simplex.Messaging.Protocol as SMP
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

partitionErrs :: (a -> ConnId) -> [a] -> [Either AgentErrorType b] -> ([(ConnId, AgentErrorType)], [b])
partitionErrs f xs = partitionEithers . zipWith (\x -> first (f x,)) xs
{-# INLINE partitionErrs #-}

ntfSubConnId :: NtfSubscription -> ConnId
ntfSubConnId NtfSubscription {connId} = connId

processNtfCmd :: AgentClient -> (NtfSupervisorCommand, NonEmpty ConnId) -> AM ()
processNtfCmd c (cmd, connIds) = do
  logInfo $ "processNtfCmd - cmd = " <> tshow cmd
  let connIds' = L.toList connIds
  case cmd of
    NSCCreate -> do
      (cErrs, rqSubActions) <- lift $ partitionErrs id connIds' <$> withStoreBatch c (\db -> map (getQueueSub db) connIds')
      notifyErrs c cErrs
      logInfo $ "processNtfCmd, NSCCreate - length rqSubs = " <> tshow (length rqSubActions)
      let (ns, rs, css, cns) = partitionQueueSubActions rqSubActions
      createNewSubs ns
      resetSubs rs
      lift $ do
        mapM_ (getNtfSMPWorker True c) (S.fromList css)
        mapM_ (getNtfNTFWorker True c) (S.fromList cns)
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
            (cErrs, _) <- lift $ partitionErrs ntfSubConnId newSubs <$> withStoreBatch c (\db -> map (storeNewSub db) newSubs)
            notifyErrs c cErrs
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
            (cErrs, _) <- lift $ partitionErrs ntfSubConnId subsToReset <$> withStoreBatch' c (\db -> map (storeResetSub db) subsToReset)
            notifyErrs c cErrs
            let rqs = map fst rqSubs
            kickSMPWorkers rqs
          where
            toResetSub :: NtfServer -> (RcvQueue, NtfSubscription) -> NtfSubscription
            toResetSub ntfServer (rq, sub) =
              let RcvQueue {server = smpServer} = rq
               in sub {smpServer, ntfQueueId = Nothing, ntfServer, ntfSubId = Nothing, ntfSubStatus = NASNew}
            storeResetSub :: DB.Connection -> NtfSubscription -> IO ()
            storeResetSub db sub = supervisorUpdateNtfSub db sub (NSASMP NSASmpKey)
        partitionQueueSubActions ::
          [(RcvQueue, Maybe NtfSupervisorSub)] ->
          ( [RcvQueue], -- new subs
            [(RcvQueue, NtfSubscription)], -- reset subs
            [SMPServer], -- continue work (SMP)
            [NtfServer] -- continue work (Ntf)
          )
        partitionQueueSubActions = foldr' decideSubWork ([], [], [], [])
          where
            -- sub = Nothing, needs to be created
            decideSubWork (rq, Nothing) (ns, rs, css, cns) = (rq : ns, rs, css, cns)
            decideSubWork (rq, Just (sub, subAction_)) (ns, rs, css, cns) =
              case (clientNtfCreds rq, ntfQueueId sub) of
                -- notifier ID created on SMP server (on ntf server subscription can be registered or not yet),
                -- need to clarify action
                (Just ClientNtfCreds {notifierId}, Just ntfQueueId')
                  | sameSrvAddr (qServer rq) subSMPServer && notifierId == ntfQueueId' -> contOrReset
                  | otherwise -> reset
                (Nothing, Nothing) -> contOrReset
                _ -> reset
              where
                NtfSubscription {ntfServer = subNtfServer, smpServer = subSMPServer} = sub
                contOrReset = case subAction_ of
                  -- action was set to NULL after worker internal error
                  Nothing -> reset
                  Just (action, _)
                    -- subscription was marked for deletion / is being deleted
                    | isDeleteNtfSubAction action -> reset
                    -- continue work on subscription (e.g. supervisor was repeatedly tasked with creating a subscription)
                    | otherwise -> case action of
                        NSASMP _ -> (ns, rs, qServer rq : css, cns)
                        NSANtf _ -> (ns, rs, css, subNtfServer : cns)
                reset = (ns, (rq, sub) : rs, css, cns)
    NSCSmpDelete -> do
      (cErrs, rqs) <- lift $ partitionErrs id connIds' <$> withStoreBatch c (\db -> map (getQueue db) connIds')
      logInfo $ "processNtfCmd, NSCSmpDelete - length rqs = " <> tshow (length rqs)
      (cErrs', _) <- lift $ partitionErrs qConnId rqs <$> withStoreBatch' c (\db -> map (updateAction db) rqs)
      notifyErrs c (cErrs <> cErrs')
      kickSMPWorkers rqs
      where
        getQueue :: DB.Connection -> ConnId -> IO (Either AgentErrorType RcvQueue)
        getQueue db connId = first storeError <$> getPrimaryRcvQueue db connId
        updateAction :: DB.Connection -> RcvQueue -> IO ()
        updateAction db rq = supervisorUpdateNtfAction db (qConnId rq) (NSASMP NSASmpDelete)
    NSCNtfWorker ntfServer -> lift . void $ getNtfNTFWorker True c ntfServer
    NSCNtfSMPWorker smpServer -> lift . void $ getNtfSMPWorker True c smpServer
    NSCDeleteSub -> void $ lift $ withStoreBatch' c $ \db -> map (deleteNtfSubscription' db) connIds'
  where
    kickSMPWorkers :: [RcvQueue] -> AM ()
    kickSMPWorkers rqs = do
      let smpServers = S.fromList $ map qServer rqs
      lift $ mapM_ (getNtfSMPWorker True c) smpServers

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
      withWork c doWork (`getNextNtfSubNTFActions` srv) $
        \nextActions -> do
          logInfo $ "runNtfWorker - length nextActions = " <> tshow (length nextActions)
          -- withRetryInterval - retry only network errors?
          -- but: list of actions can differ per retry -> custom retry logic? no retry (retry via db)?
          liftIO $ waitWhileSuspended c
          liftIO $ waitForUserNetwork c
          processSubActions nextActions
    processSubActions :: NonEmpty NtfNTFWorkItem -> AM ()
    processSubActions subActions = do
      ts <- liftIO getCurrentTime
      let subActions' = L.filter (\(_, _, actionTs) -> actionTs <= ts) subActions
          (_, _, firstActionTs) = L.head subActions
      case L.nonEmpty subActions' of
        Nothing -> lift $ rescheduleWork doWork ts firstActionTs
        Just subActions'' -> do
          -- split by action type
          let (creates, checks, deletes, rotates) = splitActions subActions''
          -- process each action type actions in order and batched per action type
          createSubs creates
          deleteSubs deletes
          rotateSubs rotates
          -- mark successes and permanent errors per action type
          -- collect temporary errors across all actions -> retry with new action list?
          pure ()
    splitActions :: NonEmpty NtfNTFWorkItem -> ([NtfSubscription], [NtfSubscription], [NtfSubscription], [NtfSubscription])
    splitActions = foldl' addAction ([], [], [], [])
      where
        addAction (creates, checks, deletes, rotates) = \case
          (sub, NSACreate, _) -> (sub : creates, checks, deletes, rotates)
          (sub, NSACheck, _) -> (creates, sub : checks, deletes, rotates)
          (sub, NSADelete, _) -> (creates, checks, sub : deletes, rotates)
          (sub, NSARotate, _) -> (creates, checks, deletes, sub : rotates)
    createSubs :: [NtfSubscription] -> AM ()
    createSubs subs =
      lift getNtfToken >>= \case
        Just tkn@NtfToken {ntfServer, ntfTokenId = Just tknId, ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
          subsRqs_ <- lift $ zip subs <$> withStoreBatch c (\db -> map (getQueue db) subs)
          let (subsErrs, subsCreds) = splitSubs subsRqs_
          case L.nonEmpty subsCreds of
            Nothing -> workerErrors c subsErrs
            Just subsCreds' -> do
              let subAttempts = countByUserId (L.toList subsCreds')
              forM_ (M.toList subAttempts) $ \(userId, count) ->
                atomically $ incNtfServerStat' c userId ntfServer ntfCreateAttempts count
              nSubIds_ <- lift $ agentNtfCreateSubscriptions c tknId tkn (L.map toSubKey subsCreds')
              let (nSubErrs, nSubIds) = splitResults nSubIds_
              let subsCreated = countByUserId nSubIds
              forM_ (M.toList subsCreated) $ \(userId, count) ->
                atomically $ incNtfServerStat' c userId ntfServer ntfCreated count
              ts <- liftIO getCurrentTime
              let checkTs = addUTCTime 30 ts
              (cErrs, _) <- lift $ partitionErrs nSubConnId nSubIds <$> withStoreBatch' c (\db -> map (updateSubNSACheck db checkTs) nSubIds)
              workerErrors c (subsErrs <> nSubErrs <> cErrs)
        _ -> do
          let errs = map (\sub -> (ntfSubConnId sub, INTERNAL "NSACreate - no active token")) subs
          workerErrors c errs
      where
        getQueue :: DB.Connection -> NtfSubscription -> IO (Either AgentErrorType RcvQueue)
        getQueue db NtfSubscription {connId} = first storeError <$> getPrimaryRcvQueue db connId
        splitSubs :: [(NtfSubscription, Either AgentErrorType RcvQueue)] -> ([(ConnId, AgentErrorType)], [(NtfSubscription, ClientNtfCreds)])
        splitSubs = foldr' splitSub ([], [])
          where
            splitSub (sub, Right RcvQueue {clientNtfCreds = Just creds}) (errs, ss) = (errs, (sub, creds) : ss)
            splitSub (sub, Right _) (errs, ss) = ((ntfSubConnId sub, INTERNAL "NSACreate - no notifier queue credentials") : errs, ss)
            splitSub (sub, Left e) (errs, ss) = ((ntfSubConnId sub, e) : errs, ss)
        countByUserId :: [(NtfSubscription, a)] -> M.Map UserId Int
        countByUserId = foldr' (\(NtfSubscription {userId}, _) acc -> M.insertWith (+) userId 1 acc) M.empty
        toSubKey :: (NtfSubscription, ClientNtfCreds) -> (NtfSubscription, SMPQueueNtf, SMP.NtfPrivateAuthKey)
        toSubKey (sub@NtfSubscription {smpServer}, ClientNtfCreds {ntfPrivateKey, notifierId}) =
          (sub, SMPQueueNtf smpServer notifierId, ntfPrivateKey)
        splitResults :: NonEmpty (NtfSubscription, Either AgentErrorType NtfSubscriptionId) -> ([(ConnId, AgentErrorType)], [(NtfSubscription, NtfSubscriptionId)])
        splitResults = foldr' addRes ([], [])
          where
            addRes (sub, Right nSubId) (errs, sIds) = (errs, (sub, nSubId) : sIds)
            addRes (sub, Left e) (errs, sIds) = ((ntfSubConnId sub, e) : errs, sIds)
        updateSubNSACheck :: DB.Connection -> UTCTime -> (NtfSubscription, NtfSubscriptionId) -> IO ()
        updateSubNSACheck db checkTs (sub, nSubId) = updateNtfSubscription db sub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew} (NSANtf NSACheck) checkTs
        nSubConnId :: (NtfSubscription, NtfSubscriptionId) -> ConnId
        nSubConnId (NtfSubscription {connId}, _) = connId
    -- NSADelete and NSARotate are deprecated, but their processing is kept for legacy db records
    deleteSubs :: [NtfSubscription] -> AM ()
    deleteSubs subs =
      forM_ subs $ \sub@NtfSubscription {connId, smpServer} ->
        deleteNtfSub sub $ do
          ts <- liftIO getCurrentTime
          let sub' = sub {ntfSubId = Nothing, ntfSubStatus = NASOff}
          withStore' c $ \db -> updateNtfSubscription db sub' (NSASMP NSASmpDelete) ts
          ns <- asks ntfSupervisor
          atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfSMPWorker smpServer, [connId])
    rotateSubs :: [NtfSubscription] -> AM ()
    rotateSubs subs =
      forM_ subs $ \sub@NtfSubscription {connId} ->
        deleteNtfSub sub $ do
          withStore' c $ \db -> deleteNtfSubscription db connId
          ns <- asks ntfSupervisor
          atomically $ writeTBQueue (ntfSubQ ns) (NSCCreate, [connId])
    -- deleteNtfSub is only used in NSADelete and NSARotate, so also deprecated
    deleteNtfSub :: NtfSubscription -> AM () -> AM ()
    deleteNtfSub NtfSubscription {userId, ntfSubId} continue = case ntfSubId of
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
    -- -------------------- below - old code --------------------
    runNtfOperation' :: AM ()
    runNtfOperation' =
      withWork c doWork (`getNextNtfSubNTFActions` srv) $
        \nextActions@((NtfSubscription {connId}, _, _) :| _) -> do
          logInfo $ "runNtfWorker - length nextActions = " <> tshow (length nextActions)
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            processSubActions' nextActions
              `catchAgentError` retryOnError c "NtfWorker" loop (workerInternalError c connId . show)
    processSubActions' :: NonEmpty NtfNTFWorkItem -> AM ()
    processSubActions' [(sub@NtfSubscription {userId, connId, smpServer, ntfSubId}, action, actionTs)] = do
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
                        atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfSMPWorker smpServer, [connId])
                      status -> updateSubNextCheck ts status
                    atomically $ incNtfServerStat c userId ntfServer ntfChecked
                  Nothing -> workerInternalError c connId "NSACheck - no subscription ID"
              _ -> workerInternalError c connId "NSACheck - no active token"
          -- NSADelete and NSARotate are deprecated, but their processing is kept for legacy db records
          NSADelete ->
            deleteNtfSub sub $ do
              let sub' = sub {ntfSubId = Nothing, ntfSubStatus = NASOff}
              withStore' c $ \db -> updateNtfSubscription db sub' (NSASMP NSASmpDelete) ts
              ns <- asks ntfSupervisor
              atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfSMPWorker smpServer, [connId]) -- TODO [batch ntf] loop
          NSARotate ->
            deleteNtfSub sub $ do
              withStore' c $ \db -> deleteNtfSubscription db connId
              ns <- asks ntfSupervisor
              atomically $ writeTBQueue (ntfSubQ ns) (NSCCreate, [connId]) -- TODO [batch ntf] loop
      where
        updateSubNextCheck ts toStatus = do
          checkInterval <- asks $ ntfSubCheckInterval . config
          let nextCheckTs = addUTCTime checkInterval ts
          updateSub (NASCreated toStatus) (NSANtf NSACheck) nextCheckTs
        updateSub toStatus toAction actionTs' =
          withStore' c $ \db ->
            updateNtfSubscription db sub {ntfSubStatus = toStatus} toAction actionTs'
    processSubActions' _ = pure ()

runNtfSMPWorker :: AgentClient -> SMPServer -> Worker -> AM ()
runNtfSMPWorker c srv Worker {doWork} =
  forever $ do
    waitForWork doWork
    ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfSMPOperation
  where
    runNtfSMPOperation :: AM ()
    runNtfSMPOperation =
      withWork c doWork (`getNextNtfSubSMPActions` srv) $
        \nextActions -> do
          logInfo $ "runNtfSMPWorker - length nextActions = " <> tshow (length nextActions)
          -- withRetryInterval - retry only network errors?
          -- but: list of actions can differ per retry -> custom retry logic? no retry (retry via db)?
          liftIO $ waitWhileSuspended c
          liftIO $ waitForUserNetwork c
          processSubActions nextActions
    processSubActions :: NonEmpty NtfSMPWorkItem -> AM ()
    processSubActions subActions = do
      ts <- liftIO getCurrentTime
      let subActions' = L.filter (\(_, _, actionTs) -> actionTs <= ts) subActions
          (_, _, firstActionTs) = L.head subActions
      case L.nonEmpty subActions' of
        Nothing -> lift $ rescheduleWork doWork ts firstActionTs
        Just subActions'' -> do
          -- split by action type
          let (creates, deletes) = splitActions subActions''
          -- process each action type actions in order and batched per action type
          createSubKeys creates
          -- mark successes and permanent errors per action type
          -- collect temporary errors across all actions -> retry with new action list?
          pure ()
    splitActions :: NonEmpty NtfSMPWorkItem -> ([NtfSubscription], [NtfSubscription])
    splitActions = foldl' addAction ([], [])
      where
        addAction (creates, deletes) = \case
          (sub, NSASmpKey, _) -> (sub : creates, deletes)
          (sub, NSASmpDelete, _) -> (creates, sub : deletes)
    createSubKeys :: [NtfSubscription] -> AM ()
    createSubKeys subs =
      lift getNtfToken >>= \case
        Just NtfToken {ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
          subsRqs_ <- lift $ zip subs <$> withStoreBatch c (\db -> map (getQueue db) subs)
          let (subsErrs, subsRqs) = splitSubs subsRqs_
          subsRqsKeys <- generateKeys subsRqs
          nSubIdsKeys_ <- lift $ zip subsRqsKeys <$> enableQueuesNtfs c (map toReq subsRqsKeys)
          let (nSubErrs, nSubIdsKeys) = splitResults nSubIdsKeys_
          let nSubIdsSecrets = calcSecrets nSubIdsKeys
          ts <- liftIO getCurrentTime
          (cErrs, srvsConnIds) <- lift $ partitionErrs nSubConnId nSubIdsSecrets <$> withStoreBatch' c (\db -> map (updateSubNSACreate db ts) nSubIdsSecrets)
          ns <- asks ntfSupervisor
          let srvConns = groupBySrv srvsConnIds
          forM_ (M.toList srvConns) $ \(ntfSrv, connIds) ->
            forM_ (L.nonEmpty connIds) $ \connIds' ->
              atomically $ writeTBQueue (ntfSubQ ns) (NSCNtfWorker ntfSrv, L.reverse connIds')
          workerErrors c (subsErrs <> nSubErrs <> cErrs)
        _ -> do
          let errs = map (\sub -> (ntfSubConnId sub, INTERNAL "NSASmpKey - no active token")) subs
          workerErrors c errs
      where
        getQueue :: DB.Connection -> NtfSubscription -> IO (Either AgentErrorType RcvQueue)
        getQueue db NtfSubscription {connId} = first storeError <$> getPrimaryRcvQueue db connId
        splitSubs :: [(NtfSubscription, Either AgentErrorType RcvQueue)] -> ([(ConnId, AgentErrorType)], [(NtfSubscription, RcvQueue)])
        splitSubs = foldr' splitSub ([], [])
          where
            splitSub (sub, Right rq) (errs, ss) = (errs, (sub, rq) : ss)
            splitSub (sub, Left e) (errs, ss) = ((ntfSubConnId sub, e) : errs, ss)
        generateKeys ::
          [(NtfSubscription, RcvQueue)] ->
          AM [(NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519)]
        generateKeys subsRqs = do
          C.AuthAlg a <- asks (rcvAuthAlg . config)
          g <- asks random
          liftIO $ forM subsRqs $ \(sub, rq) -> do
            (ntfPublicKey, ntfPrivateKey) <- atomically $ C.generateAuthKeyPair a g
            (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- atomically $ C.generateKeyPair g
            pure (sub, rq, (ntfPublicKey, ntfPrivateKey), (rcvNtfPubDhKey, rcvNtfPrivDhKey))
        toReq :: (NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519) -> (RcvQueue, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey)
        toReq (_sub, rq, (ntfPublicKey, _ntfPrivateKey), (rcvNtfPubDhKey, _rcvNtfPrivDhKey)) = (rq, ntfPublicKey, rcvNtfPubDhKey)
        splitResults ::
          [((NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519), (RcvQueue, Either AgentErrorType (SMP.NotifierId, SMP.RcvNtfPublicDhKey)))] ->
          ([(ConnId, AgentErrorType)], [(NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519, SMP.NotifierId, SMP.RcvNtfPublicDhKey)])
        splitResults = foldr' addRes ([], [])
          where
            addRes (subRq, (_rq, Right sIdKey)) (errs, sIdsKeys) = (errs, toSub subRq sIdKey : sIdsKeys)
            addRes ((sub, _, _, _), (_rq, Left e)) (errs, sIds) = ((ntfSubConnId sub, e) : errs, sIds)
            toSub ::
              (NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519) ->
              (SMP.NotifierId, SMP.RcvNtfPublicDhKey) ->
              (NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519, SMP.NotifierId, SMP.RcvNtfPublicDhKey)
            toSub (sub, rq, authKeyPair, rcvKeyPair) (notifierId, rcvNtfSrvPubDhKey) =
              (sub, rq, authKeyPair, rcvKeyPair, notifierId, rcvNtfSrvPubDhKey)
        calcSecrets ::
          [(NtfSubscription, RcvQueue, C.AAuthKeyPair, C.KeyPairX25519, SMP.NotifierId, SMP.RcvNtfPublicDhKey)] ->
          [(NtfSubscription, RcvQueue, C.AAuthKeyPair, SMP.NotifierId, SMP.RcvNtfDhSecret)]
        calcSecrets = map toSubSecret
          where
            toSubSecret (sub, rq, authKeyPair, (_rcvNtfPubDhKey, rcvNtfPrivDhKey), notifierId, rcvNtfSrvPubDhKey) =
              let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
               in (sub, rq, authKeyPair, notifierId, rcvNtfDhSecret)
        updateSubNSACreate :: DB.Connection -> UTCTime -> (NtfSubscription, RcvQueue, C.AAuthKeyPair, SMP.NotifierId, SMP.RcvNtfDhSecret) -> IO (NtfServer, ConnId)
        updateSubNSACreate db ts (sub@NtfSubscription {ntfServer}, _rq, (ntfPublicKey, ntfPrivateKey), notifierId, rcvNtfDhSecret) = do
          setRcvQueueNtfCreds db (ntfSubConnId sub) $ Just ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
          updateNtfSubscription db sub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey} (NSANtf NSACreate) ts
          pure (ntfServer, ntfSubConnId sub)
        nSubConnId :: (NtfSubscription, RcvQueue, C.AAuthKeyPair, SMP.NotifierId, SMP.RcvNtfDhSecret) -> ConnId
        nSubConnId (NtfSubscription {connId}, _, _, _, _) = connId
        groupBySrv :: [(NtfServer, ConnId)] -> Map NtfServer [ConnId]
        groupBySrv = foldr' addConn M.empty
          where
            addConn (ntfSrv, connId) = M.alter (Just . maybe [connId] (connId :)) ntfSrv
    deleteSubs :: [NtfSubscription] -> AM ()
    deleteSubs subs = do
      -- subsRqs_ <- lift $ zip subs <$> withStoreBatch c (\db -> map (getQueue db) subs)
      pure ()
      where
        resetCredsGetQueue :: DB.Connection -> ConnId -> IO (Either AgentErrorType RcvQueue)
        resetCredsGetQueue db connId = fmap (first storeError) $ runExceptT $ do
          liftIO $ setRcvQueueNtfCreds db connId Nothing
          ExceptT $ getPrimaryRcvQueue db connId
    -- -------------------- below - old code --------------------
    runNtfSMPOperation' :: AM ()
    runNtfSMPOperation' =
      withWork c doWork (`getNextNtfSubSMPActions` srv) $
        \nextActions@((NtfSubscription {connId}, _, _) :| _) -> do
          logInfo $ "runNtfSMPWorker - length nextActions " <> tshow (length nextActions)
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            processSubActions' nextActions
              `catchAgentError` retryOnError c "NtfSMPWorker" loop (workerInternalError c connId . show)
    processSubActions' :: NonEmpty NtfSMPWorkItem -> AM ()
    processSubActions' [(sub@NtfSubscription {connId, ntfServer}, smpAction, actionTs)] = do
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
                atomically $ sendNtfSubCommand ns (NSCNtfWorker ntfServer, [connId])
              _ -> workerInternalError c connId "NSASmpKey - no active token"
          NSASmpDelete -> do
            -- TODO should we remove it after successful removal from the server?
            rq_ <- withStore' c $ \db -> do
              setRcvQueueNtfCreds db connId Nothing
              getPrimaryRcvQueue db connId
            mapM_ (disableQueueNotifications c) rq_
            withStore' c $ \db -> deleteNtfSubscription db connId
    processSubActions' _ = pure ()

rescheduleAction :: TMVar () -> UTCTime -> UTCTime -> AM' Bool
rescheduleAction doWork ts actionTs
  | actionTs <= ts = pure False
  | otherwise = do
      rescheduleWork doWork ts actionTs
      pure True

rescheduleWork :: TMVar () -> UTCTime -> UTCTime -> AM' ()
rescheduleWork doWork ts actionTs = do
  void . atomically $ tryTakeTMVar doWork
  void . forkIO $ do
    liftIO $ threadDelay' $ diffToMicroseconds $ diffUTCTime actionTs ts
    atomically $ hasWorkToDo' doWork

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

workerErrors :: AgentClient -> [(ConnId, AgentErrorType)] -> AM ()
workerErrors c connErrs =
  unless (null connErrs) $ do
    void $ lift $ withStoreBatch' c (\db -> map (setNullNtfSubscriptionAction db . fst) connErrs)
    notifyErrs c connErrs

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

notifyErrs :: MonadIO m => AgentClient -> [(ConnId, AgentErrorType)] -> m ()
notifyErrs AgentClient {subQ} connErrs = unless (null connErrs) $ atomically $ writeTBQueue subQ ("", "", AEvt SAENone $ ERRS connErrs)
{-# INLINE notifyErrs #-}

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
