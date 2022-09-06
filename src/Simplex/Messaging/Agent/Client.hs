{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    MsgDeliveryKey,
    newAgentClient,
    withAgentLock,
    closeAgentClient,
    closeProtocolServerClients,
    newRcvQueue,
    subscribeQueue,
    subscribeQueues,
    getQueueMessage,
    decryptSMPMessage,
    addSubscription,
    getSubscriptions,
    sendConfirmation,
    sendInvitation,
    temporaryAgentError,
    secureQueue,
    enableQueueNotifications,
    disableQueueNotifications,
    sendAgentMessage,
    agentNtfRegisterToken,
    agentNtfVerifyToken,
    agentNtfCheckToken,
    agentNtfReplaceToken,
    agentNtfDeleteToken,
    agentNtfEnableCron,
    agentNtfCreateSubscription,
    agentNtfCheckSubscription,
    agentNtfDeleteSubscription,
    agentCbEncrypt,
    agentCbDecrypt,
    cryptoError,
    sendAck,
    suspendQueue,
    deleteQueue,
    logServer,
    removeSubscription,
    hasActiveSubscription,
    agentDbPath,
    AgentOperation (..),
    AgentOpState (..),
    AgentState (..),
    agentOperations,
    agentOperationBracket,
    beginAgentOperation,
    endAgentOperation,
    suspendSendingAndDatabase,
    suspendOperation,
    notifySuspended,
    whenSuspending,
    withStore,
    withStore',
    storeError,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry, stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time.Clock (getCurrentTime)
import Data.Tuple (swap)
import Data.Word (Word16)
import qualified Database.SQLite.Simple as DB
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore (..), withTransaction)
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol
  ( AProtocolType (..),
    BrokerMsg,
    ErrorType,
    MsgFlags (..),
    MsgId,
    NotifierId,
    NtfPrivateSignKey,
    NtfPublicVerifyKey,
    NtfServer,
    ProtoServer,
    Protocol (..),
    ProtocolServer (..),
    ProtocolTypeI (..),
    QueueId,
    QueueIdsKeys (..),
    RcvMessage (..),
    RcvNtfPublicDhKey,
    SMPMsgMeta (..),
    SndPublicVerifyKey,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Timeout (timeout)
import UnliftIO (async)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type ClientVar msg = TMVar (Either AgentErrorType (ProtocolClient msg))

type SMPClientVar = TMVar (Either AgentErrorType SMPClient)

type NtfClientVar = TMVar (Either AgentErrorType NtfClient)

type MsgDeliveryKey = (SMPServer, SMP.SenderId)

data AgentClient = AgentClient
  { active :: TVar Bool,
    rcvQ :: TBQueue (ATransmission 'Client),
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue (ServerTransmission BrokerMsg),
    smpServers :: TVar (NonEmpty SMPServer),
    smpClients :: TMap SMPServer SMPClientVar,
    ntfServers :: TVar [NtfServer],
    ntfClients :: TMap NtfServer NtfClientVar,
    useNetworkConfig :: TVar NetworkConfig,
    subscrSrvrs :: TMap SMPServer (TMap ConnId RcvQueue),
    pendingSubscrSrvrs :: TMap SMPServer (TMap ConnId RcvQueue),
    subscrConns :: TVar (Set ConnId),
    activeSubscrConns :: TMap ConnId SMPServer,
    connMsgsQueued :: TMap ConnId Bool,
    smpQueueMsgQueues :: TMap MsgDeliveryKey (TQueue InternalId),
    smpQueueMsgDeliveries :: TMap MsgDeliveryKey (Async ()),
    nextRcvQueueMsgs :: TMap (ConnId, SMPServer, SMP.RecipientId) [ServerTransmission BrokerMsg],
    ntfNetworkOp :: TVar AgentOpState,
    rcvNetworkOp :: TVar AgentOpState,
    msgDeliveryOp :: TVar AgentOpState,
    sndNetworkOp :: TVar AgentOpState,
    databaseOp :: TVar AgentOpState,
    agentState :: TVar AgentState,
    getMsgLocks :: TMap (SMPServer, SMP.RecipientId) (TMVar ()),
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()],
    clientId :: Int,
    agentEnv :: Env,
    lock :: TMVar ()
  }

data AgentOperation = AONtfNetwork | AORcvNetwork | AOMsgDelivery | AOSndNetwork | AODatabase
  deriving (Eq, Show)

agentOpSel :: AgentOperation -> (AgentClient -> TVar AgentOpState)
agentOpSel = \case
  AONtfNetwork -> ntfNetworkOp
  AORcvNetwork -> rcvNetworkOp
  AOMsgDelivery -> msgDeliveryOp
  AOSndNetwork -> sndNetworkOp
  AODatabase -> databaseOp

agentOperations :: [AgentClient -> TVar AgentOpState]
agentOperations = [ntfNetworkOp, rcvNetworkOp, msgDeliveryOp, sndNetworkOp, databaseOp]

data AgentOpState = AgentOpState {opSuspended :: Bool, opsInProgress :: Int}

data AgentState = ASActive | ASSuspending | ASSuspended
  deriving (Eq, Show)

newAgentClient :: InitialAgentServers -> Env -> STM AgentClient
newAgentClient InitialAgentServers {smp, ntf, netCfg} agentEnv = do
  let qSize = tbqSize $ config agentEnv
  active <- newTVar True
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpServers <- newTVar smp
  smpClients <- TM.empty
  ntfServers <- newTVar ntf
  ntfClients <- TM.empty
  useNetworkConfig <- newTVar netCfg
  subscrSrvrs <- TM.empty
  pendingSubscrSrvrs <- TM.empty
  subscrConns <- newTVar S.empty
  activeSubscrConns <- TM.empty
  connMsgsQueued <- TM.empty
  smpQueueMsgQueues <- TM.empty
  smpQueueMsgDeliveries <- TM.empty
  nextRcvQueueMsgs <- TM.empty
  ntfNetworkOp <- newTVar $ AgentOpState False 0
  rcvNetworkOp <- newTVar $ AgentOpState False 0
  msgDeliveryOp <- newTVar $ AgentOpState False 0
  sndNetworkOp <- newTVar $ AgentOpState False 0
  databaseOp <- newTVar $ AgentOpState False 0
  agentState <- newTVar ASActive
  getMsgLocks <- TM.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  clientId <- stateTVar (clientCounter agentEnv) $ \i -> let i' = i + 1 in (i', i')
  lock <- newTMVar ()
  return AgentClient {active, rcvQ, subQ, msgQ, smpServers, smpClients, ntfServers, ntfClients, useNetworkConfig, subscrSrvrs, pendingSubscrSrvrs, subscrConns, activeSubscrConns, connMsgsQueued, smpQueueMsgQueues, smpQueueMsgDeliveries, nextRcvQueueMsgs, ntfNetworkOp, rcvNetworkOp, msgDeliveryOp, sndNetworkOp, databaseOp, agentState, getMsgLocks, reconnections, asyncClients, clientId, agentEnv, lock}

agentDbPath :: AgentClient -> FilePath
agentDbPath AgentClient {agentEnv = Env {store = SQLiteStore {dbFilePath}}} = dbFilePath

class ProtocolServerClient msg where
  getProtocolServerClient :: AgentMonad m => AgentClient -> ProtoServer msg -> m (ProtocolClient msg)
  clientProtocolError :: ErrorType -> AgentErrorType

instance ProtocolServerClient BrokerMsg where
  getProtocolServerClient = getSMPServerClient
  clientProtocolError = SMP

instance ProtocolServerClient NtfResponse where
  getProtocolServerClient = getNtfServerClient
  clientProtocolError = NTF

getSMPServerClient :: forall m. AgentMonad m => AgentClient -> SMPServer -> m SMPClient
getSMPServerClient c@AgentClient {active, smpClients, msgQ} srv = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar srv smpClients)
    >>= either
      (newProtocolClient c srv smpClients connectClient reconnectClient)
      (waitForProtocolClient c)
  where
    connectClient :: m SMPClient
    connectClient = do
      cfg <- atomically . updateClientConfig c =<< asks (smpCfg . config)
      u <- askUnliftIO
      liftEitherError (protocolClientError SMP) (getProtocolClient srv cfg (Just msgQ) $ clientDisconnected u)

    clientDisconnected :: UnliftIO m -> SMPClient -> IO ()
    clientDisconnected u client = do
      removeClientAndSubs >>= (`forM_` serverDown)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv
      where
        removeClientAndSubs :: IO (Maybe (Map ConnId RcvQueue))
        removeClientAndSubs = atomically $ do
          TM.delete srv smpClients
          TM.lookupDelete srv (subscrSrvrs c) >>= mapM updateSubs
          where
            updateSubs cVar = do
              cs <- readTVar cVar
              modifyTVar' (activeSubscrConns c) (`M.withoutKeys` M.keysSet cs)
              addPendingSubs cVar cs
              pure cs

            addPendingSubs cVar cs = do
              let ps = pendingSubscrSrvrs c
              TM.lookup srv ps >>= \case
                Just v -> TM.union cs v
                _ -> TM.insert srv cVar ps

        serverDown :: Map ConnId RcvQueue -> IO ()
        serverDown cs = unless (M.null cs) $
          whenM (readTVarIO active) $ do
            let conns = M.keys cs
            notifySub "" $ hostEvent DISCONNECT client
            unless (null conns) . notifySub "" $ DOWN srv conns
            atomically $ mapM_ (releaseGetLock c) cs
            unliftIO u reconnectServer

        reconnectServer :: m ()
        reconnectServer = do
          a <- async tryReconnectClient
          atomically $ modifyTVar' (reconnections c) (a :)

        tryReconnectClient :: m ()
        tryReconnectClient = do
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \loop ->
            reconnectClient `catchError` const loop

    reconnectClient :: m ()
    reconnectClient =
      withAgentLock c $
        atomically (TM.lookup srv (pendingSubscrSrvrs c) >>= mapM readTVar)
          >>= mapM_ resubscribe
      where
        resubscribe :: Map ConnId RcvQueue -> m ()
        resubscribe qs = do
          (client_, (errs, oks)) <- second (M.mapEither id) <$> subscribeQueues c srv qs
          liftIO $ do
            mapM_ (notifySub "" . hostEvent CONNECT) client_
            unless (M.null oks) $ do
              notifySub "" . UP srv $ M.keys oks
          let (tempErrs, finalErrs) = M.partition temporaryAgentError errs
          liftIO . mapM_ (\(connId, e) -> notifySub connId $ ERR e) $ M.assocs finalErrs
          mapM_ throwError . listToMaybe $ M.elems tempErrs

    notifySub :: ConnId -> ACommand 'Agent -> IO ()
    notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, cmd)

getNtfServerClient :: forall m. AgentMonad m => AgentClient -> NtfServer -> m NtfClient
getNtfServerClient c@AgentClient {active, ntfClients} srv = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar srv ntfClients)
    >>= either
      (newProtocolClient c srv ntfClients connectClient $ pure ())
      (waitForProtocolClient c)
  where
    connectClient :: m NtfClient
    connectClient = do
      cfg <- atomically . updateClientConfig c =<< asks (ntfCfg . config)
      liftEitherError (protocolClientError NTF) (getProtocolClient srv cfg Nothing clientDisconnected)

    clientDisconnected :: NtfClient -> IO ()
    clientDisconnected client = do
      atomically $ TM.delete srv ntfClients
      atomically $ writeTBQueue (subQ c) ("", "", hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getClientVar :: forall a s. ProtocolServer s -> TMap (ProtocolServer s) (TMVar a) -> STM (Either (TMVar a) (TMVar a))
getClientVar srv clients = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup srv clients
  where
    newClientVar :: STM (TMVar a)
    newClientVar = do
      var <- newEmptyTMVar
      TM.insert srv var clients
      pure var

waitForProtocolClient :: AgentMonad m => AgentClient -> ClientVar msg -> m (ProtocolClient msg)
waitForProtocolClient c clientVar = do
  NetworkConfig {tcpConnectTimeout} <- readTVarIO $ useNetworkConfig c
  client_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar clientVar)
  liftEither $ case client_ of
    Just (Right smpClient) -> Right smpClient
    Just (Left e) -> Left e
    Nothing -> Left $ BROKER TIMEOUT

newProtocolClient ::
  forall msg m.
  (AgentMonad m, ProtocolTypeI (ProtoType msg)) =>
  AgentClient ->
  ProtoServer msg ->
  TMap (ProtoServer msg) (ClientVar msg) ->
  m (ProtocolClient msg) ->
  m () ->
  ClientVar msg ->
  m (ProtocolClient msg)
newProtocolClient c srv clients connectClient reconnectClient clientVar = tryConnectClient pure tryConnectAsync
  where
    tryConnectClient :: (ProtocolClient msg -> m a) -> m () -> m a
    tryConnectClient successAction retryAction =
      tryError connectClient >>= \r -> case r of
        Right client -> do
          logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
          atomically $ putTMVar clientVar r
          atomically $ writeTBQueue (subQ c) ("", "", hostEvent CONNECT client)
          successAction client
        Left e -> do
          if temporaryAgentError e
            then retryAction
            else atomically $ do
              putTMVar clientVar (Left e)
              TM.delete srv clients
          throwError e
    tryConnectAsync :: m ()
    tryConnectAsync = do
      a <- async connectAsync
      atomically $ modifyTVar' (asyncClients c) (a :)
    connectAsync :: m ()
    connectAsync = do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \loop -> void $ tryConnectClient (const reconnectClient) loop

hostEvent :: forall msg. ProtocolTypeI (ProtoType msg) => (AProtocolType -> TransportHost -> ACommand 'Agent) -> ProtocolClient msg -> ACommand 'Agent
hostEvent event client = event (AProtocolType $ protocolTypeI @(ProtoType msg)) $ transportHost client

updateClientConfig :: AgentClient -> ProtocolClientConfig -> STM ProtocolClientConfig
updateClientConfig AgentClient {useNetworkConfig} cfg = do
  networkConfig <- readTVar useNetworkConfig
  pure cfg {networkConfig}

closeAgentClient :: MonadIO m => AgentClient -> m ()
closeAgentClient c = liftIO $ do
  atomically $ writeTVar (active c) False
  closeProtocolServerClients c smpClients
  closeProtocolServerClients c ntfClients
  cancelActions $ reconnections c
  cancelActions $ asyncClients c
  cancelActions $ smpQueueMsgDeliveries c
  clear subscrSrvrs
  clear pendingSubscrSrvrs
  clear subscrConns
  clear activeSubscrConns
  clear connMsgsQueued
  clear smpQueueMsgQueues
  clear getMsgLocks
  where
    clear :: Monoid m => (AgentClient -> TVar m) -> IO ()
    clear sel = atomically $ writeTVar (sel c) mempty

closeProtocolServerClients :: AgentClient -> (AgentClient -> TMap (ProtoServer msg) (ClientVar msg)) -> IO ()
closeProtocolServerClients c clientsSel =
  readTVarIO cs >>= mapM_ (forkIO . closeClient) >> atomically (writeTVar cs M.empty)
  where
    cs = clientsSel c
    closeClient cVar = do
      NetworkConfig {tcpConnectTimeout} <- readTVarIO $ useNetworkConfig c
      tcpConnectTimeout `timeout` atomically (readTMVar cVar) >>= \case
        Just (Right client) -> closeProtocolClient client `catchAll_` pure ()
        _ -> pure ()

cancelActions :: (Foldable f, Monoid (f (Async ()))) => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel >> atomically (writeTVar as mempty)

withAgentLock :: MonadUnliftIO m => AgentClient -> m a -> m a
withAgentLock AgentClient {lock} =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

withClient_ :: forall a m msg. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtoServer msg -> (ProtocolClient msg -> m a) -> m a
withClient_ c srv action = (getProtocolServerClient c srv >>= action) `catchError` logServerError
  where
    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ bshow e
      throwError e

withLogClient_ :: (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtoServer msg -> QueueId -> ByteString -> (ProtocolClient msg -> m a) -> m a
withLogClient_ c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withClient_ c srv action
  logServer "<--" c srv qId "OK"
  return res

withClient :: forall m msg a. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtoServer msg -> (ProtocolClient msg -> ExceptT ProtocolClientError IO a) -> m a
withClient c srv action = withClient_ c srv $ liftClient (clientProtocolError @msg) . action

withLogClient :: forall m msg a. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtoServer msg -> QueueId -> ByteString -> (ProtocolClient msg -> ExceptT ProtocolClientError IO a) -> m a
withLogClient c srv qId cmdStr action = withLogClient_ c srv qId cmdStr $ liftClient (clientProtocolError @msg) . action

liftClient :: AgentMonad m => (ErrorType -> AgentErrorType) -> ExceptT ProtocolClientError IO a -> m a
liftClient = liftError . protocolClientError

protocolClientError :: (ErrorType -> AgentErrorType) -> ProtocolClientError -> AgentErrorType
protocolClientError protocolError_ = \case
  PCEProtocolError e -> protocolError_ e
  PCEResponseError e -> BROKER $ RESPONSE e
  PCEUnexpectedResponse _ -> BROKER UNEXPECTED
  PCEResponseTimeout -> BROKER TIMEOUT
  PCENetworkError -> BROKER NETWORK
  PCEIncompatibleHost -> BROKER HOST
  PCETransportError e -> BROKER $ TRANSPORT e
  e@PCESignatureError {} -> INTERNAL $ show e
  e@PCEIOError {} -> INTERNAL $ show e

newRcvQueue :: AgentMonad m => AgentClient -> SMPServer -> VersionRange -> Bool -> m (RcvQueue, SMPQueueUri)
newRcvQueue c srv vRange current =
  asks (cmdSignAlg . config) >>= \case
    C.SignAlg a -> newRcvQueue_ a c srv vRange current

newRcvQueue_ ::
  (C.SignatureAlgorithm a, C.AlgorithmI a, AgentMonad m) =>
  C.SAlgorithm a ->
  AgentClient ->
  SMPServer ->
  VersionRange ->
  Bool ->
  m (RcvQueue, SMPQueueUri)
newRcvQueue_ a c srv vRange current = do
  (recipientKey, rcvPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (dhKey, privDhKey) <- liftIO C.generateKeyPair'
  (e2eDhKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  logServer "-->" c srv "" "NEW"
  QIK {rcvId, sndId, rcvPublicDhKey} <-
    withClient c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey dhKey
  createdAt <- liftIO getCurrentTime
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sndId]
  let rq =
        RcvQueue
          { server = srv,
            rcvId,
            rcvPrivateKey,
            rcvDhSecret = C.dh' rcvPublicDhKey privDhKey,
            e2ePrivKey,
            e2eDhSecret = Nothing,
            sndId,
            sndPublicKey = Nothing,
            status = New,
            rcvQueueAction = Nothing,
            currRcvQueue = current,
            dbNextRcvQueueId = Nothing,
            clientNtfCreds = Nothing,
            smpClientVersion = maxVersion vRange,
            createdAt,
            updatedAt = createdAt
          }
  pure (rq, SMPQueueUri vRange $ SMPQueueAddress srv sndId e2eDhKey)

subscribeQueue :: AgentMonad m => AgentClient -> RcvQueue -> ConnId -> m ()
subscribeQueue c rq@RcvQueue {server, rcvPrivateKey, rcvId} connId = do
  whenM (atomically . TM.member (server, rcvId) $ getMsgLocks c) . throwError $ CMD PROHIBITED
  atomically $ do
    modifyTVar (subscrConns c) $ S.insert connId
    addPendingSubscription c rq connId
  withLogClient c server rcvId "SUB" $ \smp ->
    liftIO (runExceptT (subscribeSMPQueue smp rcvPrivateKey rcvId) >>= processSubResult c rq connId)
      >>= either throwError pure

processSubResult :: AgentClient -> RcvQueue -> ConnId -> Either ProtocolClientError () -> IO (Either ProtocolClientError ())
processSubResult c rq@RcvQueue {server} connId r = do
  case r of
    Left e ->
      atomically . unless (temporaryClientError e) $
        removePendingSubscription c server connId
    _ -> addSubscription c rq connId
  pure r

temporaryClientError :: ProtocolClientError -> Bool
temporaryClientError = \case
  PCENetworkError -> True
  PCEResponseTimeout -> True
  _ -> False

temporaryAgentError :: AgentErrorType -> Bool
temporaryAgentError = \case
  BROKER NETWORK -> True
  BROKER TIMEOUT -> True
  _ -> False

-- | subscribe multiple queues - all passed queues should be on the same server
subscribeQueues :: AgentMonad m => AgentClient -> SMPServer -> Map ConnId RcvQueue -> m (Maybe SMPClient, Map ConnId (Either AgentErrorType ()))
subscribeQueues c srv qs = do
  (errs, qs_) <- partitionEithers <$> mapM checkQueue (M.assocs qs)
  forM_ qs_ $ \q -> atomically $ do
    modifyTVar (subscrConns c) . S.insert $ fst q
    uncurry (addPendingSubscription c) $ swap q
  case L.nonEmpty qs_ of
    Just qs' -> do
      smp_ <- tryError (getSMPServerClient c srv)
      (eitherToMaybe smp_,) . M.fromList . (errs <>) <$> case smp_ of
        Left e -> pure $ map (second . const $ Left e) qs_
        Right smp -> do
          logServer "-->" c srv (bshow (length qs_) <> " queues") "SUB"
          let qs2 = L.map (queueCreds . snd) qs'
          rs' :: [((ConnId, RcvQueue), Either ProtocolClientError ())] <-
            liftIO $ zip qs_ . L.toList <$> subscribeSMPQueues smp qs2
          forM_ rs' $ \((connId, rq), r) -> liftIO $ processSubResult c rq connId r
          pure $ map (bimap fst (first $ protocolClientError SMP)) rs'
    _ -> pure $ (Nothing, M.fromList errs)
  where
    checkQueue rq@(connId, RcvQueue {rcvId, server}) = do
      prohibited <- atomically . TM.member (server, rcvId) $ getMsgLocks c
      pure $ if prohibited || srv /= server then Left (connId, Left $ CMD PROHIBITED) else Right rq
    queueCreds RcvQueue {rcvPrivateKey, rcvId} = (rcvPrivateKey, rcvId)

addSubscription :: MonadIO m => AgentClient -> RcvQueue -> ConnId -> m ()
addSubscription c rq@RcvQueue {server} connId = atomically $ do
  TM.insert connId server $ activeSubscrConns c
  modifyTVar (subscrConns c) $ S.insert connId
  addSubs_ (subscrSrvrs c) rq connId
  removePendingSubscription c server connId

hasActiveSubscription :: AgentClient -> ConnId -> STM Bool
hasActiveSubscription c connId = TM.member connId (activeSubscrConns c)

addPendingSubscription :: AgentClient -> RcvQueue -> ConnId -> STM ()
addPendingSubscription = addSubs_ . pendingSubscrSrvrs

addSubs_ :: TMap SMPServer (TMap ConnId RcvQueue) -> RcvQueue -> ConnId -> STM ()
addSubs_ ss rq@RcvQueue {server} connId =
  TM.lookup server ss >>= \case
    Just m -> TM.insert connId rq m
    _ -> TM.singleton connId rq >>= \m -> TM.insert server m ss

removeSubscription :: AgentClient -> ConnId -> STM ()
removeSubscription c connId = do
  modifyTVar (subscrConns c) $ S.delete connId
  server_ <- TM.lookupDelete connId $ activeSubscrConns c
  mapM_ (\server -> removeSubs_ (subscrSrvrs c) server connId) server_

removePendingSubscription :: AgentClient -> SMPServer -> ConnId -> STM ()
removePendingSubscription = removeSubs_ . pendingSubscrSrvrs

removeSubs_ :: TMap SMPServer (TMap ConnId RcvQueue) -> SMPServer -> ConnId -> STM ()
removeSubs_ ss server connId =
  TM.lookup server ss >>= mapM_ (TM.delete connId)

getSubscriptions :: AgentClient -> STM (Set ConnId)
getSubscriptions = readTVar . subscrConns

logServer :: MonadIO m => ByteString -> AgentClient -> ProtocolServer s -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: ProtocolServer s -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SndQueue -> ByteString -> m ()
sendConfirmation c sq@SndQueue {server, sndId, sndPublicKey = Just sndPublicKey, e2ePubKey = e2ePubKey@Just {}} agentConfirmation =
  withLogClient_ c server sndId "SEND <CONF>" $ \smp -> do
    let clientMsg = SMP.ClientMessage (SMP.PHConfirmation sndPublicKey) agentConfirmation
    msg <- agentCbEncrypt sq e2ePubKey $ smpEncode clientMsg
    liftClient SMP $ sendSMPMessage smp Nothing sndId (SMP.MsgFlags {notification = True}) msg
sendConfirmation _ _ _ = throwError $ INTERNAL "sendConfirmation called without snd_queue public key(s) in the database"

sendInvitation :: forall m. AgentMonad m => AgentClient -> Compatible SMPQueueInfo -> Compatible Version -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
sendInvitation c (Compatible (SMPQueueInfo v SMPQueueAddress {smpServer, senderId, dhPublicKey})) (Compatible agentVersion) connReq connInfo =
  withLogClient_ c smpServer senderId "SEND <INV>" $ \smp -> do
    msg <- mkInvitation
    liftClient SMP $ sendSMPMessage smp Nothing senderId MsgFlags {notification = True} msg
  where
    mkInvitation :: m ByteString
    -- this is only encrypted with per-queue E2E, not with double ratchet
    mkInvitation = do
      let agentEnvelope = AgentInvitation {agentVersion, connReq, connInfo}
      agentCbEncryptOnce v dhPublicKey . smpEncode $
        SMP.ClientMessage SMP.PHEmpty $ smpEncode agentEnvelope

getQueueMessage :: AgentMonad m => AgentClient -> RcvQueue -> m (Maybe SMPMsgMeta)
getQueueMessage c rq@RcvQueue {server, rcvId, rcvPrivateKey} = do
  atomically createTakeGetLock
  (v, msg_) <- withLogClient c server rcvId "GET" $ \smp ->
    (thVersion smp,) <$> getSMPMessage smp rcvPrivateKey rcvId
  mapM (decryptMeta v) msg_
  where
    decryptMeta v msg@SMP.RcvMessage {msgId} = SMP.rcvMessageMeta msgId <$> decryptSMPMessage v rq msg
    createTakeGetLock = TM.alterF takeLock (server, rcvId) $ getMsgLocks c
      where
        takeLock l_ = do
          l <- maybe (newTMVar ()) pure l_
          takeTMVar l
          pure $ Just l

decryptSMPMessage :: AgentMonad m => Version -> RcvQueue -> SMP.RcvMessage -> m SMP.ClientRcvMsgBody
decryptSMPMessage v rq SMP.RcvMessage {msgId, msgTs, msgFlags, msgBody = SMP.EncRcvMsgBody body}
  | v == 1 || v == 2 = SMP.ClientRcvMsgBody msgTs msgFlags <$> decrypt body
  | otherwise = liftEither . parse SMP.clientRcvMsgBodyP (AGENT A_MESSAGE) =<< decrypt body
  where
    decrypt = agentCbDecrypt (rcvDhSecret rq) (C.cbNonce msgId)

secureQueue :: AgentMonad m => AgentClient -> RcvQueue -> SndPublicVerifyKey -> m ()
secureQueue c RcvQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogClient c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

enableQueueNotifications :: AgentMonad m => AgentClient -> RcvQueue -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> m (NotifierId, RcvNtfPublicDhKey)
enableQueueNotifications c RcvQueue {server, rcvId, rcvPrivateKey} notifierKey rcvNtfPublicDhKey =
  withLogClient c server rcvId "NKEY <nkey>" $ \smp ->
    enableSMPQueueNotifications smp rcvPrivateKey rcvId notifierKey rcvNtfPublicDhKey

disableQueueNotifications :: AgentMonad m => AgentClient -> RcvQueue -> m ()
disableQueueNotifications c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogClient c server rcvId "NDEL" $ \smp ->
    disableSMPQueueNotifications smp rcvPrivateKey rcvId

sendAck :: AgentMonad m => AgentClient -> RcvQueue -> MsgId -> m ()
sendAck c rq@RcvQueue {server, rcvId, rcvPrivateKey} msgId = do
  withLogClient c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId msgId
  atomically $ releaseGetLock c rq

releaseGetLock :: AgentClient -> RcvQueue -> STM ()
releaseGetLock c RcvQueue {server, rcvId} =
  TM.lookup (server, rcvId) (getMsgLocks c) >>= mapM_ (`tryPutTMVar` ())

suspendQueue :: AgentMonad m => AgentClient -> RcvQueue -> m Word16
suspendQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogClient c server rcvId "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
deleteQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogClient c server rcvId "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

sendAgentMessage :: forall m. AgentMonad m => AgentClient -> SndQueue -> MsgFlags -> ByteString -> m ()
sendAgentMessage c sq@SndQueue {server, sndId, sndPrivateKey} msgFlags agentMsg =
  withLogClient_ c server sndId "SEND <MSG>" $ \smp -> do
    let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
    msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
    liftClient SMP $ sendSMPMessage smp (Just sndPrivateKey) sndId msgFlags msg

agentNtfRegisterToken :: AgentMonad m => AgentClient -> NtfToken -> C.APublicVerifyKey -> C.PublicKeyX25519 -> m (NtfTokenId, C.PublicKeyX25519)
agentNtfRegisterToken c NtfToken {deviceToken, ntfServer, ntfPrivKey} ntfPubKey pubDhKey =
  withClient c ntfServer $ \ntf -> ntfRegisterToken ntf ntfPrivKey (NewNtfTkn deviceToken ntfPubKey pubDhKey)

agentNtfVerifyToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> NtfRegCode -> m ()
agentNtfVerifyToken c tknId NtfToken {ntfServer, ntfPrivKey} code =
  withLogClient c ntfServer tknId "TVFY" $ \ntf -> ntfVerifyToken ntf ntfPrivKey tknId code

agentNtfCheckToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> m NtfTknStatus
agentNtfCheckToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withLogClient c ntfServer tknId "TCHK" $ \ntf -> ntfCheckToken ntf ntfPrivKey tknId

agentNtfReplaceToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> DeviceToken -> m ()
agentNtfReplaceToken c tknId NtfToken {ntfServer, ntfPrivKey} token =
  withLogClient c ntfServer tknId "TRPL" $ \ntf -> ntfReplaceToken ntf ntfPrivKey tknId token

agentNtfDeleteToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> m ()
agentNtfDeleteToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withLogClient c ntfServer tknId "TDEL" $ \ntf -> ntfDeleteToken ntf ntfPrivKey tknId

agentNtfEnableCron :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> Word16 -> m ()
agentNtfEnableCron c tknId NtfToken {ntfServer, ntfPrivKey} interval =
  withLogClient c ntfServer tknId "TCRN" $ \ntf -> ntfEnableCron ntf ntfPrivKey tknId interval

agentNtfCreateSubscription :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> SMPQueueNtf -> NtfPrivateSignKey -> m NtfSubscriptionId
agentNtfCreateSubscription c tknId NtfToken {ntfServer, ntfPrivKey} smpQueue nKey =
  withLogClient c ntfServer tknId "SNEW" $ \ntf -> ntfCreateSubscription ntf ntfPrivKey (NewNtfSub tknId smpQueue nKey)

agentNtfCheckSubscription :: AgentMonad m => AgentClient -> NtfSubscriptionId -> NtfToken -> m NtfSubStatus
agentNtfCheckSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withLogClient c ntfServer subId "SCHK" $ \ntf -> ntfCheckSubscription ntf ntfPrivKey subId

agentNtfDeleteSubscription :: AgentMonad m => AgentClient -> NtfSubscriptionId -> NtfToken -> m ()
agentNtfDeleteSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withLogClient c ntfServer subId "SDEL" $ \ntf -> ntfDeleteSubscription ntf ntfPrivKey subId

agentCbEncrypt :: AgentMonad m => SndQueue -> Maybe C.PublicKeyX25519 -> ByteString -> m ByteString
agentCbEncrypt SndQueue {e2eDhSecret, smpClientVersion} e2ePubKey msg = do
  cmNonce <- liftIO C.randomCbNonce
  let paddedLen = maybe SMP.e2eEncMessageLength (const SMP.e2eEncConfirmationLength) e2ePubKey
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg paddedLen
  let cmHeader = SMP.PubHeader smpClientVersion e2ePubKey
  pure $ smpEncode SMP.ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

-- add encoding as AgentInvitation'?
agentCbEncryptOnce :: AgentMonad m => Version -> C.PublicKeyX25519 -> ByteString -> m ByteString
agentCbEncryptOnce clientVersion dhRcvPubKey msg = do
  (dhSndPubKey, dhSndPrivKey) <- liftIO C.generateKeyPair'
  let e2eDhSecret = C.dh' dhRcvPubKey dhSndPrivKey
  cmNonce <- liftIO C.randomCbNonce
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg SMP.e2eEncConfirmationLength
  let cmHeader = SMP.PubHeader clientVersion (Just dhSndPubKey)
  pure $ smpEncode SMP.ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

-- | NaCl crypto-box decrypt - both for messages received from the server
-- and per-queue E2E encrypted messages from the sender that were inside.
agentCbDecrypt :: AgentMonad m => C.DhSecretX25519 -> C.CbNonce -> ByteString -> m ByteString
agentCbDecrypt dhSecret nonce msg =
  liftEither . first cryptoError $
    C.cbDecrypt dhSecret nonce msg

cryptoError :: C.CryptoError -> AgentErrorType
cryptoError = \case
  C.CryptoLargeMsgError -> CMD LARGE
  C.CryptoHeaderError _ -> AGENT A_ENCRYPTION
  C.AESDecryptError -> AGENT A_ENCRYPTION
  C.CBDecryptError -> AGENT A_ENCRYPTION
  C.CERatchetDuplicateMessage -> AGENT A_DUPLICATE
  e -> INTERNAL $ show e

endAgentOperation :: AgentClient -> AgentOperation -> STM ()
endAgentOperation c op = endOperation c op $ case op of
  AONtfNetwork -> pure ()
  AORcvNetwork ->
    suspendOperation c AOMsgDelivery $
      suspendSendingAndDatabase c
  AOMsgDelivery ->
    suspendSendingAndDatabase c
  AOSndNetwork ->
    suspendOperation c AODatabase $
      notifySuspended c
  AODatabase ->
    notifySuspended c

suspendSendingAndDatabase :: AgentClient -> STM ()
suspendSendingAndDatabase c =
  suspendOperation c AOSndNetwork $
    suspendOperation c AODatabase $
      notifySuspended c

suspendOperation :: AgentClient -> AgentOperation -> STM () -> STM ()
suspendOperation c op endedAction = do
  n <- stateTVar (agentOpSel op c) $ \s -> (opsInProgress s, s {opSuspended = True})
  -- unsafeIOToSTM $ putStrLn $ "suspendOperation_ " <> show op <> " " <> show n
  when (n == 0) $ whenSuspending c endedAction

notifySuspended :: AgentClient -> STM ()
notifySuspended c = do
  -- unsafeIOToSTM $ putStrLn "notifySuspended"
  writeTBQueue (subQ c) ("", "", SUSPENDED)
  writeTVar (agentState c) ASSuspended

endOperation :: AgentClient -> AgentOperation -> STM () -> STM ()
endOperation c op endedAction = do
  (suspended, n) <- stateTVar (agentOpSel op c) $ \s ->
    let n = max 0 (opsInProgress s - 1)
     in ((opSuspended s, n), s {opsInProgress = n})
  -- unsafeIOToSTM $ putStrLn $ "endOperation: " <> show op <> " " <> show suspended <> " " <> show n
  when (suspended && n == 0) $ whenSuspending c endedAction

whenSuspending :: AgentClient -> STM () -> STM ()
whenSuspending c = whenM ((== ASSuspending) <$> readTVar (agentState c))

beginAgentOperation :: AgentClient -> AgentOperation -> STM ()
beginAgentOperation c op = do
  let opVar = agentOpSel op c
  s <- readTVar opVar
  -- unsafeIOToSTM $ putStrLn $ "beginOperation? " <> show op <> " " <> show (opsInProgress s)
  when (opSuspended s) retry
  -- unsafeIOToSTM $ putStrLn $ "beginOperation! " <> show op <> " " <> show (opsInProgress s + 1)
  writeTVar opVar $! s {opsInProgress = opsInProgress s + 1}

agentOperationBracket :: MonadUnliftIO m => AgentClient -> AgentOperation -> m a -> m a
agentOperationBracket c op action =
  E.bracket
    (atomically $ beginAgentOperation c op)
    (\_ -> atomically $ endAgentOperation c op)
    (const action)

withStore' :: AgentMonad m => AgentClient -> (DB.Connection -> IO a) -> m a
withStore' c action = withStore c $ fmap Right . action

withStore :: AgentMonad m => AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> m a
withStore c action = do
  st <- asks store
  liftEitherError storeError . agentOperationBracket c AODatabase $
    withTransaction st action `E.catch` handleInternal
  where
    handleInternal :: E.SomeException -> IO (Either StoreError a)
    handleInternal = pure . Left . SEInternal . bshow

storeError :: StoreError -> AgentErrorType
storeError = \case
  SEConnNotFound -> CONN NOT_FOUND
  SEConnDuplicate -> CONN DUPLICATE
  SEBadConnType CRcv -> CONN SIMPLEX
  SEBadConnType CSnd -> CONN SIMPLEX
  SEInvitationNotFound -> CMD PROHIBITED
  -- this error is never reported as store error,
  -- it is used to wrap agent operations when "transaction-like" store access is needed
  -- NOTE: network IO should NOT be used inside AgentStoreMonad
  SEAgentError e -> e
  e -> INTERNAL $ show e
