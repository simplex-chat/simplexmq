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
import Data.Bifunctor (bimap, first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import Data.List (partition)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Text.Encoding
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Tuple (swap)
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
import Simplex.Messaging.Util (catchAll_, ifM, toChunks, whenM, ($>>=), (<$$>))
import System.Timeout (timeout)
import UnliftIO (async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type SMPClientVar = SessionVar (Either (SMPClientError, Maybe UTCTime) (OwnServer, SMPClient))

data SMPClientAgentEvent
  = CAConnected SMPServer
  | CADisconnected SMPServer (Set SMPSub)
  | CAResubscribed SMPServer (NonEmpty SMPSub)
  | CASubError SMPServer (NonEmpty (SMPSub, SMPClientError))

data SMPSubParty = SPRecipient | SPNotifier
  deriving (Eq, Ord, Show)

type SMPSub = (SMPSubParty, QueueId)

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
    { smpCfg = defaultSMPClientConfig {defaultTransport = ("5223", transport @TLS)},
      reconnectInterval =
        RetryInterval
          { initialInterval = second,
            increaseAfter = 10 * second,
            maxInterval = 10 * second
          },
      persistErrorInterval = 30, -- seconds
      msgQSize = 256,
      agentQSize = 256,
      agentSubsBatchSize = 900,
      ownServerDomains = []
    }
  where
    second = 1000000

data SMPClientAgent = SMPClientAgent
  { agentCfg :: SMPClientAgentConfig,
    active :: TVar Bool,
    msgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg),
    agentQ :: TBQueue SMPClientAgentEvent,
    randomDrg :: TVar ChaChaDRG,
    smpClients :: TMap SMPServer SMPClientVar,
    smpSessions :: TMap SessionId (OwnServer, SMPClient),
    srvSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    pendingSrvSubs :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey),
    smpSubWorkers :: TMap SMPServer (SessionVar (Async ())),
    workerSeq :: TVar Int
  }

type OwnServer = Bool

newSMPClientAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> STM SMPClientAgent
newSMPClientAgent agentCfg@SMPClientAgentConfig {msgQSize, agentQSize} randomDrg = do
  active <- newTVar True
  msgQ <- newTBQueue msgQSize
  agentQ <- newTBQueue agentQSize
  smpClients <- TM.empty
  smpSessions <- TM.empty
  srvSubs <- TM.empty
  pendingSrvSubs <- TM.empty
  smpSubWorkers <- TM.empty
  workerSeq <- newTVar 0
  pure
    SMPClientAgent
      { agentCfg,
        active,
        msgQ,
        agentQ,
        randomDrg,
        smpClients,
        smpSessions,
        srvSubs,
        pendingSrvSubs,
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
          let !c = (owned, smp)
          atomically $ do
            putTMVar (sessionVar v) (Right c)
            TM.insert (sessionId $ thParams smp) c smpSessions
          notify ca $ CAConnected srv
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
   in any (\s -> s == srv || (B.cons '.' s) `B.isSuffixOf` srv) (ownServerDomains agentCfg)

-- | Run an SMP client for SMPClientVar
connectClient :: SMPClientAgent -> SMPServer -> SMPClientVar -> IO (Either SMPClientError SMPClient)
connectClient ca@SMPClientAgent {agentCfg, smpClients, smpSessions, msgQ, randomDrg} srv v =
  getProtocolClient randomDrg (1, srv, Nothing) (smpCfg agentCfg) (Just msgQ) clientDisconnected
  where
    clientDisconnected :: SMPClient -> IO ()
    clientDisconnected smp = do
      removeClientAndSubs smp >>= (`forM_` serverDown)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: SMPClient -> IO (Maybe (Map SMPSub C.APrivateAuthKey))
    removeClientAndSubs smp = atomically $ do
      removeSessVar v srv smpClients
      TM.delete (sessionId $ thParams smp) smpSessions
      TM.lookupDelete srv (srvSubs ca) >>= mapM updateSubs
      where
        updateSubs sVar = do
          ss <- readTVar sVar
          addPendingSubs sVar ss
          pure ss

        addPendingSubs sVar ss = do
          let ps = pendingSrvSubs ca
          TM.lookup srv ps >>= \case
            Just ss' -> TM.union ss ss'
            _ -> TM.insert srv sVar ps

    serverDown :: Map SMPSub C.APrivateAuthKey -> IO ()
    serverDown ss = unless (M.null ss) $ do
      notify ca . CADisconnected srv $ M.keysSet ss
      reconnectClient ca srv

-- | Spawn reconnect worker if needed
reconnectClient :: SMPClientAgent -> SMPServer -> IO ()
reconnectClient ca@SMPClientAgent {active, agentCfg, smpSubWorkers, workerSeq} srv = do
  ts <- getCurrentTime
  whenM (readTVarIO active) $ atomically (getWorkerVar ts) >>= mapM_ (either newSubWorker (\_ -> pure ()))
  where
    getWorkerVar ts =
      ifM
        (null <$> getPending)
        (pure Nothing) -- prevent race with cleanup and adding pending queues in another call
        (Just <$> getSessVar workerSeq srv smpSubWorkers ts)
    newSubWorker :: SessionVar (Async ()) -> IO ()
    newSubWorker v = do
      a <- async $ void (E.tryAny runSubWorker) >> atomically (cleanup v)
      atomically $ putTMVar (sessionVar v) a
    runSubWorker =
      withRetryInterval (reconnectInterval agentCfg) $ \_ loop -> do
        pending <- atomically getPending
        forM_ pending $ \cs -> whenM (readTVarIO active) $ do
          void $ tcpConnectTimeout `timeout` runExceptT (reconnectSMPClient ca srv cs)
          loop
    ProtocolClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} = smpCfg agentCfg
    getPending = mapM readTVar =<< TM.lookup srv (pendingSrvSubs ca)
    cleanup :: SessionVar (Async ()) -> STM ()
    cleanup v = do
      -- Here we wait until TMVar is not empty to prevent worker cleanup happening before worker is added to TMVar.
      -- Not waiting may result in terminated worker remaining in the map.
      whenM (isEmptyTMVar $ sessionVar v) retry
      removeSessVar v srv smpSubWorkers

reconnectSMPClient :: SMPClientAgent -> SMPServer -> Map SMPSub C.APrivateAuthKey -> ExceptT SMPClientError IO ()
reconnectSMPClient ca@SMPClientAgent {agentCfg} srv cs =
  withSMP ca srv $ \smp -> do
    subs' <- filterM (fmap not . atomically . hasSub (srvSubs ca) srv . fst) $ M.assocs cs
    let (nSubs, rSubs) = partition (isNotifier . fst . fst) subs'
    subscribe_ smp SPNotifier nSubs
    subscribe_ smp SPRecipient rSubs
  where
    isNotifier = \case
      SPNotifier -> True
      SPRecipient -> False
    subscribe_ :: SMPClient -> SMPSubParty -> [(SMPSub, C.APrivateAuthKey)] -> ExceptT SMPClientError IO ()
    subscribe_ smp party = mapM_ subscribeBatch . toChunks (agentSubsBatchSize agentCfg)
      where
        subscribeBatch subs' = do
          let subs'' :: (NonEmpty (QueueId, C.APrivateAuthKey)) = L.map (first snd) subs'
          rs <- liftIO $ smpSubscribeQueues party ca smp srv subs''
          let rs' :: (NonEmpty ((SMPSub, C.APrivateAuthKey), Either SMPClientError ())) =
                L.zipWith (first . const) subs' rs
              rs'' :: [Either (SMPSub, SMPClientError) (SMPSub, C.APrivateAuthKey)] =
                map (\(sub, r) -> bimap (fst sub,) (const sub) r) $ L.toList rs'
              (errs, oks) = partitionEithers rs''
              (tempErrs, finalErrs) = partition (temporaryClientError . snd) errs
          mapM_ (atomically . addSubscription ca srv) oks
          mapM_ (notify ca . CAResubscribed srv) $ L.nonEmpty $ map fst oks
          mapM_ (atomically . removePendingSubscription ca srv . fst) finalErrs
          mapM_ (notify ca . CASubError srv) $ L.nonEmpty finalErrs
          mapM_ (throwE . snd) $ listToMaybe tempErrs

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
        pure ts_ $>>= \ts ->  -- proxy will create a new connection if ts_ is Nothing
          ifM
            ((ts <) <$> liftIO getCurrentTime) -- error persistence interval period expired?
            (Nothing <$ atomically (removeSessVar v srv smpClients)) -- proxy will create a new connection
            (pure $ Just $ Left e) -- not expired, returning error

lookupSMPServerClient :: SMPClientAgent -> SessionId -> STM (Maybe (OwnServer, SMPClient))
lookupSMPServerClient SMPClientAgent {smpSessions} sessId = TM.lookup sessId smpSessions

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
      liftIO $ putStrLn $ "SMP error (" <> show srv <> "): " <> show e
      throwE e

subscribeQueue :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> ExceptT SMPClientError IO ()
subscribeQueue ca srv sub = do
  atomically $ addPendingSubscription ca srv sub
  withSMP ca srv $ \smp -> subscribe_ smp `catchE` handleErr
  where
    subscribe_ smp = do
      smpSubscribe smp sub
      atomically $ addSubscription ca srv sub

    handleErr e = do
      atomically . when (e /= PCENetworkError && e /= PCEResponseTimeout) $
        removePendingSubscription ca srv (fst sub)
      throwE e

subscribeQueuesSMP :: SMPClientAgent -> SMPServer -> NonEmpty (RecipientId, RcvPrivateAuthKey) -> IO (NonEmpty (RecipientId, Either SMPClientError ()))
subscribeQueuesSMP = subscribeQueues_ SPRecipient

subscribeQueuesNtfs :: SMPClientAgent -> SMPServer -> NonEmpty (NotifierId, NtfPrivateAuthKey) -> IO (NonEmpty (NotifierId, Either SMPClientError ()))
subscribeQueuesNtfs = subscribeQueues_ SPNotifier

subscribeQueues_ :: SMPSubParty -> SMPClientAgent -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
subscribeQueues_ party ca srv subs = do
  atomically $ forM_ subs $ addPendingSubscription ca srv . first (party,)
  runExceptT (getSMPServerClient' ca srv) >>= \case
    Left e -> pure $ L.map ((,Left e) . fst) subs
    Right smp -> smpSubscribeQueues party ca smp srv subs

smpSubscribeQueues :: SMPSubParty -> SMPClientAgent -> SMPClient -> SMPServer -> NonEmpty (QueueId, C.APrivateAuthKey) -> IO (NonEmpty (QueueId, Either SMPClientError ()))
smpSubscribeQueues party ca smp srv subs = do
  rs <- L.zip subs <$> subscribe smp (L.map swap subs)
  atomically $ forM rs $ \(sub, r) ->
    (fst sub,) <$> case r of
      Right () -> do
        addSubscription ca srv $ first (party,) sub
        pure $ Right ()
      Left e -> do
        when (e /= PCENetworkError && e /= PCEResponseTimeout) $
          removePendingSubscription ca srv (party, fst sub)
        pure $ Left e
  where
    subscribe = case party of
      SPRecipient -> subscribeSMPQueues
      SPNotifier -> subscribeSMPQueuesNtfs

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

smpSubscribe :: SMPClient -> (SMPSub, C.APrivateAuthKey) -> ExceptT SMPClientError IO ()
smpSubscribe smp ((party, queueId), privKey) = subscribe_ smp privKey queueId
  where
    subscribe_ = case party of
      SPRecipient -> subscribeSMPQueue
      SPNotifier -> subscribeSMPQueueNotifications

addSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addSubscription ca srv sub = do
  addSub_ (srvSubs ca) srv sub
  removePendingSubscription ca srv $ fst sub

addPendingSubscription :: SMPClientAgent -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addPendingSubscription = addSub_ . pendingSrvSubs

addSub_ :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> (SMPSub, C.APrivateAuthKey) -> STM ()
addSub_ subs srv (s, key) =
  TM.lookup srv subs >>= \case
    Just m -> TM.insert s key m
    _ -> TM.singleton s key >>= \v -> TM.insert srv v subs

removeSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removeSubscription = removeSub_ . srvSubs

removePendingSubscription :: SMPClientAgent -> SMPServer -> SMPSub -> STM ()
removePendingSubscription = removeSub_ . pendingSrvSubs

removeSub_ :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM ()
removeSub_ subs srv s = TM.lookup srv subs >>= mapM_ (TM.delete s)

getSubKey :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM (Maybe C.APrivateAuthKey)
getSubKey subs srv s = TM.lookup srv subs $>>= TM.lookup s

hasSub :: TMap SMPServer (TMap SMPSub C.APrivateAuthKey) -> SMPServer -> SMPSub -> STM Bool
hasSub subs srv s = maybe (pure False) (TM.member s) =<< TM.lookup srv subs
