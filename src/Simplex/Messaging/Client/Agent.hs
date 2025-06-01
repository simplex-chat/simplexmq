{-# LANGUAGE BangPatterns #-}
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

module Simplex.Messaging.Client.Agent where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Tuple (swap)
import Data.Word (Word32)
import Numeric.Natural
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BrokerMsg, ErrorType, NotifierId, NtfPrivateAuthKey, ProtocolServer (..), QueueId, RcvPrivateAuthKey, RecipientId, SMPServer)
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
  = CAConnected SMPServer (Maybe (SMPSubParty, ServiceId))
  | CADisconnected SMPServer (Set SMPSub)
  | CASubscribed SMPServer SMPSubParty (NonEmpty QueueId)
  | CASubscribedService ServiceId SMPServer SMPSubParty (NonEmpty QueueId)
  | CASubError SMPServer SMPSubParty (NonEmpty (QueueId, SMPClientError))
  | CAServiceDisconnected SMPServer (SMPSubParty, ServiceId)
  | CAServiceSubscribed SMPServer (SMPSubParty, ServiceId) Word32
  | CAServiceSubError SMPServer (SMPSubParty, ServiceId) SMPClientError
  -- CAServiceUnavailable is used when service ID in pending subscription is different from the current service in connection.
  -- This will require resubscribing to all queues associated with this service ID individually, creating new associations.
  -- It may happen if, for example, SMP server deletes service information (e.g. via downgrade and§ upgrade)
  -- and assigns different service ID to the service certificate.
  | CAServiceUnavailable SMPServer (SMPSubParty, ServiceId)

data SMPSubParty = SPRecipient | SPNotifier
  deriving (Eq, Ord, Show)

type SMPSub = (SMPSubParty, EntityId)

-- type SMPServerSub = (SMPServer, SMPSub)

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

data SMPClientAgent = SMPClientAgent
  { agentCfg :: SMPClientAgentConfig,
    active :: TVar Bool,
    startedAt :: UTCTime,
    msgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg),
    agentQ :: TBQueue SMPClientAgentEvent,
    randomDrg :: TVar ChaChaDRG,
    smpClients :: TMap SMPServer SMPClientVar,
    smpSessions :: TMap SessionId (OwnServer, SMPClient),
    -- Only one service subscription can exist per server with this agent.
    -- With correctly functioning SMP server, queue and service subscriptions cab't be
    -- active at the same time.
    activeServiceSubs :: TMap SMPServer (TVar (Maybe ((SMPSubParty, ServiceId), SessionId))),
    activeQueueSubs :: TMap SMPServer (TMap SMPSub (SessionId, C.APrivateAuthKey)),
    -- Pending service subscriptions can co-exist with pending queue subscriptions
    -- on the same SMP server during subscriptions being transitioned from per-queue to service.
    pendingServiceSubs :: TMap SMPServer (TVar (Maybe (SMPSubParty, ServiceId))),
    pendingQueueSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    smpSubWorkers :: TMap SMPServer (SessionVar (Async ())),
    workerSeq :: TVar Int
  }

type OwnServer = Bool

newSMPClientAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> IO SMPClientAgent
newSMPClientAgent agentCfg@SMPClientAgentConfig {msgQSize, agentQSize} randomDrg = do
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
getSMPServerClient' :: SMPClientAgent -> SMPServer -> ExceptT SMPClientError IO SMPClient
getSMPServerClient' ca srv = snd <$> getSMPServerClient'' ca srv
{-# INLINE getSMPServerClient' #-}

getSMPServerClient'' :: SMPClientAgent -> SMPServer -> ExceptT SMPClientError IO (OwnServer, SMPClient)
getSMPServerClient'' ca@SMPClientAgent {agentCfg, smpClients, smpSessions, workerSeq} srv = do
  ts <- liftIO getCurrentTime
  atomically (getClientVar ts) >>= either (ExceptT . newSMPClient) waitForSMPClient
  where
    getClientVar :: UTCTime -> STM (Either SMPClientVar SMPClientVar)
    getClientVar = getSessVar workerSeq srv smpClients

    waitForSMPClient :: SMPClientVar -> ExceptT SMPClientError IO (OwnServer, SMPClient)
    waitForSMPClient v = do
      let ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
      smpClient_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar v)
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
          notify ca $ CAConnected srv Nothing -- TODO [certs] add service role and ID here
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

isOwnServer :: SMPClientAgent -> SMPServer -> OwnServer
isOwnServer SMPClientAgent {agentCfg} ProtocolServer {host} =
  let srv = strEncode $ L.head host
   in any (\s -> s == srv || B.cons '.' s `B.isSuffixOf` srv) (ownServerDomains agentCfg)

-- | Run an SMP client for SMPClientVar
connectClient :: SMPClientAgent -> SMPServer -> SMPClientVar -> IO (Either SMPClientError SMPClient)
connectClient ca@SMPClientAgent {agentCfg, smpClients, smpSessions, msgQ, randomDrg, startedAt} srv v =
  getProtocolClient randomDrg (1, srv, Nothing) (smpCfg agentCfg) [] (Just msgQ) startedAt clientDisconnected
  where
    clientDisconnected :: SMPClient -> IO ()
    clientDisconnected smp = do
      removeClientAndSubs smp >>= serverDown
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: SMPClient -> IO (Maybe (SMPSubParty, ServiceId), Maybe (Map SMPSub C.APrivateAuthKey))
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
          sub <- stateTVar sVar $ \case
            Just (sub, sessId') | sessId == sessId' -> (Just sub, Nothing)
            s -> (Nothing, s)
          -- We don't reset pending subscription to Nothing here to avoid any race conditions
          -- with subsequent client sessions that might have set pending already.
          when (isJust sub) $ setPendingServiceSub ca srv sub
          pure sub
        updateQueueSubs qVar = do
          -- removing subscriptions that have matching sessionId to disconnected client
          -- and keep the other ones (they can be made by the new client)
          sub <- M.map snd <$> stateTVar qVar (M.partition ((sessId ==) . fst))
          if M.null sub
            then pure Nothing
            else Just sub <$ addSubs_ (pendingQueueSubs ca) srv sub

    serverDown :: (Maybe (SMPSubParty, ServiceId), Maybe (Map SMPSub C.APrivateAuthKey)) -> IO ()
    serverDown (sSub, qSubs) = do
      mapM_ (notify ca . CAServiceDisconnected srv) sSub
      mapM_ (notify ca . CADisconnected srv . M.keysSet) qSubs
      when (isJust sSub || isJust qSubs) $ reconnectClient ca srv

-- | Spawn reconnect worker if needed
reconnectClient :: SMPClientAgent -> SMPServer -> IO ()
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
          void $ tcpConnectTimeout `timeout` runExceptT (reconnectSMPClient ca srv subs)
          loop
    ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
    noPending (sSub, qSubs) = isNothing sSub && maybe True M.null qSubs
    getPending :: Monad m => (forall a. SMPServer -> TMap SMPServer a -> m (Maybe a)) -> (forall a. TVar a -> m a) -> m (Maybe (SMPSubParty, ServiceId), Maybe (Map SMPSub C.APrivateAuthKey))
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

reconnectSMPClient :: SMPClientAgent -> SMPServer -> (Maybe (SMPSubParty, ServiceId), Maybe (Map SMPSub C.APrivateAuthKey)) -> ExceptT SMPClientError IO ()
reconnectSMPClient ca@SMPClientAgent {agentCfg} srv (sSub_, qSubs_) =
  withSMP ca srv $ \smp -> liftIO $ do
    mapM_ (smpSubscribeService ca smp srv) sSub_
    forM_ qSubs_ $ \qSubs -> do
      currSubs <- maybe (pure M.empty) readTVarIO =<< TM.lookupIO srv (activeQueueSubs ca)
      let (nSubs, rSubs) = foldr (groupSub currSubs) ([], []) $ M.assocs qSubs
      subscribe_ smp SPNotifier nSubs
      subscribe_ smp SPRecipient rSubs
  where
    groupSub :: Map SMPSub (SessionId, C.APrivateAuthKey) -> (SMPSub, C.APrivateAuthKey) -> ([(QueueId, C.APrivateAuthKey)], [(QueueId, C.APrivateAuthKey)]) -> ([(QueueId, C.APrivateAuthKey)], [(QueueId, C.APrivateAuthKey)])
    groupSub currSubs (s@(party, qId), k) acc@(nSubs, rSubs)
      | M.member s currSubs = acc
      | otherwise = case party of
          SPNotifier -> (s' : nSubs, rSubs)
          SPRecipient -> (nSubs, s' : rSubs)
      where
        s' = (qId, k)
    subscribe_ :: SMPClient -> SMPSubParty -> [(QueueId, C.APrivateAuthKey)] -> IO ()
    subscribe_ smp party = mapM_ (smpSubscribeQueues party ca smp srv) . toChunks (agentSubsBatchSize agentCfg)

notify :: MonadIO m => SMPClientAgent -> SMPClientAgentEvent -> m ()
notify ca evt = atomically $ writeTBQueue (agentQ ca) evt
{-# INLINE notify #-}

-- Returns already connected client for proxying messages or Nothing if client is absent, not connected yet or stores expired error.
-- If Nothing is return proxy will spawn a new thread to wait or to create another client connection to destination relay.
getConnectedSMPServerClient :: SMPClientAgent -> SMPServer -> IO (Maybe (Either SMPClientError (OwnServer, SMPClient)))
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

lookupSMPServerClient :: SMPClientAgent -> SessionId -> IO (Maybe (OwnServer, SMPClient))
lookupSMPServerClient SMPClientAgent {smpSessions} sessId = TM.lookupIO sessId smpSessions

closeSMPClientAgent :: SMPClientAgent -> IO ()
closeSMPClientAgent c = do
  atomically $ writeTVar (active c) False
  closeSMPServerClients c
  atomically (swapTVar (smpSubWorkers c) M.empty) >>= mapM_ cancelReconnect
  where
    cancelReconnect :: SessionVar (Async ()) -> IO ()
    cancelReconnect v = void . forkIO $ atomically (readTMVar $ sessionVar v) >>= uninterruptibleCancel

closeSMPServerClients :: SMPClientAgent -> IO ()
closeSMPServerClients c = atomically (smpClients c `swapTVar` M.empty) >>= mapM_ (forkIO . closeClient)
  where
    closeClient v =
      atomically (readTMVar $ sessionVar v) >>= \case
        Right (_, smp) -> closeProtocolClient smp `catchAll_` pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withSMP :: SMPClientAgent -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> ExceptT SMPClientError IO a
withSMP ca srv action = (getSMPServerClient' ca srv >>= action) `catchE` logSMPError
  where
    logSMPError :: SMPClientError -> ExceptT SMPClientError IO a
    logSMPError e = do
      logInfo $ "SMP error (" <> safeDecodeUtf8 (strEncode $ host srv) <> "): " <> tshow e
      throwE e

subscribeQueuesSMP :: SMPClientAgent -> SMPServer -> NonEmpty (RecipientId, RcvPrivateAuthKey) -> IO ()
subscribeQueuesSMP = subscribeQueues_ SPRecipient

subscribeQueuesNtfs :: SMPClientAgent -> SMPServer -> NonEmpty (NotifierId, NtfPrivateAuthKey) -> IO ()
subscribeQueuesNtfs = subscribeQueues_ SPNotifier

subscribeQueues_ :: SMPSubParty -> SMPClientAgent -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO ()
subscribeQueues_ party ca srv subs = do
  atomically $ addPendingSubs ca srv party $ L.toList subs
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Right smp -> smpSubscribeQueues party ca smp srv subs
    Left _ -> pure () -- no call to reconnectClient - failing getSMPServerClient' does that

smpSubscribeQueues :: SMPSubParty -> SMPClientAgent -> SMPClient -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO ()
smpSubscribeQueues party ca smp srv subs = do
  rs <- subscribe smp $ L.map swap subs
  rs' <-
    atomically $
      ifM
        (activeClientSession ca smp srv)
        (Just <$> processSubscriptions rs)
        (pure Nothing)
  case rs' of
    Just (tempErrs, finalErrs, (qOks, sQs), _) -> do
      notify_ CASubscribed $ map fst qOks
      forM_ smpServiceId $ \serviceId ->
        notify_ (CASubscribedService serviceId) sQs
      notify_ CASubError finalErrs
      when tempErrs $ reconnectClient ca srv
    Nothing -> reconnectClient ca srv
  where
    processSubscriptions :: NonEmpty (Either SMPClientError (Maybe ServiceId)) -> STM (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId])
    processSubscriptions rs = do
      pending <- maybe (pure M.empty) readTVar =<< TM.lookup srv (pendingQueueSubs ca)
      let acc@(_, _, (qOks, sQs), notPending) = foldr (groupSub pending) (False, [], ([], []), []) (L.zip subs rs)
      unless (null qOks) $ addSubscriptions ca srv party qOks
      unless (null sQs) $ forM_ smpServiceId $ \serviceId ->
        setActiveServiceSub ca srv $ Just ((party, serviceId), sessId)
      unless (null notPending) $ removePendingSubs ca srv party notPending
      pure acc
    sessId = sessionId $ thParams smp
    smpServiceId = (\THClientService {serviceId} -> serviceId) <$> smpClientService smp
    groupSub ::
      Map SMPSub C.APrivateAuthKey ->
      ((QueueId, C.APrivateAuthKey), Either SMPClientError (Maybe ServiceId)) ->
      (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId]) ->
      (Bool, [(QueueId, SMPClientError)], ([(QueueId, (SessionId, C.APrivateAuthKey))], [QueueId]), [QueueId])
    groupSub pending ((qId, pk), r) acc@(!tempErrs, finalErrs, oks@(qOks, sQs), notPending) = case r of
      Right serviceId_
        | M.member (party, qId) pending ->
            let oks' = case (smpServiceId, serviceId_) of
                  (Just sId, Just sId') | sId == sId' -> (qOks, qId : sQs)
                  _ -> ((qId, (sessId, pk)) : qOks, sQs)
             in (tempErrs, finalErrs, oks', qId : notPending)
        | otherwise -> acc
      Left e
        | temporaryClientError e -> (True, finalErrs, oks, notPending)
        | otherwise -> (tempErrs, (qId, e) : finalErrs, oks, qId : notPending)
    subscribe = case party of
      SPRecipient -> subscribeSMPQueues
      SPNotifier -> subscribeSMPQueuesNtfs
    notify_ :: (SMPServer -> SMPSubParty -> NonEmpty a -> SMPClientAgentEvent) -> [a] -> IO ()
    notify_ evt qs = mapM_ (notify ca . evt srv party) $ L.nonEmpty qs

subscribeServiceSMP :: SMPClientAgent -> SMPServer -> ServiceId -> IO ()
subscribeServiceSMP = subscribeService_ SPRecipient

subscribeServiceNtfs :: SMPClientAgent -> SMPServer -> ServiceId -> IO ()
subscribeServiceNtfs = subscribeService_ SPNotifier

subscribeService_ :: SMPSubParty -> SMPClientAgent -> SMPServer -> ServiceId -> IO ()
subscribeService_ party ca srv serviceId = do
  let sub = (party, serviceId)
  atomically $ setPendingServiceSub ca srv $ Just sub
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Right smp -> smpSubscribeService ca smp srv sub
    Left _ -> pure () -- no call to reconnectClient - failing getSMPServerClient' does that

smpSubscribeService :: SMPClientAgent -> SMPClient -> SMPServer -> (SMPSubParty, ServiceId) -> IO ()
smpSubscribeService ca smp srv sub@(party, serviceId) = case smpClientService smp of
  Just service | serviceAvailable service -> subscribe
  _ -> notifyUnavailable
  where
    subscribe = do
      r <- runExceptT $ case party of
        SPRecipient -> subscribeRcvService smp
        SPNotifier -> subscribeNtfService smp
      ok <-
        atomically $
          ifM
            (activeClientSession ca smp srv)
            (True <$ processSubscription r)
            (pure False)
      if ok
        then case r of
          Right n -> notify ca $ CAServiceSubscribed srv sub n
          Left PCEServiceUnavailable -> notifyUnavailable
          Left e
            | temporaryClientError e -> reconnectClient ca srv
            | otherwise -> notify ca $ CAServiceSubError srv sub e
        else reconnectClient ca srv
    processSubscription = mapM_ $ \_ -> do
      setActiveServiceSub ca srv $ Just (sub, sessId)
      setPendingServiceSub ca srv Nothing
    serviceAvailable THClientService {serviceRole, serviceId = serviceId'} =
      compatibleRole serviceRole party && serviceId' == serviceId
    compatibleRole SRMessaging SPRecipient = True
    compatibleRole SRNotifier SPNotifier = True
    compatibleRole _ _ = False
    notifyUnavailable = do
      atomically $ setPendingServiceSub ca srv Nothing
      notify ca $ CAServiceUnavailable srv sub -- this will resubscribe all queues directly
    sessId = sessionId $ thParams smp

activeClientSession' :: SMPClientAgent -> SessionId -> SMPServer -> STM Bool
activeClientSession' ca sessId srv = sameSess <$> tryReadSessVar srv (smpClients ca)
  where
    sameSess = \case
      Just (Right (_, smp')) -> sessId == sessionId (thParams smp')
      _ -> False

activeClientSession :: SMPClientAgent -> SMPClient -> SMPServer -> STM Bool
activeClientSession ca = activeClientSession' ca . sessionId . thParams

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

addSubscriptions :: SMPClientAgent -> SMPServer -> SMPSubParty -> [(QueueId, (SessionId, C.APrivateAuthKey))] -> STM ()
addSubscriptions = addSubsList_ . activeQueueSubs
{-# INLINE addSubscriptions #-}

addPendingSubs :: SMPClientAgent -> SMPServer -> SMPSubParty -> [(QueueId, C.APrivateAuthKey)] -> STM ()
addPendingSubs = addSubsList_ . pendingQueueSubs
{-# INLINE addPendingSubs #-}

addSubsList_ :: TMap SMPServer (TMap SMPSub s) -> SMPServer -> SMPSubParty -> [(QueueId, s)] -> STM ()
addSubsList_ subs srv party ss = addSubs_ subs srv ss'
  where
    ss' = M.fromList $ map (first (party,)) ss

addSubs_ :: TMap SMPServer (TMap SMPSub s) -> SMPServer -> Map SMPSub s -> STM ()
addSubs_ subs srv ss =
  TM.lookup srv subs >>= \case
    Just m -> TM.union ss m
    _ -> TM.insertM srv (newTVar ss) subs

setActiveServiceSub :: SMPClientAgent -> SMPServer -> Maybe ((SMPSubParty, ServiceId), SessionId) -> STM ()
setActiveServiceSub = setServiceSub_ activeServiceSubs
{-# INLINE setActiveServiceSub #-}

setPendingServiceSub :: SMPClientAgent -> SMPServer -> Maybe (SMPSubParty, ServiceId) -> STM ()
setPendingServiceSub = setServiceSub_ pendingServiceSubs
{-# INLINE setPendingServiceSub #-}

setServiceSub_ ::
  (SMPClientAgent -> TMap SMPServer (TVar (Maybe sub))) ->
  SMPClientAgent ->
  SMPServer ->
  Maybe sub ->
  STM ()
setServiceSub_ subsSel ca srv sub =
  TM.lookup srv (subsSel ca) >>= \case
    Just v -> writeTVar v sub
    Nothing -> TM.insertM srv (newTVar sub) (subsSel ca)

removeSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removeSubscription = removeSub_ . activeQueueSubs
{-# INLINE removeSubscription #-}

removePendingSub :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removePendingSub = removeSub_ . pendingQueueSubs
{-# INLINE removePendingSub #-}

removeSub_ :: TMap SMPServer (TMap SMPSub s) -> SMPServer -> SMPSub -> STM ()
removeSub_ subs srv s = TM.lookup srv subs >>= mapM_ (TM.delete s)

removeSubscriptions :: SMPClientAgent -> SMPServer -> SMPSubParty -> [QueueId] -> STM ()
removeSubscriptions = removeSubs_ . activeQueueSubs
{-# INLINE removeSubscriptions #-}

removePendingSubs :: SMPClientAgent -> SMPServer -> SMPSubParty -> [QueueId] -> STM ()
removePendingSubs = removeSubs_ . pendingQueueSubs
{-# INLINE removePendingSubs #-}

removeSubs_ :: TMap SMPServer (TMap SMPSub s) -> SMPServer -> SMPSubParty -> [QueueId] -> STM ()
removeSubs_ subs srv party qs = TM.lookup srv subs >>= mapM_ (`modifyTVar'` (`M.withoutKeys` ss))
  where
    ss = S.fromList $ map (party,) qs
