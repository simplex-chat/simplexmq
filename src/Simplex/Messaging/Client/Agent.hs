{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
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
  | CASubscribed SMPServer SMPSubParty (NonEmpty (QueueId, Maybe ServiceId))
  | CASubError SMPServer SMPSubParty (NonEmpty (QueueId, SMPClientError))
  | CAServiceDisconnected SMPServer (SMPSubParty, ServiceId)
  | CAServiceSubscibed SMPServer (SMPSubParty, ServiceId) Word32
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
    activeQueueSubs :: TMap SMPServer (TMap SMPSub (SessionId, C.APrivateAuthKey)),
    -- Only one service subscription can exist per server with this agent.
    -- With correctly functioning SMP server, queue and service subscriptions cab't be
    -- active at the same time.
    activeServiceSubs :: TMap SMPServer (TVar (Maybe ((SMPSubParty, ServiceId), SessionId))),
    pendingQueueSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    -- Pending service subscriptions can co-exist with pending queue subscriptions
    -- on the same SMP server during subscriptions being transitioned from per-queue to service.
    pendingServiceSubs :: TMap SMPServer (TVar (Maybe (SMPSubParty, ServiceId))),
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
  activeQueueSubs <- TM.emptyIO
  pendingQueueSubs <- TM.emptyIO
  smpSubWorkers <- TM.emptyIO
  activeServiceSubs <- TM.emptyIO
  pendingServiceSubs <- TM.emptyIO
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
        activeQueueSubs,
        pendingQueueSubs,
        smpSubWorkers,
        activeServiceSubs,
        pendingServiceSubs,
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

    removeClientAndSubs :: SMPClient -> IO (Maybe (Map SMPSub C.APrivateAuthKey), Maybe (SMPSubParty, ServiceId))
    removeClientAndSubs smp = do
      -- Looking up subscription vars outside of STM transaction to reduce re-evaluation.
      -- It is possible because these vars are never removed, they are only added.
      qVar_ <- TM.lookupIO srv $ activeQueueSubs ca
      sVar_ <- TM.lookupIO srv $ activeServiceSubs ca
      atomically $ do
        TM.delete sessId smpSessions
        removeSessVar v srv smpClients
        pendingQs <- pure qVar_ $>>= updateQueueSubs
        pendingS <- pure sVar_ $>>= updateServiceSub
        pure (pendingQs, pendingS)
      where
        sessId = sessionId $ thParams smp
        updateQueueSubs qVar = do
          -- removing subscriptions that have matching sessionId to disconnected client
          -- and keep the other ones (they can be made by the new client)
          sub <- M.map snd <$> stateTVar qVar (M.partition ((sessId ==) . fst))
          if M.null sub
            then pure Nothing
            else Just sub <$ addSubs_ (pendingQueueSubs ca) srv sub
        updateServiceSub sVar = do -- (sub, sessId')
          -- We don't change active subscription in case session ID is different from disconnected client
          sub <- stateTVar sVar $ \case
            Just (sub, sessId') | sessId == sessId' -> (Just sub, Nothing)
            s -> (Nothing, s)
          -- We don't reset pending subscription to Nothing here to avoid any race conditions
          -- with subsequent client sessions that might have set pending already.
          when (isJust sub) $ setPendingServiceSub ca srv sub
          pure sub

    serverDown :: (Maybe (Map SMPSub C.APrivateAuthKey), Maybe (SMPSubParty, ServiceId)) -> IO ()
    serverDown (qs, ss) = do
      mapM_ (notify ca . CADisconnected srv . M.keysSet) qs
      mapM_ (notify ca . CAServiceDisconnected srv) ss
      when (isJust qs || isJust ss) $ reconnectClient ca srv

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
    noPending (qSubs, sSub) = maybe True M.null qSubs && isNothing sSub
    getPending :: Monad m => (forall a. SMPServer -> TMap SMPServer a -> m (Maybe a)) -> (forall a. TVar a -> m a) -> m (Maybe (Map SMPSub C.APrivateAuthKey), Maybe (SMPSubParty, ServiceId))
    getPending lkup rd = do
      qSubs <- lkup srv (pendingQueueSubs ca) >>= mapM rd
      sSub <- lkup srv (pendingServiceSubs ca) $>>= rd
      pure (qSubs, sSub)
    cleanup :: SessionVar (Async ()) -> STM ()
    cleanup v = do
      -- Here we wait until TMVar is not empty to prevent worker cleanup happening before worker is added to TMVar.
      -- Not waiting may result in terminated worker remaining in the map.
      whenM (isEmptyTMVar $ sessionVar v) retry
      removeSessVar v srv smpSubWorkers

reconnectSMPClient :: SMPClientAgent -> SMPServer -> (Maybe (Map SMPSub C.APrivateAuthKey), Maybe (SMPSubParty, ServiceId)) -> ExceptT SMPClientError IO ()
reconnectSMPClient ca@SMPClientAgent {agentCfg} srv (qSubs_, sSub_) =
  withSMP ca srv $ \smp -> liftIO $ do
    forM_ qSubs_ $ \qSubs -> do
      currSubs <- maybe (pure M.empty) readTVarIO =<< TM.lookupIO srv (activeQueueSubs ca)
      let (nSubs, rSubs) = foldr (groupSub currSubs) ([], []) $ M.assocs qSubs
      subscribe_ smp SPNotifier nSubs
      subscribe_ smp SPRecipient rSubs
    -- TODO [certs] subscribe pending service subscription if service ID in the client is the same
    -- If different, report CAServiceUnavailable
    forM_ sSub_ $ \_sSub -> pure ()
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
    Just (tempErrs, finalErrs, oks, _) -> do
      notify_ CASubscribed $ map fst oks
      notify_ CASubError finalErrs
      when tempErrs $ reconnectClient ca srv
    Nothing -> reconnectClient ca srv
  where
    processSubscriptions :: NonEmpty (Either SMPClientError (Maybe ServiceId)) -> STM (Bool, [(QueueId, SMPClientError)], [((QueueId, Maybe ServiceId), (SessionId, C.APrivateAuthKey))], [QueueId])
    processSubscriptions rs = do
      pending <- maybe (pure M.empty) readTVar =<< TM.lookup srv (pendingQueueSubs ca)
      let acc@(_, _, oks, notPending) = foldr (groupSub pending) (False, [], [], []) (L.zip subs rs)
      -- TODO [certs] add subscriptions for service IDs too.
      unless (null oks) $ addSubscriptions ca srv party $ map (first fst) oks
      unless (null notPending) $ removePendingSubs ca srv party notPending
      pure acc
    sessId = sessionId $ thParams smp
    groupSub ::
      Map SMPSub C.APrivateAuthKey ->
      ((QueueId, C.APrivateAuthKey), Either SMPClientError (Maybe ServiceId)) ->
      (Bool, [(QueueId, SMPClientError)], [((QueueId, Maybe ServiceId), (SessionId, C.APrivateAuthKey))], [QueueId]) ->
      (Bool, [(QueueId, SMPClientError)], [((QueueId, Maybe ServiceId), (SessionId, C.APrivateAuthKey))], [QueueId])
    groupSub pending ((qId, pk), r) acc@(!tempErrs, finalErrs, oks, notPending) = case r of
      Right serviceId -- TODO [certs] subscriptions for service IDs
        | M.member (party, qId) pending -> (tempErrs, finalErrs, ((qId, serviceId), (sessId, pk)) : oks, qId : notPending)
        | otherwise -> acc
      Left e
        | temporaryClientError e -> (True, finalErrs, oks, notPending)
        | otherwise -> (tempErrs, (qId, e) : finalErrs, oks, qId : notPending)
    subscribe = case party of
      SPRecipient -> subscribeSMPQueues
      SPNotifier -> subscribeSMPQueuesNtfs
    notify_ :: (SMPServer -> SMPSubParty -> NonEmpty a -> SMPClientAgentEvent) -> [a] -> IO ()
    notify_ evt qs = mapM_ (notify ca . evt srv party) $ L.nonEmpty qs

-- smpSubscribeService :: SMPSubParty -> SMPClientAgent -> SMPClient -> SMPServer -> IO ()
-- smpSubscribeService party ca smp srv = do
--   r <- case party of
--     SPRecipient -> subscribeRcvService smp
--     SPNotifier -> subscribeNtfService smp
--   where

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

setPendingServiceSub :: SMPClientAgent -> SMPServer -> Maybe (SMPSubParty, ServiceId) -> STM ()
setPendingServiceSub ca srv sub =
  TM.lookup srv (pendingServiceSubs ca) >>= \case
    Just v -> writeTVar v sub
    Nothing -> TM.insertM srv (newTVar sub) (pendingServiceSubs ca)

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
