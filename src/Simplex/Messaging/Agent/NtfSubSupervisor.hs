{-# LANGUAGE DataKinds #-}
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
    hasInstantNotifications,
    instantNotifications,
    deleteToken,
    closeNtfSupervisor,
    getNtfServer,
  )
where

import Control.Logger.Simple (logError, logInfo)
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (first)
import Data.Either (fromRight, partitionEithers)
import Data.Functor (($>))
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import qualified Data.Set as S
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock (diffUTCTime)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Stats
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.AgentStore
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Client (NetworkRequestMode (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Protocol (NtfServer, sameSrvAddr)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (diffToMicroseconds, threadDelay', tshow, whenM)
import System.Random (randomR)
import UnliftIO
import UnliftIO.Concurrent (forkIO)
import qualified UnliftIO.Exception as E

runNtfSupervisor :: AgentClient -> AM' ()
runNtfSupervisor c = do
  ns <- asks ntfSupervisor
  runExceptT startTknDelete >>= \case
    Left e -> notifyErr e
    Right _ -> pure ()
  forever $ do
    cmd <- atomically . readTBQueue $ ntfSubQ ns
    handleErr . agentOperationBracket c AONtfNetwork waitUntilActive $
      runExceptT (processNtfCmd c cmd) >>= \case
        Left e -> notifyErr e
        Right _ -> return ()
  where
    startTknDelete :: AM ()
    startTknDelete = do
      pendingDelServers <- withStore' c getPendingDelTknServers
      lift . forM_ pendingDelServers $ getNtfTknDelWorker True c
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
        partitionQueueSubActions = foldr decideSubWork ([], [], [], [])
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

getNtfTknDelWorker :: Bool -> AgentClient -> NtfServer -> AM' Worker
getNtfTknDelWorker hasWork c server = do
  ws <- asks $ ntfTknDelWorkers . ntfSupervisor
  getAgentWorker "ntf_tkn_del" hasWork c server ws $ runNtfTknDelWorker c server

withTokenServer :: (NtfServer -> AM ()) -> AM ()
withTokenServer action = lift getNtfToken >>= mapM_ (\NtfToken {ntfServer} -> action ntfServer)

runNtfWorker :: AgentClient -> NtfServer -> Worker -> AM ()
runNtfWorker c srv Worker {doWork} =
  forever $ do
    waitForWork doWork
    ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfOperation
  where
    runNtfOperation :: AM ()
    runNtfOperation = do
      ntfBatchSize <- asks $ ntfBatchSize . config
      withWorkItems c doWork (\db -> getNextNtfSubNTFActions db srv ntfBatchSize) $ \nextSubs -> do
        logInfo $ "runNtfWorker - length nextSubs = " <> tshow (length nextSubs)
        currTs <- liftIO getCurrentTime
        let (creates, checks, deletes, rotates) = splitActions currTs nextSubs
        if null creates && null checks && null deletes && null rotates
          then
            let (_, _, firstActionTs) = L.head nextSubs
             in lift $ rescheduleWork doWork currTs firstActionTs
          else do
            retrySubActions c creates createSubs
            retrySubActions c checks checkSubs
            retrySubActions c deletes deleteSubs
            retrySubActions c rotates rotateSubs
    splitActions :: UTCTime -> NonEmpty (NtfSubNTFAction, NtfSubscription, NtfActionTs) -> ([NtfSubscription], [NtfSubscription], [NtfSubscription], [NtfSubscription])
    splitActions currTs = foldr addAction ([], [], [], [])
      where
        addAction (cmd, sub, ts) acc@(creates, checks, deletes, rotates) = case cmd of
          NSACreate -> (sub : creates, checks, deletes, rotates)
          NSACheck
            | ts <= currTs -> (creates, sub : checks, deletes, rotates)
            | otherwise -> acc
          NSADelete -> (creates, checks, sub : deletes, rotates)
          NSARotate -> (creates, checks, deletes, sub : rotates)
    createSubs :: [NtfSubscription] -> AM' [NtfSubscription]
    createSubs ntfSubs =
      getNtfToken >>= \case
        Just tkn@NtfToken {ntfServer, ntfTokenId = Just tknId, ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
          subsRqs_ <- zip ntfSubs <$> withStoreBatch c (\db -> map (getQueue db) ntfSubs)
          let (errs1, subs_, newSubs_) = splitSubs tknId subsRqs_
          incStatByUserId ntfServer ntfCreateAttempts subs_
          case (L.nonEmpty subs_, L.nonEmpty newSubs_) of
            (Just subs, Just newSubs) -> do
              rs <- L.zip subs <$> agentNtfCreateSubscriptions c tkn newSubs
              let (ntfSubs', errs2, nSubIds) = splitResults $ L.toList rs
                  subs' = map fst nSubIds
                  errs2' = map (first ntfSubConnId) errs2
              incStatByUserId ntfServer ntfCreated subs'
              ts <- liftIO getCurrentTime
              int <- asks $ ntfSubFirstCheckInterval . config
              let checkTs = addUTCTime int ts
              (errs3, _) <- partitionErrs ntfSubConnId subs' <$> withStoreBatch' c (\db -> map (updateSubNSACheck db checkTs) nSubIds)
              workerErrors c $ errs1 <> errs2' <> errs3
              pure ntfSubs'
            _ -> workerErrors c errs1 $> []
        _ -> do
          let errs = map (\sub -> (ntfSubConnId sub, INTERNAL "NSACreate - no active token")) ntfSubs
          workerErrors c errs
          pure []
      where
        getQueue :: DB.Connection -> NtfSubscription -> IO (Either AgentErrorType RcvQueue)
        getQueue db NtfSubscription {connId} = first storeError <$> getPrimaryRcvQueue db connId
        splitSubs :: NtfTokenId -> [(NtfSubscription, Either AgentErrorType RcvQueue)] -> ([(ConnId, AgentErrorType)], [NtfSubscription], [NewNtfEntity 'Subscription])
        splitSubs tknId = foldr splitSub ([], [], [])
          where
            splitSub (sub, rq) (errs, subs, newSubs) = case rq of
              Right RcvQueue {clientNtfCreds = Just creds} -> (errs, sub : subs, toNewSub sub creds : newSubs)
              Right _ -> ((ntfSubConnId sub, INTERNAL "NSACreate - no notifier queue credentials") : errs, subs, newSubs)
              Left e -> ((ntfSubConnId sub, e) : errs, subs, newSubs)
            toNewSub NtfSubscription {smpServer} ClientNtfCreds {ntfPrivateKey, notifierId} =
              NewNtfSub tknId (SMPQueueNtf smpServer notifierId) ntfPrivateKey
        updateSubNSACheck :: DB.Connection -> UTCTime -> (NtfSubscription, NtfSubscriptionId) -> IO ()
        updateSubNSACheck db checkTs (sub, nSubId) = updateNtfSubscription db sub {ntfSubId = Just nSubId, ntfSubStatus = NASCreated NSNew} (NSANtf NSACheck) checkTs
    checkSubs :: [NtfSubscription] -> AM' [NtfSubscription]
    checkSubs ntfSubs =
      getNtfToken >>= \case
        Just tkn@NtfToken {ntfServer, ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
          let (errs1, subs_, subIds_) = splitSubs ntfSubs
          incStatByUserId ntfServer ntfCheckAttempts subs_
          case (L.nonEmpty subs_, L.nonEmpty subIds_) of
            (Just subs, Just subIds) -> do
              rs <- L.zip subs <$> agentNtfCheckSubscriptions c tkn subIds
              let (ntfSubs', errs2, nSubStatuses) = splitResults $ L.toList rs
                  subs' = map fst nSubStatuses
                  (errs2', authSubs) = partitionEithers $ map (\case (sub, NTF _ SMP.AUTH) -> Right sub; e -> Left $ first ntfSubConnId e) errs2
              incStatByUserId ntfServer ntfChecked subs'
              ts <- liftIO getCurrentTime
              int <- asks $ ntfSubCheckInterval . config
              let nextCheckTs = addUTCTime int ts
              (errs3, srvs) <- partitionErrs ntfSubConnId subs' <$> withStoreBatch' c (\db -> map (updateSub db ntfServer ts nextCheckTs) nSubStatuses)
              (errs4, srvs') <- partitionErrs ntfSubConnId authSubs <$> withStoreBatch' c (\db -> map (recreateNtfSub db ntfServer ts) authSubs)
              mapM_ (getNtfSMPWorker True c) $ S.fromList (catMaybes srvs <> srvs')
              workerErrors c $ errs1 <> errs2' <> errs3 <> errs4
              pure ntfSubs'
            _ -> workerErrors c errs1 $> []
        _ -> do
          let errs = map (\sub -> (ntfSubConnId sub, INTERNAL "NSACheck - no active token")) ntfSubs
          workerErrors c errs
          pure []
      where
        splitSubs :: [NtfSubscription] -> ([(ConnId, AgentErrorType)], [NtfSubscription], [NtfSubscriptionId])
        splitSubs = foldr splitSub ([], [], [])
          where
            splitSub sub (errs, subs, subIds) = case sub of
              NtfSubscription {ntfSubId = Just subId} -> (errs, sub : subs, subId : subIds)
              _ -> ((ntfSubConnId sub, INTERNAL "NSACheck - no subscription ID") : errs, subs, subIds)
        updateSub :: DB.Connection -> NtfServer -> UTCTime -> UTCTime -> (NtfSubscription, NtfSubStatus) -> IO (Maybe SMPServer)
        updateSub db ntfServer ts nextCheckTs (sub, status)
          | ntfShouldSubscribe status =
              let sub' = sub {ntfSubStatus = NASCreated status}
               in Nothing <$ updateNtfSubscription db sub' (NSANtf NSACheck) nextCheckTs
          -- ntf server stopped subscribing to this queue
          | otherwise = Just <$> recreateNtfSub db ntfServer ts sub
        recreateNtfSub :: DB.Connection -> NtfServer -> UTCTime -> NtfSubscription -> IO SMPServer
        recreateNtfSub db ntfServer ts sub@NtfSubscription {smpServer} =
          let sub' = sub {ntfServer, ntfQueueId = Nothing, ntfSubId = Nothing, ntfSubStatus = NASNew}
           in smpServer <$ updateNtfSubscription db sub' (NSASMP NSASmpKey) ts
    incStatByUserId :: NtfServer -> (AgentNtfServerStats -> TVar Int) -> [NtfSubscription] -> AM' ()
    incStatByUserId ntfServer sel ss =
      forM_ (M.assocs userIdsCounts) $ \(userId, count) ->
        atomically $ incNtfServerStat' c userId ntfServer sel count
      where
        userIdsCounts = foldl' (\acc NtfSubscription {userId} -> M.insertWith (+) userId 1 acc) M.empty ss
    -- NSADelete and NSARotate are deprecated, but their processing is kept for legacy db records;
    -- These actions are not batched
    deleteSubs :: [NtfSubscription] -> AM' [NtfSubscription]
    deleteSubs ntfSubs = do
      retrySubs_ <- mapM (runCatching deleteSub) ntfSubs
      pure $ catMaybes retrySubs_
      where
        deleteSub :: NtfSubscription -> AM (Maybe NtfSubscription)
        deleteSub sub@NtfSubscription {smpServer} =
          deleteNtfSub sub $ do
            let sub' = sub {ntfSubId = Nothing, ntfSubStatus = NASOff}
            ts <- liftIO getCurrentTime
            withStore' c $ \db -> updateNtfSubscription db sub' (NSASMP NSASmpDelete) ts
            lift . void $ getNtfSMPWorker True c smpServer
    rotateSubs :: [NtfSubscription] -> AM' [NtfSubscription]
    rotateSubs ntfSubs = do
      retrySubs_ <- mapM (runCatching rotateSub) ntfSubs
      pure $ catMaybes retrySubs_
      where
        rotateSub :: NtfSubscription -> AM (Maybe NtfSubscription)
        rotateSub sub@NtfSubscription {connId} =
          deleteNtfSub sub $ do
            withStore' c $ \db -> deleteNtfSubscription db connId
            ns <- asks ntfSupervisor
            atomically $ writeTBQueue (ntfSubQ ns) (NSCCreate, [connId])
    runCatching :: (NtfSubscription -> AM (Maybe NtfSubscription)) -> NtfSubscription -> AM' (Maybe NtfSubscription)
    runCatching action sub@NtfSubscription {connId} =
      fromRight Nothing
        <$> runExceptT (action sub `catchAgentError` \e -> workerInternalError c connId (show e) $> Nothing)
    -- deleteNtfSub is only used in NSADelete and NSARotate, so also deprecated
    deleteNtfSub :: NtfSubscription -> AM () -> AM (Maybe NtfSubscription)
    deleteNtfSub sub@NtfSubscription {userId, ntfSubId} continue = case ntfSubId of
      Just nSubId ->
        lift getNtfToken >>= \case
          Just tkn@NtfToken {ntfServer} -> do
            atomically $ incNtfServerStat c userId ntfServer ntfDelAttempts
            tryAgentError (agentNtfDeleteSubscription c nSubId tkn) >>= \case
              Right _ -> do
                atomically $ incNtfServerStat c userId ntfServer ntfDeleted
                continue'
              Left e
                | temporaryOrHostError e -> pure $ Just sub -- don't continue, retry
                | otherwise -> continue'
          Nothing -> continue'
      _ -> continue'
      where
        continue' = continue $> Nothing -- continue without retry

runNtfSMPWorker :: AgentClient -> SMPServer -> Worker -> AM ()
runNtfSMPWorker c srv Worker {doWork} = forever $ do
  waitForWork doWork
  ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfSMPOperation
  where
    runNtfSMPOperation :: AM ()
    runNtfSMPOperation = do
      ntfBatchSize <- asks $ ntfBatchSize . config
      withWorkItems c doWork (\db -> getNextNtfSubSMPActions db srv ntfBatchSize) $ \nextSubs -> do
        logInfo $ "runNtfSMPWorker - length nextSubs = " <> tshow (length nextSubs)
        let (creates, deletes) = splitActions nextSubs
        retrySubActions c creates createNotifierKeys
        retrySubActions c deletes deleteNotifierKeys
    splitActions :: NonEmpty (NtfSubSMPAction, NtfSubscription) -> ([NtfSubscription], [NtfSubscription])
    splitActions = foldr addAction ([], [])
      where
        addAction (cmd, sub) (creates, deletes) = case cmd of
          NSASmpKey -> (sub : creates, deletes)
          NSASmpDelete -> (creates, sub : deletes)
    createNotifierKeys :: [NtfSubscription] -> AM' [NtfSubscription]
    createNotifierKeys ntfSubs =
      getNtfToken >>= \case
        Just NtfToken {ntfTknStatus = NTActive, ntfMode = NMInstant} -> do
          (errs1, subRqKeys) <- prepareQueueSmpKey ntfSubs
          rs <- enableQueuesNtfs c subRqKeys
          let (subRqKeys', errs2, successes) = splitResults rs
              ntfSubs' = map eqnrNtfSub subRqKeys'
              errs2' = map (first (qConnId . eqnrRq)) errs2
          ts <- liftIO getCurrentTime
          (errs3, srvs) <- partitionErrs (qConnId . eqnrRq . fst) successes <$> withStoreBatch' c (\db -> map (storeNtfSubCreds db ts) successes)
          mapM_ (getNtfNTFWorker True c) $ S.fromList srvs
          workerErrors c $ errs1 <> errs2' <> errs3
          pure ntfSubs'
        _ -> do
          let errs = map (\sub -> (ntfSubConnId sub, INTERNAL "NSASmpKey - no active token")) ntfSubs
          workerErrors c errs
          pure []
      where
        prepareQueueSmpKey :: [NtfSubscription] -> AM' ([(ConnId, AgentErrorType)], [EnableQueueNtfReq])
        prepareQueueSmpKey subs = do
          alg <- asks (rcvAuthAlg . config)
          g <- asks random
          partitionErrs ntfSubConnId subs <$> withStoreBatch c (\db -> map (getQueue db alg g) subs)
          where
            getQueue :: DB.Connection -> C.AuthAlg -> TVar ChaChaDRG -> NtfSubscription -> IO (Either AgentErrorType EnableQueueNtfReq)
            getQueue db (C.AuthAlg a) g sub = fmap (first storeError) $ runExceptT $ do
              rq <- ExceptT $ getPrimaryRcvQueue db (ntfSubConnId sub)
              authKeyPair <- atomically $ C.generateAuthKeyPair a g
              rcvNtfKeyPair <- atomically $ C.generateKeyPair g
              pure (EnableQueueNtfReq sub rq authKeyPair rcvNtfKeyPair)
        storeNtfSubCreds :: DB.Connection -> UTCTime -> (EnableQueueNtfReq, (SMP.NotifierId, SMP.RcvNtfPublicDhKey)) -> IO NtfServer
        storeNtfSubCreds db ts (EnableQueueNtfReq {eqnrNtfSub, eqnrAuthKeyPair = (ntfPublicKey, ntfPrivateKey), eqnrRcvKeyPair = (_, pk)}, (notifierId, srvPubDhKey)) = do
          let NtfSubscription {ntfServer} = eqnrNtfSub
              rcvNtfDhSecret = C.dh' srvPubDhKey pk
          setRcvQueueNtfCreds db (ntfSubConnId eqnrNtfSub) $ Just ClientNtfCreds {ntfPublicKey, ntfPrivateKey, notifierId, rcvNtfDhSecret}
          updateNtfSubscription db eqnrNtfSub {ntfQueueId = Just notifierId, ntfSubStatus = NASKey} (NSANtf NSACreate) ts
          pure ntfServer
    deleteNotifierKeys :: [NtfSubscription] -> AM' [NtfSubscription]
    deleteNotifierKeys ntfSubs = do
      (errs1, subRqs) <- partitionErrs ntfSubConnId ntfSubs <$> withStoreBatch c (\db -> map (resetCredsGetQueue db) ntfSubs)
      rs <- disableQueuesNtfs c subRqs
      let (subRqs', errs2, successes) = splitResults rs
          ntfSubs' = map fst subRqs'
          errs2' = map (first (qConnId . snd)) errs2
          disabledRqs = map (snd . fst) successes
      (errs3, _) <- partitionErrs qConnId disabledRqs <$> withStoreBatch' c (\db -> map (deleteSub db) disabledRqs)
      workerErrors c $ errs1 <> errs2' <> errs3
      pure ntfSubs'
      where
        resetCredsGetQueue :: DB.Connection -> NtfSubscription -> IO (Either AgentErrorType DisableQueueNtfReq)
        resetCredsGetQueue db sub@NtfSubscription {connId} = fmap (first storeError) $ runExceptT $ do
          liftIO $ setRcvQueueNtfCreds db connId Nothing
          rq <- ExceptT $ getPrimaryRcvQueue db connId
          pure (sub, rq)
        deleteSub :: DB.Connection -> RcvQueue -> IO ()
        deleteSub db rq = deleteNtfSubscription db (qConnId rq)

retrySubActions :: AgentClient -> [NtfSubscription] -> ([NtfSubscription] -> AM' [NtfSubscription]) -> AM ()
retrySubActions _ [] _ = pure ()
retrySubActions c subs action = do
  v <- newTVarIO subs
  ri <- asks $ reconnectInterval . config
  withRetryInterval ri $ \_ loop -> do
    liftIO $ waitWhileSuspended c
    liftIO $ waitForUserNetwork c
    subs' <- readTVarIO v
    retrySubs <- lift $ action subs'
    unless (null retrySubs) $ do
      atomically $ writeTVar v retrySubs
      retryNetworkLoop c loop

--                                                (temporary errs, other errs, successes)
splitResults :: [(a, Either AgentErrorType r)] -> ([a], [(a, AgentErrorType)], [(a, r)])
splitResults = foldr addRes ([], [], [])
  where
    addRes (a, r_) (as, errs, rs) = case r_ of
      Right r -> (as, errs, (a, r) : rs)
      Left e
        | temporaryOrHostError e -> (a : as, errs, rs)
        | otherwise -> (as, (a, e) : errs, rs)

rescheduleWork :: TMVar () -> UTCTime -> UTCTime -> AM' ()
rescheduleWork doWork ts actionTs = do
  void . atomically $ tryTakeTMVar doWork
  void . forkIO $ do
    liftIO $ threadDelay' $ diffToMicroseconds $ diffUTCTime actionTs ts
    atomically $ hasWorkToDo' doWork

retryNetworkLoop :: AgentClient -> AM () -> AM ()
retryNetworkLoop c loop = do
  atomically $ endAgentOperation c AONtfNetwork
  liftIO $ throwWhenInactive c
  atomically $ beginAgentOperation c AONtfNetwork
  loop

workerErrors :: AgentClient -> [(ConnId, AgentErrorType)] -> AM' ()
workerErrors c connErrs =
  unless (null connErrs) $ do
    void $ withStoreBatch' c (\db -> map (setNullNtfSubscriptionAction db . fst) connErrs)
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

sendNtfSubCommand :: NtfSupervisor -> (NtfSupervisorCommand, NonEmpty ConnId) -> IO ()
sendNtfSubCommand ns cmd =
  whenM (hasInstantNotifications ns) $ atomically $ writeTBQueue (ntfSubQ ns) cmd

hasInstantNotifications :: NtfSupervisor -> IO Bool
hasInstantNotifications ns = do
  tkn <- readTVarIO $ ntfTkn ns
  pure $ maybe False instantNotifications tkn

instantNotifications :: NtfToken -> Bool
instantNotifications NtfToken {ntfTknStatus = NTActive, ntfMode = NMInstant} = True
instantNotifications _ = False
{-# INLINE instantNotifications #-}

deleteToken :: AgentClient -> NtfToken -> AM ()
deleteToken c tkn@NtfToken {ntfServer, ntfTokenId, ntfPrivKey} = do
  setToDelete <- withStore' c $ \db -> do
    removeNtfToken db tkn
    case ntfTokenId of
      Just tknId -> addNtfTokenToDelete db ntfServer ntfPrivKey tknId $> True
      Nothing -> pure False
  ns <- asks ntfSupervisor
  atomically $ nsRemoveNtfToken ns
  when setToDelete $ void $ lift $ getNtfTknDelWorker True c ntfServer

runNtfTknDelWorker :: AgentClient -> NtfServer -> Worker -> AM ()
runNtfTknDelWorker c srv Worker {doWork} =
  forever $ do
    waitForWork doWork
    ExceptT $ agentOperationBracket c AONtfNetwork throwWhenInactive $ runExceptT runNtfOperation
  where
    runNtfOperation :: AM ()
    runNtfOperation =
      withWork c doWork (`getNextNtfTokenToDelete` srv) $
        \nextTknToDelete -> do
          logInfo $ "runNtfTknDelWorker, nextTknToDelete " <> tshow nextTknToDelete
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \_ loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            processTknToDelete nextTknToDelete `catchAgentError` retryTmpError loop nextTknToDelete
    retryTmpError :: AM () -> NtfTokenToDelete -> AgentErrorType -> AM ()
    retryTmpError loop (tknDbId, _, _) e = do
      logError $ "ntf tkn del error: " <> tshow e
      if temporaryOrHostError e
        then retryNetworkLoop c loop
        else do
          withStore' c $ \db -> deleteNtfTokenToDelete db tknDbId
          notifyInternalError' c (show e)
    processTknToDelete :: NtfTokenToDelete -> AM ()
    processTknToDelete (tknDbId, ntfPrivKey, tknId) = do
      agentNtfDeleteToken c NRMBackground srv ntfPrivKey tknId
      withStore' c $ \db -> deleteNtfTokenToDelete db tknDbId

closeNtfSupervisor :: NtfSupervisor -> IO ()
closeNtfSupervisor ns = do
  stopWorkers $ ntfWorkers ns
  stopWorkers $ ntfSMPWorkers ns
  stopWorkers $ ntfTknDelWorkers ns
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
