{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Client.Agent
  ( SMPClientAgent (..),
    SMPClientAgentConfig (..),
    SMPClientAgentEvent (..),
    OwnServer,
    defaultSMPClientAgentConfig,
    newSMPClientAgent,
    getSMPServerClient'',
    getConnectedSMPServerClient,
    closeSMPClientAgent,
    lookupSMPServerClient,
    isOwnServer,
    subscribeServiceNtfs,
    subscribeQueuesNtfs,
    activeClientSession',
    removeActiveSub,
    removeActiveSubs,
    removePendingSub,
    removePendingSubs,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Constraint (Dict (..))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
  ( BrokerMsg,
    ErrorType,
    NotifierId,
    NtfPrivateAuthKey,
    Party (..),
    PartyI,
    ProtocolServer (..),
    QueueId,
    SMPServer,
    ServiceSub (..),
    SParty (..),
    ServiceParty,
    serviceParty,
    partyServiceRole,
    queueIdsHash,
  )
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (catchAll_, ifM, safeDecodeUtf8, toChunks, tshow, whenM, ($>>=), (<$$>))
import System.Timeout (timeout)
import UnliftIO (async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type SMPClientVar = SessionVar (Either (SMPClientError, Maybe UTCTime) (OwnServer, SMPClient))

data SMPClientAgentEvent
  = CAConnected SMPServer (Maybe ServiceId)
  | CADisconnected SMPServer (NonEmpty QueueId)
  | CASubscribed SMPServer (Maybe ServiceId) (NonEmpty QueueId)
  | CASubError SMPServer (NonEmpty (QueueId, SMPClientError))
  | CAServiceDisconnected SMPServer ServiceSub
  | CAServiceSubscribed {subServer :: SMPServer, expected :: ServiceSub, subscribed :: ServiceSub}
  | CAServiceSubError SMPServer ServiceSub SMPClientError
  -- CAServiceUnavailable is used when service ID in pending subscription is different from the current service in connection.
  -- This will require resubscribing to all queues associated with this service ID individually, creating new associations.
  -- It may happen if, for example, SMP server deletes service information (e.g. via downgrade and upgrade)
  -- and assigns different service ID to the service certificate.
  | CAServiceUnavailable SMPServer ServiceSub

data SMPClientAgentConfig = SMPClientAgentConfig
  { smpCfg :: ProtocolClientConfig SMPVersion,
    reconnectInterval :: RetryInterval,
    persistErrorInterval :: NominalDiffTime,
    msgQSize :: Natural,
    agentQSize :: Natural,
    agentSubsBatchSize :: Int,
    ownServerDomains :: [ByteString]
  }

defaultSMPClientAgentConfig :: SMPClientAgentConfig
defaultSMPClientAgentConfig =
  SMPClientAgentConfig
    { smpCfg = defaultSMPClientConfig,
      reconnectInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * second
          },
      persistErrorInterval = 30, -- seconds
      msgQSize = 2048,
      agentQSize = 2048,
      agentSubsBatchSize = 1360,
      ownServerDomains = []
    }
  where
    second = 1000000

data SMPClientAgent p = SMPClientAgent
  { agentCfg :: SMPClientAgentConfig,
    agentParty :: SParty p,
    active :: TVar Bool,
    startedAt :: UTCTime,
    msgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg),
    agentQ :: TBQueue SMPClientAgentEvent,
    randomDrg :: TVar ChaChaDRG,
    smpClients :: TMap SMPServer SMPClientVar,
    smpSessions :: TMap SessionId (OwnServer, SMPClient),
    -- Only one service subscription can exist per server with this agent.
    -- With correctly functioning SMP server, queue and service subscriptions can't be
    -- active at the same time.
    activeServiceSubs :: TMap SMPServer (TVar (Maybe (ServiceSub, SessionId))),
    activeQueueSubs :: TMap SMPServer (TMap QueueId (SessionId, C.APrivateAuthKey)),
    -- Pending service subscriptions can co-exist with pending queue subscriptions
    -- on the same SMP server during subscriptions being transitioned from per-queue to service.
    pendingServiceSubs :: TMap SMPServer (TVar (Maybe ServiceSub)),
    pendingQueueSubs :: TMap SMPServer (TMap QueueId C.APrivateAuthKey),
    smpSubWorkers :: TMap SMPServer (SessionVar (Async ())),
    workerSeq :: TVar Int
  }

type OwnServer = Bool

newSMPClientAgent :: SParty p -> SMPClientAgentConfig -> TVar ChaChaDRG -> IO (SMPClientAgent p)
newSMPClientAgent agentParty agentCfg@SMPClientAgentConfig {msgQSize, agentQSize} randomDrg = do
  active <- newTVarIO True
  startedAt <- getCurrentTime
  msgQ <- newTBQueueIO msgQSize
  agentQ <- newTBQueueIO agentQSize
  smpClients <- TM.emptyIO
  smpSessions <- TM.emptyIO
  activeServiceSubs <- TM.emptyIO
  activeQueueSubs <- TM.emptyIO
  pendingServiceSubs <- TM.emptyIO
  pendingQueueSubs <- TM.emptyIO
  smpSubWorkers <- TM.emptyIO
  workerSeq <- newTVarIO 0
  pure
    SMPClientAgent
      { agentCfg,
        agentParty,
        active,
        startedAt,
        msgQ,
        agentQ,
        randomDrg,
        smpClients,
        smpSessions,
        activeServiceSubs,
        activeQueueSubs,
        pendingServiceSubs,
        pendingQueueSubs,
        smpSubWorkers,
        workerSeq
      }

-- | Get or create SMP client for SMPServer
getSMPServerClient' :: SMPClientAgent p -> SMPServer -> ExceptT SMPClientError IO SMPClient
getSMPServerClient' ca srv = snd <$> getSMPServerClient'' ca srv
{-# INLINE getSMPServerClient' #-}

getSMPServerClient'' :: SMPClientAgent p -> SMPServer -> ExceptT SMPClientError IO (OwnServer, SMPClient)
getSMPServerClient'' ca@SMPClientAgent {agentCfg, smpClients, smpSessions, workerSeq} srv = do
  ts <- liftIO getCurrentTime
  atomically (getClientVar ts) >>= either (ExceptT . newSMPClient) waitForSMPClient
  where
    getClientVar :: UTCTime -> STM (Either SMPClientVar SMPClientVar)
    getClientVar = getSessVar workerSeq srv smpClients

    waitForSMPClient :: SMPClientVar -> ExceptT SMPClientError IO (OwnServer, SMPClient)
    waitForSMPClient v = do
      let ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
      smpClient_ <- liftIO $ netTimeoutInt tcpConnectTimeout NRMBackground `timeout` atomically (readTMVar $ sessionVar v)
      case smpClient_ of
        Just (Right smpClient) -> pure smpClient
        Just (Left (e, ts_)) -> case ts_ of
          Nothing -> throwE e
          Just ts ->
            ifM
              ((ts <) <$> liftIO getCurrentTime)
              (atomically (removeSessVar v srv smpClients) >> getSMPServerClient'' ca srv)
              (throwE e)
        Nothing -> throwE PCEResponseTimeout

    newSMPClient :: SMPClientVar -> IO (Either SMPClientError (OwnServer, SMPClient))
    newSMPClient v = do
      r <- connectClient ca srv v `E.catch` (pure . Left . PCEIOError)
      case r of
        Right smp -> do
          logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
          let !owned = isOwnServer ca srv
              !c = (owned, smp)
          atomically $ do
            putTMVar (sessionVar v) (Right c)
            TM.insert (sessionId $ thParams smp) c smpSessions
          let serviceId_ = (\THClientService {serviceId} -> serviceId) <$> smpClientService smp
          notify ca $ CAConnected srv serviceId_
          pure $ Right c
        Left e -> do
          let ei = persistErrorInterval agentCfg
          if ei == 0
            then atomically $ do
              putTMVar (sessionVar v) (Left (e, Nothing))
              removeSessVar v srv smpClients
            else do
              ts <- addUTCTime ei <$> liftIO getCurrentTime
              atomically $ putTMVar (sessionVar v) (Left (e, Just ts))
          reconnectClient ca srv
          pure $ Left e

isOwnServer :: SMPClientAgent p -> SMPServer -> OwnServer
isOwnServer SMPClientAgent {agentCfg} ProtocolServer {host} =
  let srv = strEncode $ L.head host
   in any (\s -> s == srv || B.cons '.' s `B.isSuffixOf` srv) (ownServerDomains agentCfg)

-- | Run an SMP client for SMPClientVar
connectClient :: SMPClientAgent p -> SMPServer -> SMPClientVar -> IO (Either SMPClientError SMPClient)
connectClient ca@SMPClientAgent {agentCfg, smpClients, smpSessions, msgQ, randomDrg, startedAt} srv v =
  getProtocolClient randomDrg NRMBackground (1, srv, Nothing) (smpCfg agentCfg) [] (Just msgQ) startedAt clientDisconnected
  where
    clientDisconnected :: SMPClient -> IO ()
    clientDisconnected smp = do
      removeClientAndSubs smp >>= serverDown
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: SMPClient -> IO (Maybe ServiceSub, Maybe (Map QueueId C.APrivateAuthKey))
    removeClientAndSubs smp = do
      -- Looking up subscription vars outside of STM transaction to reduce re-evaluation.
      -- It is possible because these vars are never removed, they are only added.
      sVar_ <- TM.lookupIO srv $ activeServiceSubs ca
      qVar_ <- TM.lookupIO srv $ activeQueueSubs ca
      atomically $ do
        TM.delete sessId smpSessions
        removeSessVar v srv smpClients
        sSub <- pure sVar_ $>>= updateServiceSub
        qSubs <- pure qVar_ $>>= updateQueueSubs
        pure (sSub, qSubs)
      where
        sessId = sessionId $ thParams smp
        updateServiceSub sVar = do -- (sub, sessId')
          -- We don't change active subscription in case session ID is different from disconnected client
          serviceSub_ <- stateTVar sVar $ \case
            Just (serviceSub, sessId') | sessId == sessId' -> (Just serviceSub, Nothing)
            s -> (Nothing, s)
          -- We don't reset pending subscription to Nothing here to avoid any race conditions
          -- with subsequent client sessions that might have set pending already.
          when (isJust serviceSub_) $ setPendingServiceSub ca srv serviceSub_
          pure serviceSub_
        updateQueueSubs qVar = do
          -- removing subscriptions that have matching sessionId to disconnected client
          -- and keep the other ones (they can be made by the new client)
          subs <- M.map snd <$> stateTVar qVar (M.partition ((sessId ==) . fst))
          if M.null subs
            then pure Nothing
            else Just subs <$ addSubs_ (pendingQueueSubs ca) srv subs

    serverDown :: (Maybe ServiceSub, Maybe (Map QueueId C.APrivateAuthKey)) -> IO ()
    serverDown (sSub, qSubs) = do
      mapM_ (notify ca . CAServiceDisconnected srv) sSub
      let qIds = L.nonEmpty . M.keys =<< qSubs
      mapM_ (notify ca . CADisconnected srv) qIds
      when (isJust sSub || isJust qIds) $ reconnectClient ca srv

-- | Spawn reconnect worker if needed
reconnectClient :: SMPClientAgent p -> SMPServer -> IO ()
reconnectClient ca@SMPClientAgent {active, agentCfg, smpSubWorkers, workerSeq} srv = do
  ts <- getCurrentTime
  whenM (readTVarIO active) $ atomically (getWorkerVar ts) >>= mapM_ (either newSubWorker (\_ -> pure ()))
  where
    getWorkerVar ts =
      ifM
        (noPending <$> getPending TM.lookup readTVar)
        (pure Nothing) -- prevent race with cleanup and adding pending queues in another call
        (Just <$> getSessVar workerSeq srv smpSubWorkers ts)
    newSubWorker :: SessionVar (Async ()) -> IO ()
    newSubWorker v = do
      a <- async $ void (E.tryAny runSubWorker) >> atomically (cleanup v)
      atomically $ putTMVar (sessionVar v) a
    runSubWorker =
      withRetryInterval (reconnectInterval agentCfg) $ \_ loop -> do
        subs <- getPending TM.lookupIO readTVarIO
        unless (noPending subs) $ whenM (readTVarIO active) $ do
          void $ netTimeoutInt tcpConnectTimeout NRMBackground `timeout` runExceptT (reconnectSMPClient ca srv subs)
          loop
    ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
    noPending (sSub, qSubs) = isNothing sSub && maybe True M.null qSubs
    getPending :: Monad m => (forall a. SMPServer -> TMap SMPServer a -> m (Maybe a)) -> (forall a. TVar a -> m a) -> m (Maybe ServiceSub, Maybe (Map QueueId C.APrivateAuthKey))
    getPending lkup rd = do
      sSub <- lkup srv (pendingServiceSubs ca) $>>= rd
      qSubs <- lkup srv (pendingQueueSubs ca) >>= mapM rd
      pure (sSub, qSubs)
    cleanup :: SessionVar (Async ()) -> STM ()
    cleanup v = do
      -- Here we wait until TMVar is not empty to prevent worker cleanup happening before worker is added to TMVar.
      -- Not waiting may result in terminated worker remaining in the map.
      whenM (isEmptyTMVar $ sessionVar v) retry
      removeSessVar v srv smpSubWorkers

reconnectSMPClient :: forall p. SMPClientAgent p -> SMPServer -> (Maybe ServiceSub, Maybe (Map QueueId C.APrivateAuthKey)) -> ExceptT SMPClientError IO ()
reconnectSMPClient ca@SMPClientAgent {agentCfg, agentParty} srv (sSub_, qSubs_) =
  withSMP ca srv $ \smp -> liftIO $ case serviceParty agentParty of
    Just Dict -> resubscribe smp
    Nothing -> pure ()
  where
    resubscribe :: (PartyI p, ServiceParty p) => SMPClient -> IO ()
    resubscribe smp = do
      mapM_ (smpSubscribeService ca smp srv) sSub_
      forM_ qSubs_ $ \qSubs -> do
        currSubs_ <- mapM readTVarIO =<< TM.lookupIO srv (activeQueueSubs ca)
        let qSubs' :: [(QueueId, C.APrivateAuthKey)] =
              maybe id (\currSubs -> filter ((`M.notMember` currSubs) . fst)) currSubs_ $ M.assocs qSubs
        mapM_ (smpSubscribeQueues @p ca smp srv) $ toChunks (agentSubsBatchSize agentCfg) qSubs'

notify :: MonadIO m => SMPClientAgent p -> SMPClientAgentEvent -> m ()
notify ca evt = atomically $ writeTBQueue (agentQ ca) evt
{-# INLINE notify #-}

-- Returns already connected client for proxying messages or Nothing if client is absent, not connected yet or stores expired error.
-- If Nothing is return proxy will spawn a new thread to wait or to create another client connection to destination relay.
getConnectedSMPServerClient :: SMPClientAgent p -> SMPServer -> IO (Maybe (Either SMPClientError (OwnServer, SMPClient)))
getConnectedSMPServerClient SMPClientAgent {smpClients} srv =
  atomically (TM.lookup srv smpClients $>>= \v -> (v,) <$$> tryReadTMVar (sessionVar v)) -- Nothing: client is absent or not connected yet
    $>>= \case
      (_, Right r) -> pure $ Just $ Right r
      (v, Left (e, ts_)) ->
        pure ts_ $>>= \ts ->
          -- proxy will create a new connection if ts_ is Nothing
          ifM
            ((ts <) <$> liftIO getCurrentTime) -- error persistence interval period expired?
            (Nothing <$ atomically (removeSessVar v srv smpClients)) -- proxy will create a new connection
            (pure $ Just $ Left e) -- not expired, returning error

lookupSMPServerClient :: SMPClientAgent p -> SessionId -> IO (Maybe (OwnServer, SMPClient))
lookupSMPServerClient SMPClientAgent {smpSessions} sessId = TM.lookupIO sessId smpSessions

closeSMPClientAgent :: SMPClientAgent p -> IO ()
closeSMPClientAgent c = do
  atomically $ writeTVar (active c) False
  closeSMPServerClients c
  atomically (swapTVar (smpSubWorkers c) M.empty) >>= mapM_ cancelReconnect
  where
    cancelReconnect :: SessionVar (Async ()) -> IO ()
    cancelReconnect v = void . forkIO $ atomically (readTMVar $ sessionVar v) >>= uninterruptibleCancel

closeSMPServerClients :: SMPClientAgent p -> IO ()
closeSMPServerClients c = atomically (smpClients c `swapTVar` M.empty) >>= mapM_ (forkIO . closeClient)
  where
    closeClient v =
      atomically (readTMVar $ sessionVar v) >>= \case
        Right (_, smp) -> closeProtocolClient smp `catchAll_` pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withSMP :: SMPClientAgent p -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO a
withSMP ca srv action = (getSMPServerClient' ca srv >>= action) `catchE` logSMPError
  where
    logSMPError :: SMPClientError -> ExceptT SMPClientError IO a
    logSMPError e = do
      logInfo $ "SMP error (" <> safeDecodeUtf8 (strEncode srv) <> "): " <> tshow e
      throwE e

subscribeQueuesNtfs :: SMPClientAgent 'NotifierService -> SMPServer -> NonEmpty (NotifierId, NtfPrivateAuthKey) -> IO ()
subscribeQueuesNtfs = subscribeQueues_
{-# INLINE subscribeQueuesNtfs #-}

subscribeQueues_ :: ServiceParty p => SMPClientAgent p -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO ()
subscribeQueues_ ca srv subs = do
  atomically $ addPendingSubs ca srv $ L.toList subs
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Right smp -> smpSubscribeQueues ca smp srv subs
    Left _ -> pure () -- no call to reconnectClient - failing getSMPServerClient' does that

smpSubscribeQueues :: ServiceParty p => SMPClientAgent p -> SMPClient -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO ()
smpSubscribeQueues ca smp srv subs = do
  rs <- case agentParty ca of
    SRecipientService -> subscribeSMPQueues smp subs
    SNotifierService -> subscribeSMPQueuesNtfs smp subs
  rs' <-
    atomically $
      ifM
        (activeClientSession ca smp srv)
        (Just <$> processSubscriptions rs)
        (pure Nothing)
  case rs' of
    Just (tempErrs, finalErrs, (qOks, sQs), _) -> do
      notify_ (`CASubscribed` Nothing) $ map fst qOks
      when (isJust smpServiceId) $ notify_ (`CASubscribed` smpServiceId) sQs
      notify_ CASubError finalErrs
      when tempErrs $ reconnectClient ca srv
    Nothing -> reconnectClient ca srv
  where
    processSubscriptions :: NonEmpty (Either SMPClientError (Maybe ServiceId)) -> STM (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId])
    processSubscriptions rs = do
      pending <- maybe (pure M.empty) readTVar =<< TM.lookup srv (pendingQueueSubs ca)
      let acc@(_, _, (qOks, sQs), notPending) = foldr (groupSub pending) (False, [], ([], []), []) (L.zip subs rs)
      unless (null qOks) $ addActiveSubs ca srv qOks
      unless (null sQs) $ forM_ smpServiceId $ \serviceId ->
        updateActiveServiceSub ca srv (ServiceSub serviceId (fromIntegral $ length sQs) (queueIdsHash sQs), sessId)
      unless (null notPending) $ removePendingSubs ca srv notPending
      pure acc
    sessId = sessionId $ thParams smp
    smpServiceId = (\THClientService {serviceId} -> serviceId) <$> smpClientService smp
    groupSub ::
      Map QueueId C.APrivateAuthKey ->
      ((QueueId, C.APrivateAuthKey), Either SMPClientError (Maybe ServiceId)) ->
      (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId]) ->
      (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId])
    groupSub pending ((qId, pk), r) acc@(!tempErrs, finalErrs, oks@(qOks, sQs), notPending) = case r of
      Right serviceId_
        | M.member qId pending ->
            let oks' = case (smpServiceId, serviceId_) of
                  (Just sId, Just sId') | sId == sId' -> (qOks, qId : sQs)
                  _ -> ((qId, (sessId, pk)) : qOks, sQs)
             in (tempErrs, finalErrs, oks', qId : notPending)
        | otherwise -> acc
      Left e
        | temporaryClientError e -> (True, finalErrs, oks, notPending)
        | otherwise -> (tempErrs, (qId, e) : finalErrs, oks, qId : notPending)
    notify_ :: (SMPServer -> NonEmpty a -> SMPClientAgentEvent) -> [a] -> IO ()
    notify_ evt qs = mapM_ (notify ca . evt srv) $ L.nonEmpty qs

subscribeServiceNtfs :: SMPClientAgent 'NotifierService -> SMPServer -> ServiceSub -> IO ()
subscribeServiceNtfs = subscribeService_
{-# INLINE subscribeServiceNtfs #-}

subscribeService_ :: (PartyI p, ServiceParty p) => SMPClientAgent p -> SMPServer -> ServiceSub -> IO ()
subscribeService_ ca srv serviceSub = do
  atomically $ setPendingServiceSub ca srv $ Just serviceSub
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Right smp -> smpSubscribeService ca smp srv serviceSub
    Left _ -> pure () -- no call to reconnectClient - failing getSMPServerClient' does that

smpSubscribeService :: (PartyI p, ServiceParty p) => SMPClientAgent p -> SMPClient -> SMPServer -> ServiceSub -> IO ()
smpSubscribeService ca smp srv serviceSub@(ServiceSub serviceId n idsHash) = case smpClientService smp of
  Just service | serviceAvailable service -> subscribe
  _ -> notifyUnavailable
  where
    subscribe = do
      r <- runExceptT $ subscribeService smp (agentParty ca) n idsHash
      ok <-
        atomically $
          ifM
            (activeClientSession ca smp srv)
            (True <$ processSubscription r)
            (pure False)
      if ok
        then case r of
          Right serviceSub' -> notify ca $ CAServiceSubscribed srv serviceSub serviceSub'
          Left e
            | smpClientServiceError e -> notifyUnavailable
            | temporaryClientError e -> reconnectClient ca srv
            | otherwise -> notify ca $ CAServiceSubError srv serviceSub e
        else reconnectClient ca srv
    processSubscription = mapM_ $ \serviceSub' -> do -- TODO [certs rcv] validate hash here?
      setActiveServiceSub ca srv $ Just (serviceSub', sessId)
      setPendingServiceSub ca srv Nothing
    serviceAvailable THClientService {serviceRole, serviceId = serviceId'} =
      serviceId == serviceId' && partyServiceRole (agentParty ca) == serviceRole
    notifyUnavailable = do
      atomically $ setPendingServiceSub ca srv Nothing
      notify ca $ CAServiceUnavailable srv serviceSub -- this will resubscribe all queues directly
    sessId = sessionId $ thParams smp

activeClientSession' :: SMPClientAgent p -> SessionId -> SMPServer -> STM Bool
activeClientSession' ca sessId srv = sameSess <$> tryReadSessVar srv (smpClients ca)
  where
    sameSess = \case
      Just (Right (_, smp')) -> sessId == sessionId (thParams smp')
      _ -> False

activeClientSession :: SMPClientAgent p -> SMPClient -> SMPServer -> STM Bool
activeClientSession ca = activeClientSession' ca . sessionId . thParams

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

addActiveSubs :: SMPClientAgent p -> SMPServer -> [(QueueId, (SessionId, C.APrivateAuthKey))] -> STM ()
addActiveSubs = addSubsList_ . activeQueueSubs
{-# INLINE addActiveSubs #-}

addPendingSubs :: SMPClientAgent p -> SMPServer -> [(QueueId, C.APrivateAuthKey)] -> STM ()
addPendingSubs = addSubsList_ . pendingQueueSubs
{-# INLINE addPendingSubs #-}

addSubsList_ :: TMap SMPServer (TMap QueueId s) -> SMPServer -> [(QueueId, s)] -> STM ()
addSubsList_ subs srv ss = addSubs_ subs srv $ M.fromList ss
  -- where
  --   ss' = M.fromList $ map (first (party,)) ss

addSubs_ :: TMap SMPServer (TMap QueueId s) -> SMPServer -> Map QueueId s -> STM ()
addSubs_ subs srv ss =
  TM.lookup srv subs >>= \case
    Just m -> TM.union ss m
    _ -> TM.insertM srv (newTVar ss) subs

setActiveServiceSub :: SMPClientAgent p -> SMPServer -> Maybe (ServiceSub, SessionId) -> STM ()
setActiveServiceSub = setServiceSub_ activeServiceSubs
{-# INLINE setActiveServiceSub #-}

setPendingServiceSub :: SMPClientAgent p -> SMPServer -> Maybe ServiceSub -> STM ()
setPendingServiceSub = setServiceSub_ pendingServiceSubs
{-# INLINE setPendingServiceSub #-}

setServiceSub_ ::
  (SMPClientAgent p -> TMap SMPServer (TVar (Maybe sub))) ->
  SMPClientAgent p ->
  SMPServer ->
  Maybe sub ->
  STM ()
setServiceSub_ subsSel ca srv sub =
  TM.lookup srv (subsSel ca) >>= \case
    Just v -> writeTVar v sub
    Nothing -> TM.insertM srv (newTVar sub) (subsSel ca)

updateActiveServiceSub :: SMPClientAgent p -> SMPServer -> (ServiceSub, SessionId) -> STM ()
updateActiveServiceSub ca srv sub@(ServiceSub serviceId' n' idsHash', sessId') =
  TM.lookup srv (activeServiceSubs ca) >>= \case
    Just v -> modifyTVar' v $ \case
      Just (ServiceSub serviceId n idsHash, sessId) | serviceId == serviceId' && sessId == sessId' ->
        Just (ServiceSub serviceId (n + n') (idsHash <> idsHash'), sessId)
      _ -> Just sub
    Nothing -> TM.insertM srv (newTVar $ Just sub) (activeServiceSubs ca)

removeActiveSub :: SMPClientAgent p -> SMPServer -> QueueId -> STM ()
removeActiveSub = removeSub_ . activeQueueSubs
{-# INLINE removeActiveSub #-}

removePendingSub :: SMPClientAgent p -> SMPServer -> QueueId -> STM ()
removePendingSub = removeSub_ . pendingQueueSubs
{-# INLINE removePendingSub #-}

removeSub_ :: TMap SMPServer (TMap QueueId s) -> SMPServer -> QueueId -> STM ()
removeSub_ subs srv s = TM.lookup srv subs >>= mapM_ (TM.delete s)

removeActiveSubs :: SMPClientAgent p -> SMPServer -> [QueueId] -> STM ()
removeActiveSubs = removeSubs_ . activeQueueSubs
{-# INLINE removeActiveSubs #-}

removePendingSubs :: SMPClientAgent p -> SMPServer -> [QueueId] -> STM ()
removePendingSubs = removeSubs_ . pendingQueueSubs
{-# INLINE removePendingSubs #-}

removeSubs_ :: TMap SMPServer (TMap QueueId s) -> SMPServer -> [QueueId] -> STM ()
removeSubs_ subs srv qs = TM.lookup srv subs >>= mapM_ (`modifyTVar'` (`M.withoutKeys` S.fromList qs))
