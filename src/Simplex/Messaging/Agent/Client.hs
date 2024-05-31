{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    ProtocolTestFailure (..),
    ProtocolTestStep (..),
    newAgentClient,
    withConnLock,
    withConnLocks,
    withInvLock,
    withLockMap,
    ipAddressProtected,
    closeAgentClient,
    closeProtocolServerClients,
    reconnectServerClients,
    closeXFTPServerClient,
    runSMPServerTest,
    runXFTPServerTest,
    runNTFServerTest,
    getXFTPWorkPath,
    newRcvQueue,
    subscribeQueues,
    getQueueMessage,
    decryptSMPMessage,
    addSubscription,
    failSubscription,
    addNewQueueSubscription,
    getSubscriptions,
    sendConfirmation,
    sendInvitation,
    temporaryAgentError,
    temporaryOrHostError,
    serverHostError,
    secureQueue,
    enableQueueNotifications,
    enableQueuesNtfs,
    disableQueueNotifications,
    disableQueuesNtfs,
    sendAgentMessage,
    getQueueInfo,
    agentNtfRegisterToken,
    agentNtfVerifyToken,
    agentNtfCheckToken,
    agentNtfReplaceToken,
    agentNtfDeleteToken,
    agentNtfEnableCron,
    agentNtfCreateSubscription,
    agentNtfCheckSubscription,
    agentNtfDeleteSubscription,
    agentXFTPDownloadChunk,
    agentXFTPNewChunk,
    agentXFTPUploadChunk,
    agentXFTPAddRecipients,
    agentXFTPDeleteChunk,
    agentCbEncrypt,
    agentCbDecrypt,
    cryptoError,
    sendAck,
    suspendQueue,
    deleteQueue,
    deleteQueues,
    logServer,
    logSecret,
    removeSubscription,
    hasActiveSubscription,
    hasPendingSubscription,
    hasGetLock,
    activeClientSession,
    agentClientStore,
    agentDRG,
    getAgentSubscriptions,
    slowNetworkConfig,
    protocolClientError,
    Worker (..),
    SessionVar (..),
    SubscriptionsInfo (..),
    SubInfo (..),
    AgentOperation (..),
    AgentOpState (..),
    AgentState (..),
    AgentLocks (..),
    AgentStatsKey (..),
    getAgentWorker,
    getAgentWorker',
    cancelWorker,
    waitForWork,
    hasWorkToDo,
    hasWorkToDo',
    withWork,
    agentOperations,
    agentOperationBracket,
    waitUntilActive,
    UserNetworkInfo (..),
    UserNetworkType (..),
    getNetworkConfig',
    waitForUserNetwork,
    isNetworkOnline,
    isOnline,
    throwWhenInactive,
    throwWhenNoDelivery,
    beginAgentOperation,
    endAgentOperation,
    waitUntilForeground,
    suspendSendingAndDatabase,
    suspendOperation,
    notifySuspended,
    whenSuspending,
    withStore,
    withStore',
    withStoreBatch,
    withStoreBatch',
    storeError,
    userServers,
    pickServer,
    getNextServer,
    withUserServers,
    withNextSrv,
    AgentWorkersDetails (..),
    getAgentWorkersDetails,
    AgentWorkersSummary (..),
    getAgentWorkersSummary,
    AgentQueuesInfo (..),
    getAgentQueuesInfo,
    SMPTransportSession,
    NtfTransportSession,
    XFTPTransportSession,
    ProxiedRelay (..),
    SMPConnectedClient (..),
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry, throwSTM)
import Control.Exception (AsyncException (..), BlockedIndefinitelyOnSTM (..))
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as J
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (partitionEithers)
import Data.Functor (($>))
import Data.List (deleteFirstsBy, foldl', partition, (\\))
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, isJust, isNothing, listToMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Word (Word16)
import qualified Database.SQLite.Simple as SQL
import Network.Socket (HostName)
import Simplex.FileTransfer.Client (XFTPChunkSpec (..), XFTPClient, XFTPClientConfig (..), XFTPClientError)
import qualified Simplex.FileTransfer.Client as X
import Simplex.FileTransfer.Description (ChunkReplicaId (..), FileDigest (..), kb)
import Simplex.FileTransfer.Protocol (FileInfo (..), FileResponse)
import Simplex.FileTransfer.Transport (XFTPErrorType (DIGEST), XFTPRcvChunkSpec (..), XFTPVersion)
import Simplex.FileTransfer.Types (DeletedSndChunkReplica (..), NewSndChunkReplica (..), RcvFileChunkReplica (..), SndFileChunk (..), SndFileChunkReplica (..))
import Simplex.FileTransfer.Util (uniqueCombine)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore (..), withTransaction)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import Simplex.Messaging.Agent.TRcvQueues (TRcvQueues (getRcvQueues))
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Transport (NTFVersion)
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON, parse, sumTypeJSON)
import Simplex.Messaging.Protocol
  ( AProtocolType (..),
    BrokerMsg,
    EntityId,
    ErrorType,
    MsgFlags (..),
    MsgId,
    NtfPublicAuthKey,
    NtfServer,
    NtfServerWithAuth,
    ProtoServer,
    ProtoServerWithAuth (..),
    Protocol (..),
    ProtocolServer (..),
    ProtocolTypeI (..),
    QueueId,
    QueueIdsKeys (..),
    RcvMessage (..),
    RcvNtfPublicDhKey,
    SMPMsgMeta (..),
    SProtocolType (..),
    SndPublicAuthKey,
    SubscriptionMode (..),
    UserProtocol,
    VersionRangeSMPC,
    VersionSMPC,
    XFTPServer,
    XFTPServerWithAuth,
    sameSrvAddr',
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.QueueStore.QueueInfo
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SMPVersion, SessionId, THandleParams (sessionId), TransportError (..))
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Mem.Weak (Weak)
import System.Random (randomR)
import UnliftIO (mapConcurrently, timeout)
import UnliftIO.Async (async)
import UnliftIO.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type ClientVar msg = SessionVar (Either (AgentErrorType, Maybe UTCTime) (Client msg))

type SMPClientVar = ClientVar SMP.BrokerMsg

type NtfClientVar = ClientVar NtfResponse

type XFTPClientVar = ClientVar FileResponse

type SMPTransportSession = TransportSession SMP.BrokerMsg

type NtfTransportSession = TransportSession NtfResponse

type XFTPTransportSession = TransportSession FileResponse

data AgentClient = AgentClient
  { acThread :: TVar (Maybe (Weak ThreadId)),
    active :: TVar Bool,
    rcvQ :: TBQueue (ATransmission 'Client),
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg),
    smpServers :: TMap UserId (NonEmpty SMPServerWithAuth),
    smpClients :: TMap SMPTransportSession SMPClientVar,
    -- smpProxiedRelays:
    -- SMPTransportSession defines connection from proxy to relay,
    -- SMPServerWithAuth defines client connected to SMP proxy (with the same userId and entityId in TransportSession)
    smpProxiedRelays :: TMap SMPTransportSession SMPServerWithAuth,
    ntfServers :: TVar [NtfServer],
    ntfClients :: TMap NtfTransportSession NtfClientVar,
    xftpServers :: TMap UserId (NonEmpty XFTPServerWithAuth),
    xftpClients :: TMap XFTPTransportSession XFTPClientVar,
    useNetworkConfig :: TVar (NetworkConfig, NetworkConfig), -- (slow, fast) networks
    userNetworkInfo :: TVar UserNetworkInfo,
    userNetworkUpdated :: TVar (Maybe UTCTime),
    subscrConns :: TVar (Set ConnId),
    activeSubs :: TRcvQueues,
    pendingSubs :: TRcvQueues,
    removedSubs :: TMap (UserId, SMPServer, SMP.RecipientId) SMPClientError,
    workerSeq :: TVar Int,
    smpDeliveryWorkers :: TMap SndQAddr (Worker, TMVar ()),
    asyncCmdWorkers :: TMap (Maybe SMPServer) Worker,
    connCmdsQueued :: TMap ConnId Bool,
    ntfNetworkOp :: TVar AgentOpState,
    rcvNetworkOp :: TVar AgentOpState,
    msgDeliveryOp :: TVar AgentOpState,
    sndNetworkOp :: TVar AgentOpState,
    databaseOp :: TVar AgentOpState,
    agentState :: TVar AgentState,
    getMsgLocks :: TMap (SMPServer, SMP.RecipientId) (TMVar ()),
    -- locks to prevent concurrent operations with connection
    connLocks :: TMap ConnId Lock,
    -- locks to prevent concurrent operations with connection request invitations
    invLocks :: TMap ByteString Lock,
    -- lock to prevent concurrency between periodic and async connection deletions
    deleteLock :: Lock,
    -- smpSubWorkers for SMP servers sessions
    smpSubWorkers :: TMap SMPTransportSession (SessionVar (Async ())),
    agentStats :: TMap AgentStatsKey (TVar Int),
    msgCounts :: TMap ConnId (TVar (Int, Int)), -- (total, duplicates)
    clientId :: Int,
    agentEnv :: Env
  }

data SMPConnectedClient = SMPConnectedClient
  { connectedClient :: SMPClient,
    proxiedRelays :: TMap SMPServer ProxiedRelayVar
  }

type ProxiedRelayVar = SessionVar (Either AgentErrorType ProxiedRelay)

getAgentWorker :: (Ord k, Show k) => String -> Bool -> AgentClient -> k -> TMap k Worker -> (Worker -> AM ()) -> AM' Worker
getAgentWorker = getAgentWorker' id pure
{-# INLINE getAgentWorker #-}

getAgentWorker' :: forall a k. (Ord k, Show k) => (a -> Worker) -> (Worker -> STM a) -> String -> Bool -> AgentClient -> k -> TMap k a -> (a -> AM ()) -> AM' a
getAgentWorker' toW fromW name hasWork c key ws work = do
  atomically (getWorker >>= maybe createWorker whenExists) >>= \w -> runWorker w $> w
  where
    getWorker = TM.lookup key ws
    createWorker = do
      w <- fromW =<< newWorker c
      TM.insert key w ws
      pure w
    whenExists w
      | hasWork = hasWorkToDo (toW w) $> w
      | otherwise = pure w
    runWorker w = runWorkerAsync (toW w) runWork
      where
        runWork :: AM' ()
        runWork = tryAgentError' (work w) >>= restartOrDelete
        restartOrDelete :: Either AgentErrorType () -> AM' ()
        restartOrDelete e_ = do
          t <- liftIO getSystemTime
          maxRestarts <- asks $ maxWorkerRestartsPerMin . config
          -- worker may terminate because it was deleted from the map (getWorker returns Nothing), then it won't restart
          restart <- atomically $ getWorker >>= maybe (pure False) (shouldRestart e_ (toW w) t maxRestarts)
          when restart runWork
        shouldRestart e_ Worker {workerId = wId, doWork, action, restarts} t maxRestarts w'
          | wId == workerId (toW w') =
              checkRestarts . updateRestartCount t =<< readTVar restarts
          | otherwise =
              pure False -- there is a new worker in the map, no action
          where
            checkRestarts rc
              | restartCount rc < maxRestarts = do
                  writeTVar restarts rc
                  hasWorkToDo' doWork
                  void $ tryPutTMVar action Nothing
                  notifyErr INTERNAL
                  pure True
              | otherwise = do
                  TM.delete key ws
                  notifyErr $ CRITICAL True
                  pure False
              where
                notifyErr err = do
                  let e = either ((", error: " <>) . show) (\_ -> ", no error") e_
                      msg = "Worker " <> name <> " for " <> show key <> " terminated " <> show (restartCount rc) <> " times" <> e
                  writeTBQueue (subQ c) ("", "", APC SAEConn $ ERR $ err msg)

newWorker :: AgentClient -> STM Worker
newWorker c = do
  workerId <- stateTVar (workerSeq c) $ \next -> (next, next + 1)
  doWork <- newTMVar ()
  action <- newTMVar Nothing
  restarts <- newTVar $ RestartCount 0 0
  pure Worker {workerId, doWork, action, restarts}

runWorkerAsync :: Worker -> AM' () -> AM' ()
runWorkerAsync Worker {action} work =
  E.bracket
    (atomically $ takeTMVar action) -- get current action, locking to avoid race conditions
    (atomically . tryPutTMVar action) -- if it was running (or if start crashes), put it back and unlock (don't lock if it was just started)
    (\a -> when (isNothing a) start) -- start worker if it's not running
  where
    start = atomically . putTMVar action . Just =<< async work

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

data AgentOpState = AgentOpState {opSuspended :: !Bool, opsInProgress :: !Int}

data AgentState = ASForeground | ASSuspending | ASSuspended
  deriving (Eq, Show)

data AgentLocks = AgentLocks
  { connLocks :: Map String String,
    invLocks :: Map String String,
    delLock :: Maybe String
  }
  deriving (Show)

data AgentStatsKey = AgentStatsKey
  { userId :: UserId,
    host :: ByteString,
    clientTs :: ByteString,
    cmd :: ByteString,
    res :: ByteString
  }
  deriving (Eq, Ord, Show)

data UserNetworkInfo = UserNetworkInfo
  { networkType :: UserNetworkType,
    online :: Bool
  }
  deriving (Show)

isNetworkOnline :: AgentClient -> STM Bool
isNetworkOnline c = isOnline <$> readTVar (userNetworkInfo c)

isOnline :: UserNetworkInfo -> Bool
isOnline UserNetworkInfo {networkType, online} = networkType /= UNNone && online

data UserNetworkType = UNNone | UNCellular | UNWifi | UNEthernet | UNOther
  deriving (Eq, Show)

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
newAgentClient :: Int -> InitialAgentServers -> Env -> STM AgentClient
newAgentClient clientId InitialAgentServers {smp, ntf, xftp, netCfg} agentEnv = do
  let cfg = config agentEnv
      qSize = tbqSize cfg
  acThread <- newTVar Nothing
  active <- newTVar True
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpServers <- newTVar smp
  smpClients <- TM.empty
  smpProxiedRelays <- TM.empty
  ntfServers <- newTVar ntf
  ntfClients <- TM.empty
  xftpServers <- newTVar xftp
  xftpClients <- TM.empty
  useNetworkConfig <- newTVar (slowNetworkConfig netCfg, netCfg)
  userNetworkInfo <- newTVar $ UserNetworkInfo UNOther True
  userNetworkUpdated <- newTVar Nothing
  subscrConns <- newTVar S.empty
  activeSubs <- RQ.empty
  pendingSubs <- RQ.empty
  removedSubs <- TM.empty
  workerSeq <- newTVar 0
  smpDeliveryWorkers <- TM.empty
  asyncCmdWorkers <- TM.empty
  connCmdsQueued <- TM.empty
  ntfNetworkOp <- newTVar $ AgentOpState False 0
  rcvNetworkOp <- newTVar $ AgentOpState False 0
  msgDeliveryOp <- newTVar $ AgentOpState False 0
  sndNetworkOp <- newTVar $ AgentOpState False 0
  databaseOp <- newTVar $ AgentOpState False 0
  agentState <- newTVar ASForeground
  getMsgLocks <- TM.empty
  connLocks <- TM.empty
  invLocks <- TM.empty
  deleteLock <- createLock
  smpSubWorkers <- TM.empty
  agentStats <- TM.empty
  msgCounts <- TM.empty
  return
    AgentClient
      { acThread,
        active,
        rcvQ,
        subQ,
        msgQ,
        smpServers,
        smpClients,
        smpProxiedRelays,
        ntfServers,
        ntfClients,
        xftpServers,
        xftpClients,
        useNetworkConfig,
        userNetworkInfo,
        userNetworkUpdated,
        subscrConns,
        activeSubs,
        pendingSubs,
        removedSubs,
        workerSeq,
        smpDeliveryWorkers,
        asyncCmdWorkers,
        connCmdsQueued,
        ntfNetworkOp,
        rcvNetworkOp,
        msgDeliveryOp,
        sndNetworkOp,
        databaseOp,
        agentState,
        getMsgLocks,
        connLocks,
        invLocks,
        deleteLock,
        smpSubWorkers,
        agentStats,
        msgCounts,
        clientId,
        agentEnv
      }

slowNetworkConfig :: NetworkConfig -> NetworkConfig
slowNetworkConfig cfg@NetworkConfig {tcpConnectTimeout, tcpTimeout, tcpTimeoutPerKb} =
  cfg {tcpConnectTimeout = slow tcpConnectTimeout, tcpTimeout = slow tcpTimeout, tcpTimeoutPerKb = slow tcpTimeoutPerKb}
  where
    slow :: Integral a => a -> a
    slow t = (t * 3) `div` 2

agentClientStore :: AgentClient -> SQLiteStore
agentClientStore AgentClient {agentEnv = Env {store}} = store
{-# INLINE agentClientStore #-}

agentDRG :: AgentClient -> TVar ChaChaDRG
agentDRG AgentClient {agentEnv = Env {random}} = random
{-# INLINE agentDRG #-}

class (Encoding err, Show err) => ProtocolServerClient v err msg | msg -> v, msg -> err where
  type Client msg = c | c -> msg
  getProtocolServerClient :: AgentClient -> TransportSession msg -> AM (Client msg)
  type ProtoClient msg = c | c -> msg
  protocolClient :: Client msg -> ProtoClient msg
  clientProtocolError :: HostName -> err -> AgentErrorType
  closeProtocolServerClient :: ProtoClient msg -> IO ()
  clientServer :: ProtoClient msg -> String
  clientTransportHost :: ProtoClient msg -> TransportHost
  clientSessionTs :: ProtoClient msg -> UTCTime

instance ProtocolServerClient SMPVersion ErrorType BrokerMsg where
  type Client BrokerMsg = SMPConnectedClient
  getProtocolServerClient = getSMPServerClient
  type ProtoClient BrokerMsg = ProtocolClient SMPVersion ErrorType BrokerMsg
  protocolClient = connectedClient
  clientProtocolError = SMP
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'
  clientSessionTs = sessionTs

instance ProtocolServerClient NTFVersion ErrorType NtfResponse where
  type Client NtfResponse = ProtocolClient NTFVersion ErrorType NtfResponse
  getProtocolServerClient = getNtfServerClient
  type ProtoClient NtfResponse = ProtocolClient NTFVersion ErrorType NtfResponse
  protocolClient = id
  clientProtocolError = NTF
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'
  clientSessionTs = sessionTs

instance ProtocolServerClient XFTPVersion XFTPErrorType FileResponse where
  type Client FileResponse = XFTPClient
  getProtocolServerClient = getXFTPServerClient
  type ProtoClient FileResponse = XFTPClient
  protocolClient = id
  clientProtocolError = XFTP
  closeProtocolServerClient = X.closeXFTPClient
  clientServer = X.xftpClientServer
  clientTransportHost = X.xftpTransportHost
  clientSessionTs = X.xftpSessionTs

getSMPServerClient :: AgentClient -> SMPTransportSession -> AM SMPConnectedClient
getSMPServerClient c@AgentClient {active, smpClients, workerSeq} tSess = do
  unlessM (readTVarIO active) . throwError $ INACTIVE
  ts <- liftIO getCurrentTime
  atomically (getSessVar workerSeq tSess smpClients ts)
    >>= either newClient (waitForProtocolClient c tSess smpClients)
  where
    newClient v = do
      prs <- atomically TM.empty
      smpConnectClient c tSess prs v

getSMPProxyClient :: AgentClient -> SMPTransportSession -> AM (SMPConnectedClient, Either AgentErrorType ProxiedRelay)
getSMPProxyClient c@AgentClient {active, smpClients, smpProxiedRelays, workerSeq} destSess@(userId, destSrv, qId) = do
  unlessM (readTVarIO active) . throwError $ INACTIVE
  proxySrv <- getNextServer c userId [destSrv]
  ts <- liftIO getCurrentTime
  atomically (getClientVar proxySrv ts) >>= \(tSess, auth, v) ->
    either (newProxyClient tSess auth ts) (waitForProxyClient tSess auth) v
  where
    getClientVar :: SMPServerWithAuth -> UTCTime -> STM (SMPTransportSession, Maybe SMP.BasicAuth, Either SMPClientVar SMPClientVar)
    getClientVar proxySrv ts = do
      ProtoServerWithAuth srv auth <- TM.lookup destSess smpProxiedRelays >>= maybe (TM.insert destSess proxySrv smpProxiedRelays $> proxySrv) pure
      let tSess = (userId, srv, qId)
      (tSess,auth,) <$> getSessVar workerSeq tSess smpClients ts
    newProxyClient :: SMPTransportSession -> Maybe SMP.BasicAuth -> UTCTime -> SMPClientVar -> AM (SMPConnectedClient, Either AgentErrorType ProxiedRelay)
    newProxyClient tSess auth ts v = do
      (prs, rv) <- atomically $ do
        prs <- TM.empty
        -- we do not need to check if it is a new proxied relay session,
        -- as the client is just created and there are no sessions yet
        (prs,) . either id id <$> getSessVar workerSeq destSrv prs ts
      clnt <- smpConnectClient c tSess prs v
      (clnt,) <$> newProxiedRelay clnt auth rv
    waitForProxyClient :: SMPTransportSession -> Maybe SMP.BasicAuth -> SMPClientVar -> AM (SMPConnectedClient, Either AgentErrorType ProxiedRelay)
    waitForProxyClient tSess auth v = do
      clnt@(SMPConnectedClient _ prs) <- waitForProtocolClient c tSess smpClients v
      ts <- liftIO getCurrentTime
      sess <-
        atomically (getSessVar workerSeq destSrv prs ts)
          >>= either (newProxiedRelay clnt auth) (waitForProxiedRelay tSess)
      pure (clnt, sess)
    newProxiedRelay :: SMPConnectedClient -> Maybe SMP.BasicAuth -> ProxiedRelayVar -> AM (Either AgentErrorType ProxiedRelay)
    newProxiedRelay clnt@(SMPConnectedClient smp prs) proxyAuth rv =
      tryAgentError (liftClient SMP (clientServer smp) $ connectSMPProxiedRelay smp destSrv proxyAuth) >>= \case
        Right sess -> do
          atomically $ putTMVar (sessionVar rv) (Right sess)
          liftIO $ incClientStat c userId clnt "PROXY" "OK"
          pure $ Right sess
        Left e -> do
          liftIO $ incClientStat c userId clnt "PROXY" $ strEncode e
          atomically $ do
            unless (serverHostError e) $ do
              removeSessVar rv destSrv prs
              TM.delete destSess smpProxiedRelays
            putTMVar (sessionVar rv) (Left e)
            pure $ Left e
    waitForProxiedRelay :: SMPTransportSession -> ProxiedRelayVar -> AM (Either AgentErrorType ProxiedRelay)
    waitForProxiedRelay (_, srv, _) rv = do
      NetworkConfig {tcpConnectTimeout} <- atomically $ getNetworkConfig c
      sess_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar rv)
      pure $ case sess_ of
        Just (Right sess) -> Right sess
        Just (Left e) -> Left e
        Nothing -> Left $ BROKER (B.unpack $ strEncode srv) TIMEOUT

smpConnectClient :: AgentClient -> SMPTransportSession -> TMap SMPServer ProxiedRelayVar -> SMPClientVar -> AM SMPConnectedClient
smpConnectClient c@AgentClient {smpClients, msgQ} tSess@(_, srv, _) prs v =
  newProtocolClient c tSess smpClients connectClient v
    `catchAgentError` \e -> lift (resubscribeSMPSession c tSess) >> throwError e
  where
    connectClient :: SMPClientVar -> AM SMPConnectedClient
    connectClient v' = do
      cfg <- lift $ getClientConfig c smpCfg
      g <- asks random
      env <- ask
      liftError (protocolClientError SMP $ B.unpack $ strEncode srv) $ do
        smp <- ExceptT $ getProtocolClient g tSess cfg (Just msgQ) $ smpClientDisconnected c tSess env v' prs
        pure SMPConnectedClient {connectedClient = smp, proxiedRelays = prs}

smpClientDisconnected :: AgentClient -> SMPTransportSession -> Env -> SMPClientVar -> TMap SMPServer ProxiedRelayVar -> SMPClient -> IO ()
smpClientDisconnected c@AgentClient {active, smpClients, smpProxiedRelays} tSess@(userId, srv, qId) env v prs client = do
  removeClientAndSubs >>= serverDown
  logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv
  where
    -- we make active subscriptions pending only if the client for tSess was current (in the map) and active,
    -- because we can have a race condition when a new current client could have already
    -- made subscriptions active, and the old client would be processing diconnection later.
    removeClientAndSubs :: IO ([RcvQueue], [ConnId])
    removeClientAndSubs = atomically $ ifM currentActiveClient removeSubs $ pure ([], [])
      where
        currentActiveClient = (&&) <$> removeSessVar' v tSess smpClients <*> readTVar active
        removeSubs = do
          (qs, cs) <- RQ.getDelSessQueues tSess $ activeSubs c
          RQ.batchAddQueues (pendingSubs c) qs
          -- this removes proxied relays that this client created sessions to
          destSrvs <- M.keys <$> readTVar prs
          forM_ destSrvs $ \destSrv -> TM.delete (userId, destSrv, qId) smpProxiedRelays
          pure (qs, cs)

    serverDown :: ([RcvQueue], [ConnId]) -> IO ()
    serverDown (qs, conns) = whenM (readTVarIO active) $ do
      incClientStat' c userId client "DISCONNECT" ""
      notifySub c "" $ hostEvent' DISCONNECT client
      unless (null conns) $ notifySub c "" $ DOWN srv conns
      unless (null qs) $ do
        atomically $ mapM_ (releaseGetLock c) qs
        runReaderT (resubscribeSMPSession c tSess) env

notifySub :: forall e m. (AEntityI e, MonadIO m) => AgentClient -> ConnId -> ACommand 'Agent e -> m ()
notifySub c connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, APC (sAEntity @e) cmd)

resubscribeSMPSession :: AgentClient -> SMPTransportSession -> AM' ()
resubscribeSMPSession c@AgentClient {smpSubWorkers, workerSeq} tSess = do
  ts <- liftIO getCurrentTime
  atomically (getWorkerVar ts) >>= mapM_ (either newSubWorker (\_ -> pure ()))
  where
    getWorkerVar ts =
      ifM
        (null <$> getPending)
        (pure Nothing) -- prevent race with cleanup and adding pending queues in another call
        (Just <$> getSessVar workerSeq tSess smpSubWorkers ts)
    newSubWorker v = do
      a <- async $ void (E.tryAny runSubWorker) >> atomically (cleanup v)
      atomically $ putTMVar (sessionVar v) a
    runSubWorker = do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \_ loop -> do
        pending <- atomically getPending
        forM_ (L.nonEmpty pending) $ \qs -> do
          liftIO $ waitForUserNetwork c
          reconnectSMPClient c tSess qs
          loop
    getPending = RQ.getSessQueues tSess $ pendingSubs c
    cleanup :: SessionVar (Async ()) -> STM ()
    cleanup v = do
      -- Here we wait until TMVar is not empty to prevent worker cleanup happening before worker is added to TMVar.
      -- Not waiting may result in terminated worker remaining in the map.
      whenM (isEmptyTMVar $ sessionVar v) retry
      removeSessVar v tSess smpSubWorkers

reconnectSMPClient :: AgentClient -> SMPTransportSession -> NonEmpty RcvQueue -> AM' ()
reconnectSMPClient c tSess qs = handleNotify $ do
  cs <- readTVarIO $ RQ.getConnections $ activeSubs c
  (rs, sessId_) <- subscribeQueues c $ L.toList qs
  let (errs, okConns) = partitionEithers $ map (\(RcvQueue {connId}, r) -> bimap (connId,) (const connId) r) rs
  let (tempErrs, finalErrs) = partition (temporaryAgentError . snd) errs
  mapM_ (\(connId, e) -> notifySub c connId $ ERR e) finalErrs
  forM_ (listToMaybe tempErrs) $ \(connId, e) -> do
    when (null okConns && M.null cs && null finalErrs) . liftIO $
      forM_ sessId_ $ \sessId -> do
        -- We only close the client session that was used to subscribe.
        v_ <- atomically $ ifM (activeClientSession c tSess sessId) (TM.lookupDelete tSess $ smpClients c) (pure Nothing)
        mapM_ (closeClient_ c) v_
    notifySub c connId $ ERR e
  where
    handleNotify :: AM' () -> AM' ()
    handleNotify = E.handleAny $ notifySub c "" . ERR . INTERNAL . show

getNtfServerClient :: AgentClient -> NtfTransportSession -> AM NtfClient
getNtfServerClient c@AgentClient {active, ntfClients, workerSeq} tSess@(userId, srv, _) = do
  unlessM (readTVarIO active) . throwError $ INACTIVE
  ts <- liftIO getCurrentTime
  atomically (getSessVar workerSeq tSess ntfClients ts)
    >>= either
      (newProtocolClient c tSess ntfClients connectClient)
      (waitForProtocolClient c tSess ntfClients)
  where
    connectClient :: NtfClientVar -> AM NtfClient
    connectClient v = do
      cfg <- lift $ getClientConfig c ntfCfg
      g <- asks random
      liftError' (protocolClientError NTF $ B.unpack $ strEncode srv) $
        getProtocolClient g tSess cfg Nothing $
          clientDisconnected v

    clientDisconnected :: NtfClientVar -> NtfClient -> IO ()
    clientDisconnected v client = do
      atomically $ removeSessVar v tSess ntfClients
      incClientStat c userId client "DISCONNECT" ""
      atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getXFTPServerClient :: AgentClient -> XFTPTransportSession -> AM XFTPClient
getXFTPServerClient c@AgentClient {active, xftpClients, workerSeq} tSess@(userId, srv, _) = do
  unlessM (readTVarIO active) . throwError $ INACTIVE
  ts <- liftIO getCurrentTime
  atomically (getSessVar workerSeq tSess xftpClients ts)
    >>= either
      (newProtocolClient c tSess xftpClients connectClient)
      (waitForProtocolClient c tSess xftpClients)
  where
    connectClient :: XFTPClientVar -> AM XFTPClient
    connectClient v = do
      cfg <- asks $ xftpCfg . config
      xftpNetworkConfig <- atomically $ getNetworkConfig c
      liftError' (protocolClientError XFTP $ B.unpack $ strEncode srv) $
        X.getXFTPClient tSess cfg {xftpNetworkConfig} $
          clientDisconnected v

    clientDisconnected :: XFTPClientVar -> XFTPClient -> IO ()
    clientDisconnected v client = do
      atomically $ removeSessVar v tSess xftpClients
      incClientStat c userId client "DISCONNECT" ""
      atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

waitForProtocolClient ::
  (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) =>
  AgentClient ->
  TransportSession msg ->
  TMap (TransportSession msg) (ClientVar msg) ->
  ClientVar msg ->
  AM (Client msg)
waitForProtocolClient c tSess@(_, srv, _) clients v = do
  NetworkConfig {tcpConnectTimeout} <- atomically $ getNetworkConfig c
  client_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar v)
  case client_ of
    Just (Right smpClient) -> pure smpClient
    Just (Left (e, ts_)) -> case ts_ of
      Nothing -> throwE e
      Just ts ->
        ifM
          ((ts <) <$> liftIO getCurrentTime)
          (atomically (removeSessVar v tSess clients) >> getProtocolServerClient c tSess)
          (throwE e)
    Nothing -> throwE $ BROKER (B.unpack $ strEncode srv) TIMEOUT

-- clientConnected arg is only passed for SMP server
newProtocolClient ::
  forall v err msg.
  (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) =>
  AgentClient ->
  TransportSession msg ->
  TMap (TransportSession msg) (ClientVar msg) ->
  (ClientVar msg -> AM (Client msg)) ->
  ClientVar msg ->
  AM (Client msg)
newProtocolClient c tSess@(userId, srv, entityId_) clients connectClient v =
  tryAgentError (connectClient v) >>= \case
    Right client -> do
      logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv <> " (user " <> bshow userId <> maybe "" (" for entity " <>) entityId_ <> ")"
      atomically $ putTMVar (sessionVar v) (Right client)
      liftIO $ incClientStat c userId client "CLIENT" "OK"
      atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent CONNECT client)
      pure client
    Left e -> do
      liftIO $ incServerStat c userId srv "CLIENT" $ strEncode e
      ei <- asks $ persistErrorInterval . config
      if ei == 0
        then atomically $ do
          removeSessVar v tSess clients
          putTMVar (sessionVar v) (Left (e, Nothing))
        else do
          ts <- addUTCTime ei <$> liftIO getCurrentTime
          atomically $ putTMVar (sessionVar v) (Left (e, Just ts))
      throwE e -- signal error to caller

hostEvent :: forall v err msg. (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) => (AProtocolType -> TransportHost -> ACommand 'Agent 'AENone) -> Client msg -> ACommand 'Agent 'AENone
hostEvent event = hostEvent' event . protocolClient
{-# INLINE hostEvent #-}

hostEvent' :: forall v err msg. (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) => (AProtocolType -> TransportHost -> ACommand 'Agent 'AENone) -> ProtoClient msg -> ACommand 'Agent 'AENone
hostEvent' event = event (AProtocolType $ protocolTypeI @(ProtoType msg)) . clientTransportHost

getClientConfig :: AgentClient -> (AgentConfig -> ProtocolClientConfig v) -> AM' (ProtocolClientConfig v)
getClientConfig c cfgSel = do
  cfg <- asks $ cfgSel . config
  networkConfig <- atomically $ getNetworkConfig c
  pure cfg {networkConfig}

getNetworkConfig :: AgentClient -> STM NetworkConfig
getNetworkConfig c = do
  (slowCfg, fastCfg) <- readTVar (useNetworkConfig c)
  UserNetworkInfo {networkType} <- readTVar $ userNetworkInfo c
  pure $ case networkType of
    UNCellular -> slowCfg
    UNNone -> slowCfg
    _ -> fastCfg

-- returns fast network config
getNetworkConfig' :: AgentClient -> IO NetworkConfig
getNetworkConfig' = fmap snd . readTVarIO . useNetworkConfig
{-# INLINE getNetworkConfig' #-}

waitForUserNetwork :: AgentClient -> IO ()
waitForUserNetwork c =
  unlessM (atomically $ isNetworkOnline c) $ do
    delay <- registerDelay $ userNetworkInterval $ config $ agentEnv c
    atomically $ unlessM (isNetworkOnline c) $ unlessM (readTVar delay) retry

closeAgentClient :: AgentClient -> IO ()
closeAgentClient c = do
  atomically $ writeTVar (active c) False
  closeProtocolServerClients c smpClients
  closeProtocolServerClients c ntfClients
  closeProtocolServerClients c xftpClients
  atomically $ writeTVar (smpProxiedRelays c) M.empty
  atomically (swapTVar (smpSubWorkers c) M.empty) >>= mapM_ cancelReconnect
  clearWorkers smpDeliveryWorkers >>= mapM_ (cancelWorker . fst)
  clearWorkers asyncCmdWorkers >>= mapM_ cancelWorker
  clear connCmdsQueued
  atomically . RQ.clear $ activeSubs c
  atomically . RQ.clear $ pendingSubs c
  clear subscrConns
  clear getMsgLocks
  where
    clearWorkers :: Ord k => (AgentClient -> TMap k a) -> IO (Map k a)
    clearWorkers workers = atomically $ swapTVar (workers c) mempty
    clear :: Monoid m => (AgentClient -> TVar m) -> IO ()
    clear sel = atomically $ writeTVar (sel c) mempty
    cancelReconnect :: SessionVar (Async ()) -> IO ()
    cancelReconnect v = void . forkIO $ atomically (readTMVar $ sessionVar v) >>= uninterruptibleCancel

cancelWorker :: Worker -> IO ()
cancelWorker Worker {doWork, action} = do
  noWorkToDo doWork
  atomically (tryTakeTMVar action) >>= mapM_ (mapM_ uninterruptibleCancel)

waitUntilActive :: AgentClient -> STM ()
waitUntilActive c = unlessM (readTVar $ active c) retry
{-# INLINE waitUntilActive #-}

throwWhenInactive :: AgentClient -> STM ()
throwWhenInactive c = unlessM (readTVar $ active c) $ throwSTM ThreadKilled
{-# INLINE throwWhenInactive #-}

-- this function is used to remove workers once delivery is complete, not when it is removed from the map
throwWhenNoDelivery :: AgentClient -> SndQueue -> STM ()
throwWhenNoDelivery c sq =
  unlessM (TM.member (qAddress sq) $ smpDeliveryWorkers c) $
    throwSTM ThreadKilled

closeProtocolServerClients :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> IO ()
closeProtocolServerClients c clientsSel =
  atomically (clientsSel c `swapTVar` M.empty) >>= mapM_ (forkIO . closeClient_ c)

reconnectServerClients :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> IO ()
reconnectServerClients c clientsSel =
  readTVarIO (clientsSel c) >>= mapM_ (forkIO . closeClient_ c)

closeClient :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> TransportSession msg -> IO ()
closeClient c clientSel tSess =
  atomically (TM.lookupDelete tSess $ clientSel c) >>= mapM_ (closeClient_ c)

closeClient_ :: ProtocolServerClient v err msg => AgentClient -> ClientVar msg -> IO ()
closeClient_ c v = do
  NetworkConfig {tcpConnectTimeout} <- atomically $ getNetworkConfig c
  E.handle (\BlockedIndefinitelyOnSTM -> pure ()) $
    tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar v) >>= \case
      Just (Right client) -> closeProtocolServerClient (protocolClient client) `catchAll_` pure ()
      _ -> pure ()

closeXFTPServerClient :: AgentClient -> UserId -> XFTPServer -> FileDigest -> IO ()
closeXFTPServerClient c userId server (FileDigest chunkDigest) =
  mkTransportSession c userId server chunkDigest >>= closeClient c xftpClients

withConnLock :: AgentClient -> ConnId -> String -> AM a -> AM a
withConnLock c connId name = ExceptT . withConnLock' c connId name . runExceptT
{-# INLINE withConnLock #-}

withConnLock' :: AgentClient -> ConnId -> String -> AM' a -> AM' a
withConnLock' _ "" _ = id
withConnLock' AgentClient {connLocks} connId name = withLockMap connLocks connId name
{-# INLINE withConnLock' #-}

withInvLock :: AgentClient -> ByteString -> String -> AM a -> AM a
withInvLock c key name = ExceptT . withInvLock' c key name . runExceptT
{-# INLINE withInvLock #-}

withInvLock' :: AgentClient -> ByteString -> String -> AM' a -> AM' a
withInvLock' AgentClient {invLocks} = withLockMap invLocks
{-# INLINE withInvLock' #-}

withConnLocks :: AgentClient -> Set ConnId -> String -> AM' a -> AM' a
withConnLocks AgentClient {connLocks} = withLocksMap_ connLocks
{-# INLINE withConnLocks #-}

withLockMap :: (Ord k, MonadUnliftIO m) => TMap k Lock -> k -> String -> m a -> m a
withLockMap = withGetLock . getMapLock
{-# INLINE withLockMap #-}

withLocksMap_ :: (Ord k, MonadUnliftIO m) => TMap k Lock -> Set k -> String -> m a -> m a
withLocksMap_ = withGetLocks . getMapLock
{-# INLINE withLocksMap_ #-}

getMapLock :: Ord k => TMap k Lock -> k -> STM Lock
getMapLock locks key = TM.lookup key locks >>= maybe newLock pure
  where
    newLock = createLock >>= \l -> TM.insert key l locks $> l

withClient_ :: forall a v err msg. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> ByteString -> (Client msg -> AM a) -> AM a
withClient_ c tSess@(userId, srv, _) statCmd action = do
  cl <- getProtocolServerClient c tSess
  (action cl <* stat cl "OK") `catchAgentError` logServerError cl
  where
    stat cl = liftIO . incClientStat c userId cl statCmd
    logServerError :: Client msg -> AgentErrorType -> AM a
    logServerError cl e = do
      logServer "<--" c srv "" $ strEncode e
      stat cl $ strEncode e
      throwError e

withProxySession :: AgentClient -> SMPTransportSession -> SMP.SenderId -> ByteString -> ((SMPConnectedClient, ProxiedRelay) -> AM a) -> AM a
withProxySession c destSess@(userId, destSrv, _) entId cmdStr action = do
  (cl, sess_) <- getSMPProxyClient c destSess
  logServer ("--> " <> proxySrv cl <> " >") c destSrv entId cmdStr
  case sess_ of
    Right sess -> do
      r <- (action (cl, sess) <* stat cl "OK") `catchAgentError` logServerError cl
      logServer ("<-- " <> proxySrv cl <> " <") c destSrv entId "OK"
      pure r
    Left e -> logServerError cl e
  where
    stat cl = liftIO . incClientStat c userId cl cmdStr
    proxySrv = showServer . protocolClientServer' . protocolClient
    logServerError :: SMPConnectedClient -> AgentErrorType -> AM a
    logServerError cl e = do
      logServer ("<-- " <> proxySrv cl <> " <") c destSrv "" $ strEncode e
      stat cl $ strEncode e
      throwError e

withLogClient_ :: ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> EntityId -> ByteString -> (Client msg -> AM a) -> AM a
withLogClient_ c tSess@(_, srv, _) entId cmdStr action = do
  logServer "-->" c srv entId cmdStr
  res <- withClient_ c tSess cmdStr action
  logServer "<--" c srv entId "OK"
  return res

withClient :: forall v err msg a. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> ByteString -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> AM a
withClient c tSess statKey action = withClient_ c tSess statKey $ \client -> liftClient (clientProtocolError @v @err @msg) (clientServer $ protocolClient client) $ action client
{-# INLINE withClient #-}

withLogClient :: forall v err msg a. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> EntityId -> ByteString -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> AM a
withLogClient c tSess entId cmdStr action = withLogClient_ c tSess entId cmdStr $ \client -> liftClient (clientProtocolError @v @err @msg) (clientServer $ protocolClient client) $ action client
{-# INLINE withLogClient #-}

withSMPClient :: SMPQueueRec q => AgentClient -> q -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> AM a
withSMPClient c q cmdStr action = do
  tSess <- liftIO $ mkSMPTransportSession c q
  withLogClient c tSess (queueId q) cmdStr $ action . connectedClient

sendOrProxySMPMessage :: AgentClient -> UserId -> SMPServer -> ByteString -> Maybe SMP.SndPrivateAuthKey -> SMP.SenderId -> MsgFlags -> SMP.MsgBody -> AM (Maybe SMPServer)
sendOrProxySMPMessage c userId destSrv cmdStr spKey_ senderId msgFlags msg = do
  sess <- liftIO $ mkTransportSession c userId destSrv senderId
  ifM (atomically shouldUseProxy) (sendViaProxy sess) (sendDirectly sess $> Nothing)
  where
    shouldUseProxy = do
      cfg <- getNetworkConfig c
      case smpProxyMode cfg of
        SPMAlways -> pure True
        SPMUnknown -> unknownServer
        SPMUnprotected
          | ipAddressProtected cfg destSrv -> pure False
          | otherwise -> unknownServer
        SPMNever -> pure False
    directAllowed = do
      cfg <- getNetworkConfig c
      pure $ case smpProxyFallback cfg of
        SPFAllow -> True
        SPFAllowProtected -> ipAddressProtected cfg destSrv
        SPFProhibit -> False
    unknownServer = maybe True (all ((destSrv /=) . protoServer)) <$> TM.lookup userId (userServers c)
    sendViaProxy destSess@(_, _, qId) = do
      r <- tryAgentError . withProxySession c destSess senderId ("PFWD " <> cmdStr) $ \(SMPConnectedClient smp _, proxySess) -> do
        liftClient SMP (clientServer smp) (proxySMPMessage smp proxySess spKey_ senderId msgFlags msg) >>= \case
          Right () -> pure . Just $ protocolClientServer' smp
          Left proxyErr -> do
            case proxyErr of
              (ProxyProtocolError (SMP.PROXY SMP.NO_SESSION)) -> atomically deleteRelaySession
              _ -> pure ()
            throwE
              PROXY
                { proxyServer = protocolClientServer smp,
                  relayServer = B.unpack $ strEncode destSrv,
                  proxyErr
                }
            where
              -- checks that the current proxied relay session is the same one that was used to send the message and removes it
              deleteRelaySession =
                ( TM.lookup destSess (smpProxiedRelays c)
                    $>>= \(ProtoServerWithAuth srv _) -> tryReadSessVar (userId, srv, qId) (smpClients c)
                )
                  >>= \case
                    Just (Right (SMPConnectedClient smp' prs))
                      | sameClient smp' ->
                          tryReadSessVar destSrv prs >>= \case
                            Just (Right proxySess') | sameProxiedRelay proxySess' -> TM.delete destSrv prs
                            _ -> pure ()
                    _ -> pure ()
              sameClient smp' = sessionId (thParams smp) == sessionId (thParams smp')
              sameProxiedRelay proxySess' = prSessionId proxySess == prSessionId proxySess'
      case r of
        Right r' -> pure r'
        Left e
          | serverHostError e -> ifM (atomically directAllowed) (sendDirectly destSess $> Nothing) (throwE e)
          | otherwise -> throwE e
    sendDirectly tSess =
      withLogClient_ c tSess senderId ("SEND " <> cmdStr) $ \(SMPConnectedClient smp _) ->
        liftClient SMP (clientServer smp) $ sendSMPMessage smp spKey_ senderId msgFlags msg

ipAddressProtected :: NetworkConfig -> ProtocolServer p -> Bool
ipAddressProtected NetworkConfig {socksProxy, hostMode} (ProtocolServer _ hosts _ _) = do
  isJust socksProxy || (hostMode == HMOnion && any isOnionHost hosts)
  where
    isOnionHost = \case THOnionHost _ -> True; _ -> False

withNtfClient :: AgentClient -> NtfServer -> EntityId -> ByteString -> (NtfClient -> ExceptT NtfClientError IO a) -> AM a
withNtfClient c srv = withLogClient c (0, srv, Nothing)

withXFTPClient ::
  ProtocolServerClient v err msg =>
  AgentClient ->
  (UserId, ProtoServer msg, EntityId) ->
  ByteString ->
  (Client msg -> ExceptT (ProtocolClientError err) IO b) ->
  AM b
withXFTPClient c (userId, srv, entityId) cmdStr action = do
  tSess <- liftIO $ mkTransportSession c userId srv entityId
  withLogClient c tSess entityId cmdStr action

liftClient :: (Show err, Encoding err) => (HostName -> err -> AgentErrorType) -> HostName -> ExceptT (ProtocolClientError err) IO a -> AM a
liftClient protocolError_ = liftError . protocolClientError protocolError_
{-# INLINE liftClient #-}

protocolClientError :: (Show err, Encoding err) => (HostName -> err -> AgentErrorType) -> HostName -> ProtocolClientError err -> AgentErrorType
protocolClientError protocolError_ host = \case
  PCEProtocolError e -> protocolError_ host e
  PCEResponseError e -> BROKER host $ RESPONSE $ B.unpack $ smpEncode e
  PCEUnexpectedResponse e -> BROKER host $ UNEXPECTED $ B.unpack e
  PCEResponseTimeout -> BROKER host TIMEOUT
  PCENetworkError -> BROKER host NETWORK
  PCEIncompatibleHost -> BROKER host HOST
  PCETransportError e -> BROKER host $ TRANSPORT e
  e@PCECryptoError {} -> INTERNAL $ show e
  PCEIOError {} -> BROKER host NETWORK

data ProtocolTestStep
  = TSConnect
  | TSDisconnect
  | TSCreateQueue
  | TSSecureQueue
  | TSDeleteQueue
  | TSCreateFile
  | TSUploadFile
  | TSDownloadFile
  | TSCompareFile
  | TSDeleteFile
  | TSCreateNtfToken
  | TSDeleteNtfToken
  deriving (Eq, Show)

data ProtocolTestFailure = ProtocolTestFailure
  { testStep :: ProtocolTestStep,
    testError :: AgentErrorType
  }
  deriving (Eq, Show)

runSMPServerTest :: AgentClient -> UserId -> SMPServerWithAuth -> AM' (Maybe ProtocolTestFailure)
runSMPServerTest c userId (ProtoServerWithAuth srv auth) = do
  cfg <- getClientConfig c smpCfg
  C.AuthAlg ra <- asks $ rcvAuthAlg . config
  C.AuthAlg sa <- asks $ sndAuthAlg . config
  g <- asks random
  liftIO $ do
    let tSess = (userId, srv, Nothing)
    getProtocolClient g tSess cfg Nothing (\_ -> pure ()) >>= \case
      Right smp -> do
        rKeys@(_, rpKey) <- atomically $ C.generateAuthKeyPair ra g
        (sKey, _) <- atomically $ C.generateAuthKeyPair sa g
        (dhKey, _) <- atomically $ C.generateKeyPair g
        r <- runExceptT $ do
          SMP.QIK {rcvId} <- liftError (testErr TSCreateQueue) $ createSMPQueue smp rKeys dhKey auth SMSubscribe
          liftError (testErr TSSecureQueue) $ secureSMPQueue smp rpKey rcvId sKey
          liftError (testErr TSDeleteQueue) $ deleteSMPQueue smp rpKey rcvId
        ok <- tcpTimeout (networkConfig cfg) `timeout` closeProtocolClient smp
        pure $ either Just (const Nothing) r <|> maybe (Just (ProtocolTestFailure TSDisconnect $ BROKER addr TIMEOUT)) (const Nothing) ok
      Left e -> pure (Just $ testErr TSConnect e)
  where
    addr = B.unpack $ strEncode srv
    testErr :: ProtocolTestStep -> SMPClientError -> ProtocolTestFailure
    testErr step = ProtocolTestFailure step . protocolClientError SMP addr

runXFTPServerTest :: AgentClient -> UserId -> XFTPServerWithAuth -> AM' (Maybe ProtocolTestFailure)
runXFTPServerTest c userId (ProtoServerWithAuth srv auth) = do
  cfg <- asks $ xftpCfg . config
  g <- asks random
  xftpNetworkConfig <- atomically $ getNetworkConfig c
  workDir <- getXFTPWorkPath
  filePath <- getTempFilePath workDir
  rcvPath <- getTempFilePath workDir
  liftIO $ do
    let tSess = (userId, srv, Nothing)
    X.getXFTPClient tSess cfg {xftpNetworkConfig} (\_ -> pure ()) >>= \case
      Right xftp -> withTestChunk filePath $ do
        (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
        digest <- liftIO $ C.sha256Hash <$> B.readFile filePath
        let file = FileInfo {sndKey, size = chSize, digest}
            chunkSpec = X.XFTPChunkSpec {filePath, chunkOffset = 0, chunkSize = chSize}
        r <- runExceptT $ do
          (sId, [rId]) <- liftError (testErr TSCreateFile) $ X.createXFTPChunk xftp spKey file [rcvKey] auth
          liftError (testErr TSUploadFile) $ X.uploadXFTPChunk xftp spKey sId chunkSpec
          liftError (testErr TSDownloadFile) $ X.downloadXFTPChunk g xftp rpKey rId $ XFTPRcvChunkSpec rcvPath chSize digest
          rcvDigest <- liftIO $ C.sha256Hash <$> B.readFile rcvPath
          unless (digest == rcvDigest) $ throwError $ ProtocolTestFailure TSCompareFile $ XFTP (B.unpack $ strEncode srv) DIGEST
          liftError (testErr TSDeleteFile) $ X.deleteXFTPChunk xftp spKey sId
        ok <- tcpTimeout xftpNetworkConfig `timeout` X.closeXFTPClient xftp
        incClientStat c userId xftp "XFTP_TEST" "OK"
        pure $ either Just (const Nothing) r <|> maybe (Just (ProtocolTestFailure TSDisconnect $ BROKER addr TIMEOUT)) (const Nothing) ok
      Left e -> pure (Just $ testErr TSConnect e)
  where
    addr = B.unpack $ strEncode srv
    testErr :: ProtocolTestStep -> XFTPClientError -> ProtocolTestFailure
    testErr step = ProtocolTestFailure step . protocolClientError XFTP addr
    chSize :: Integral a => a
    chSize = kb 64
    getTempFilePath :: FilePath -> AM' FilePath
    getTempFilePath workPath = do
      ts <- liftIO getCurrentTime
      let isoTime = formatTime defaultTimeLocale "%Y-%m-%dT%H%M%S.%6q" ts
      uniqueCombine workPath isoTime
    withTestChunk :: FilePath -> IO a -> IO a
    withTestChunk fp =
      E.bracket_
        (createTestChunk fp)
        (whenM (doesFileExist fp) $ removeFile fp `catchAll_` pure ())
    -- this creates a new DRG on purpose to avoid blocking the one used in the agent
    createTestChunk :: FilePath -> IO ()
    createTestChunk fp = B.writeFile fp =<< atomically . C.randomBytes chSize =<< C.newRandom

runNTFServerTest :: AgentClient -> UserId -> NtfServerWithAuth -> AM' (Maybe ProtocolTestFailure)
runNTFServerTest c userId (ProtoServerWithAuth srv _) = do
  cfg <- getClientConfig c ntfCfg
  C.AuthAlg a <- asks $ rcvAuthAlg . config
  g <- asks random
  liftIO $ do
    let tSess = (userId, srv, Nothing)
    getProtocolClient g tSess cfg Nothing (\_ -> pure ()) >>= \case
      Right ntf -> do
        (nKey, npKey) <- atomically $ C.generateAuthKeyPair a g
        (dhKey, _) <- atomically $ C.generateKeyPair g
        r <- runExceptT $ do
          let deviceToken = DeviceToken PPApnsNull "test_ntf_token"
          (tknId, _) <- liftError (testErr TSCreateNtfToken) $ ntfRegisterToken ntf npKey (NewNtfTkn deviceToken nKey dhKey)
          liftError (testErr TSDeleteNtfToken) $ ntfDeleteToken ntf npKey tknId
        ok <- tcpTimeout (networkConfig cfg) `timeout` closeProtocolClient ntf
        incClientStat c userId ntf "NTF_TEST" "OK"
        pure $ either Just (const Nothing) r <|> maybe (Just (ProtocolTestFailure TSDisconnect $ BROKER addr TIMEOUT)) (const Nothing) ok
      Left e -> pure (Just $ testErr TSConnect e)
  where
    addr = B.unpack $ strEncode srv
    testErr :: ProtocolTestStep -> SMPClientError -> ProtocolTestFailure
    testErr step = ProtocolTestFailure step . protocolClientError NTF addr

getXFTPWorkPath :: AM' FilePath
getXFTPWorkPath = do
  workDir <- readTVarIO =<< asks (xftpWorkDir . xftpAgent)
  maybe getTemporaryDirectory pure workDir

mkTransportSession :: AgentClient -> UserId -> ProtoServer msg -> EntityId -> IO (TransportSession msg)
mkTransportSession c userId srv entityId = mkTSession userId srv entityId <$> getSessionMode c
{-# INLINE mkTransportSession #-}

mkTSession :: UserId -> ProtoServer msg -> EntityId -> TransportSessionMode -> TransportSession msg
mkTSession userId srv entityId mode = (userId, srv, if mode == TSMEntity then Just entityId else Nothing)
{-# INLINE mkTSession #-}

mkSMPTransportSession :: SMPQueueRec q => AgentClient -> q -> IO SMPTransportSession
mkSMPTransportSession c q = mkSMPTSession q <$> getSessionMode c
{-# INLINE mkSMPTransportSession #-}

mkSMPTSession :: SMPQueueRec q => q -> TransportSessionMode -> SMPTransportSession
mkSMPTSession q = mkTSession (qUserId q) (qServer q) (qConnId q)
{-# INLINE mkSMPTSession #-}

getSessionMode :: AgentClient -> IO TransportSessionMode
getSessionMode = atomically . fmap sessionMode . getNetworkConfig
{-# INLINE getSessionMode #-}

newRcvQueue :: AgentClient -> UserId -> ConnId -> SMPServerWithAuth -> VersionRangeSMPC -> SubscriptionMode -> AM (NewRcvQueue, SMPQueueUri, SMPTransportSession, SessionId)
newRcvQueue c userId connId (ProtoServerWithAuth srv auth) vRange subMode = do
  C.AuthAlg a <- asks (rcvAuthAlg . config)
  g <- asks random
  rKeys@(_, rcvPrivateKey) <- atomically $ C.generateAuthKeyPair a g
  (dhKey, privDhKey) <- atomically $ C.generateKeyPair g
  (e2eDhKey, e2ePrivKey) <- atomically $ C.generateKeyPair g
  logServer "-->" c srv "" "NEW"
  tSess <- liftIO $ mkTransportSession c userId srv connId
  (sessId, QIK {rcvId, sndId, rcvPublicDhKey}) <-
    withClient c tSess "NEW" $ \(SMPConnectedClient smp _) ->
      (sessionId $ thParams smp,) <$> createSMPQueue smp rKeys dhKey auth subMode
  liftIO . logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sndId]
  let rq =
        RcvQueue
          { userId,
            connId,
            server = srv,
            rcvId,
            rcvPrivateKey,
            rcvDhSecret = C.dh' rcvPublicDhKey privDhKey,
            e2ePrivKey,
            e2eDhSecret = Nothing,
            sndId,
            status = New,
            dbQueueId = DBNewQueue,
            primary = True,
            dbReplaceQueueId = Nothing,
            rcvSwchStatus = Nothing,
            smpClientVersion = maxVersion vRange,
            clientNtfCreds = Nothing,
            deleteErrors = 0
          }
      qUri = SMPQueueUri vRange $ SMPQueueAddress srv sndId e2eDhKey
  pure (rq, qUri, tSess, sessId)

processSubResult :: AgentClient -> RcvQueue -> Either SMPClientError () -> STM (Maybe ConnId)
processSubResult c rq@RcvQueue {connId} = \case
  Left e -> Nothing <$ unless (temporaryClientError e) (failSubscription c rq e)
  Right () -> ifM (hasPendingSubscription c connId) (Just connId <$ addSubscription c rq) (pure Nothing)

temporaryAgentError :: AgentErrorType -> Bool
temporaryAgentError = \case
  BROKER _ e -> tempBrokerError e
  SMP _ (SMP.PROXY (SMP.BROKER e)) -> tempBrokerError e
  PROXY _ _ (ProxyProtocolError (SMP.PROXY (SMP.BROKER e))) -> tempBrokerError e
  PROXY _ _ (ProxyProtocolError (SMP.PROXY SMP.NO_SESSION)) -> True
  INACTIVE -> True
  _ -> False
  where
    tempBrokerError = \case
      NETWORK -> True
      TIMEOUT -> True
      _ -> False

temporaryOrHostError :: AgentErrorType -> Bool
temporaryOrHostError e = temporaryAgentError e || serverHostError e
{-# INLINE temporaryOrHostError #-}

serverHostError :: AgentErrorType -> Bool
serverHostError = \case
  BROKER _ e -> brokerHostError e
  SMP _ (SMP.PROXY (SMP.BROKER e)) -> brokerHostError e
  PROXY _ _ (ProxyProtocolError (SMP.PROXY (SMP.BROKER e))) -> brokerHostError e
  _ -> False
  where
    brokerHostError = \case
      HOST -> True
      SMP.TRANSPORT TEVersion -> True
      _ -> False

-- | Subscribe to queues. The list of results can have a different order.
subscribeQueues :: AgentClient -> [RcvQueue] -> AM' ([(RcvQueue, Either AgentErrorType ())], Maybe SessionId)
subscribeQueues c qs = do
  (errs, qs') <- partitionEithers <$> mapM checkQueue qs
  atomically $ do
    modifyTVar' (subscrConns c) (`S.union` S.fromList (map qConnId qs'))
    RQ.batchAddQueues (pendingSubs c) qs'
  env <- ask
  -- only "checked" queues are subscribed
  session <- newTVarIO Nothing
  rs <- sendTSessionBatches "SUB" 90 id (subscribeQueues_ env session) c qs'
  (errs <> rs,) <$> readTVarIO session
  where
    checkQueue rq = do
      prohibited <- atomically $ hasGetLock c rq
      pure $ if prohibited then Left (rq, Left $ CMD PROHIBITED "subscribeQueues") else Right rq
    subscribeQueues_ :: Env -> TVar (Maybe SessionId) -> SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses SMPClientError ())
    subscribeQueues_ env session smp qs' = do
      rs <- sendBatch subscribeSMPQueues smp qs'
      (active, subResults) <-
        atomically $
          ifM
            (activeClientSession c tSess sessId)
            (writeTVar session (Just sessId) >> ((True,) <$> processSubResults rs))
            (pure (False, []))
      if active
        then do
          when (any isNothing subResults) resubscribe
          let up = catMaybes $ L.toList subResults
          unless (null up) $ notifyUP up
          pure rs
        else do
          logWarn "subcription batch result for replaced SMP client, resubscribing"
          resubscribe $> L.map (second $ \_ -> Left PCENetworkError) rs
      where
        notifyUP up = maybe (logError "sndQ full" >> notifyUP up) pure =<< timeout 30000000 (notifySub c "" $ UP srv up)
        tSess@(_, srv, _) = transportSession' smp
        sessId = sessionId $ thParams smp
        processSubResults :: NonEmpty (RcvQueue, Either SMPClientError ()) -> STM (NonEmpty (Maybe ConnId))
        processSubResults = mapM (uncurry $ processSubResult c)
        resubscribe = resubscribeSMPSession c tSess `runReaderT` env

activeClientSession :: AgentClient -> SMPTransportSession -> SessionId -> STM Bool
activeClientSession c tSess sessId = sameSess <$> tryReadSessVar tSess (smpClients c)
  where
    sameSess = \case
      Just (Right (SMPConnectedClient smp _)) -> sessId == sessionId (thParams smp)
      _ -> False

type BatchResponses e r = NonEmpty (RcvQueue, Either e r)

-- statBatchSize is not used to batch the commands, only for traffic statistics
sendTSessionBatches :: forall q r. ByteString -> Int -> (q -> RcvQueue) -> (SMPClient -> NonEmpty q -> IO (BatchResponses SMPClientError r)) -> AgentClient -> [q] -> AM' [(RcvQueue, Either AgentErrorType r)]
sendTSessionBatches statCmd statBatchSize toRQ action c qs =
  concatMap L.toList <$> (mapConcurrently sendClientBatch =<< batchQueues)
  where
    batchQueues :: AM' [(SMPTransportSession, NonEmpty q)]
    batchQueues = do
      mode <- atomically $ sessionMode <$> getNetworkConfig c
      pure . M.assocs $ foldl' (batch mode) M.empty qs
      where
        batch mode m q =
          let tSess = mkSMPTSession (toRQ q) mode
           in M.alter (Just . maybe [q] (q <|)) tSess m
    sendClientBatch :: (SMPTransportSession, NonEmpty q) -> AM' (BatchResponses AgentErrorType r)
    sendClientBatch (tSess@(userId, srv, _), qs') =
      tryAgentError' (getSMPServerClient c tSess) >>= \case
        Left e -> pure $ L.map ((,Left e) . toRQ) qs'
        Right (SMPConnectedClient smp _) -> liftIO $ do
          logServer "-->" c srv (bshow (length qs') <> " queues") statCmd
          rs <- L.map agentError <$> action smp qs'
          statBatch
          pure rs
          where
            agentError = second . first $ protocolClientError SMP $ clientServer smp
            statBatch =
              let n = (length qs - 1) `div` statBatchSize + 1
               in incClientStatN c userId smp n statCmd "OK"

sendBatch :: (SMPClient -> NonEmpty (SMP.RcvPrivateAuthKey, SMP.RecipientId) -> IO (NonEmpty (Either SMPClientError ()))) -> SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses SMPClientError ())
sendBatch smpCmdFunc smp qs = L.zip qs <$> smpCmdFunc smp (L.map queueCreds qs)
  where
    queueCreds RcvQueue {rcvPrivateKey, rcvId} = (rcvPrivateKey, rcvId)

addSubscription :: AgentClient -> RcvQueue -> STM ()
addSubscription c rq@RcvQueue {connId} = do
  modifyTVar' (subscrConns c) $ S.insert connId
  RQ.addQueue rq $ activeSubs c
  RQ.deleteQueue rq $ pendingSubs c

failSubscription :: AgentClient -> RcvQueue -> SMPClientError -> STM ()
failSubscription c rq e = do
  RQ.deleteQueue rq (pendingSubs c)
  TM.insert (RQ.qKey rq) e (removedSubs c)

addPendingSubscription :: AgentClient -> RcvQueue -> STM ()
addPendingSubscription c rq@RcvQueue {connId} = do
  modifyTVar' (subscrConns c) $ S.insert connId
  RQ.addQueue rq $ pendingSubs c

addNewQueueSubscription :: AgentClient -> RcvQueue -> SMPTransportSession -> SessionId -> AM' ()
addNewQueueSubscription c rq tSess sessId = do
  same <-
    atomically $
      ifM
        (activeClientSession c tSess sessId)
        (True <$ addSubscription c rq)
        (False <$ addPendingSubscription c rq)
  unless same $ resubscribeSMPSession c tSess

hasActiveSubscription :: AgentClient -> ConnId -> STM Bool
hasActiveSubscription c connId = RQ.hasConn connId $ activeSubs c
{-# INLINE hasActiveSubscription #-}

hasPendingSubscription :: AgentClient -> ConnId -> STM Bool
hasPendingSubscription c connId = RQ.hasConn connId $ pendingSubs c
{-# INLINE hasPendingSubscription #-}

removeSubscription :: AgentClient -> ConnId -> STM ()
removeSubscription c connId = do
  modifyTVar' (subscrConns c) $ S.delete connId
  RQ.deleteConn connId $ activeSubs c
  RQ.deleteConn connId $ pendingSubs c

getSubscriptions :: AgentClient -> STM (Set ConnId)
getSubscriptions = readTVar . subscrConns
{-# INLINE getSubscriptions #-}

logServer :: MonadIO m => ByteString -> AgentClient -> ProtocolServer s -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]
{-# INLINE logServer #-}

showServer :: ProtocolServer s -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)
{-# INLINE showServer #-}

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs
{-# INLINE logSecret #-}

sendConfirmation :: AgentClient -> SndQueue -> ByteString -> AM (Maybe SMPServer)
sendConfirmation c sq@SndQueue {userId, server, sndId, sndPublicKey = Just sndPublicKey, e2ePubKey = e2ePubKey@Just {}} agentConfirmation = do
  let clientMsg = SMP.ClientMessage (SMP.PHConfirmation sndPublicKey) agentConfirmation
  msg <- agentCbEncrypt sq e2ePubKey $ smpEncode clientMsg
  sendOrProxySMPMessage c userId server "<CONF>" Nothing sndId (MsgFlags {notification = True}) msg
sendConfirmation _ _ _ = throwError $ INTERNAL "sendConfirmation called without snd_queue public key(s) in the database"

sendInvitation :: AgentClient -> UserId -> Compatible SMPQueueInfo -> Compatible VersionSMPA -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> AM (Maybe SMPServer)
sendInvitation c userId (Compatible (SMPQueueInfo v SMPQueueAddress {smpServer, senderId, dhPublicKey})) (Compatible agentVersion) connReq connInfo = do
  msg <- mkInvitation
  sendOrProxySMPMessage c userId smpServer "<INV>" Nothing senderId (MsgFlags {notification = True}) msg
  where
    mkInvitation :: AM ByteString
    -- this is only encrypted with per-queue E2E, not with double ratchet
    mkInvitation = do
      let agentEnvelope = AgentInvitation {agentVersion, connReq, connInfo}
      agentCbEncryptOnce v dhPublicKey . smpEncode $
        SMP.ClientMessage SMP.PHEmpty (smpEncode agentEnvelope)

getQueueMessage :: AgentClient -> RcvQueue -> AM (Maybe SMPMsgMeta)
getQueueMessage c rq@RcvQueue {server, rcvId, rcvPrivateKey} = do
  atomically createTakeGetLock
  msg_ <- withSMPClient c rq "GET" $ \smp ->
    getSMPMessage smp rcvPrivateKey rcvId
  mapM decryptMeta msg_
  where
    decryptMeta msg@SMP.RcvMessage {msgId} = SMP.rcvMessageMeta msgId <$> decryptSMPMessage rq msg
    createTakeGetLock = TM.alterF takeLock (server, rcvId) $ getMsgLocks c
      where
        takeLock l_ = do
          l <- maybe (newTMVar ()) pure l_
          takeTMVar l
          pure $ Just l

decryptSMPMessage :: RcvQueue -> SMP.RcvMessage -> AM SMP.ClientRcvMsgBody
decryptSMPMessage rq SMP.RcvMessage {msgId, msgBody = SMP.EncRcvMsgBody body} =
  liftEither . parse SMP.clientRcvMsgBodyP (AGENT A_MESSAGE) =<< decrypt body
  where
    decrypt = agentCbDecrypt (rcvDhSecret rq) (C.cbNonce msgId)

secureQueue :: AgentClient -> RcvQueue -> SndPublicAuthKey -> AM ()
secureQueue c rq@RcvQueue {rcvId, rcvPrivateKey} senderKey =
  withSMPClient c rq "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

enableQueueNotifications :: AgentClient -> RcvQueue -> SMP.NtfPublicAuthKey -> SMP.RcvNtfPublicDhKey -> AM (SMP.NotifierId, SMP.RcvNtfPublicDhKey)
enableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} notifierKey rcvNtfPublicDhKey =
  withSMPClient c rq "NKEY <nkey>" $ \smp ->
    enableSMPQueueNotifications smp rcvPrivateKey rcvId notifierKey rcvNtfPublicDhKey

enableQueuesNtfs :: AgentClient -> [(RcvQueue, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey)] -> AM' [(RcvQueue, Either AgentErrorType (SMP.NotifierId, SMP.RcvNtfPublicDhKey))]
enableQueuesNtfs = sendTSessionBatches "NKEY" 90 fst3 enableQueues_
  where
    fst3 (x, _, _) = x
    enableQueues_ :: SMPClient -> NonEmpty (RcvQueue, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey) -> IO (NonEmpty (RcvQueue, Either (ProtocolClientError ErrorType) (SMP.NotifierId, RcvNtfPublicDhKey)))
    enableQueues_ smp qs' = L.zipWith ((,) . fst3) qs' <$> enableSMPQueuesNtfs smp (L.map queueCreds qs')
    queueCreds :: (RcvQueue, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey) -> (SMP.RcvPrivateAuthKey, SMP.RecipientId, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey)
    queueCreds (RcvQueue {rcvPrivateKey, rcvId}, notifierKey, rcvNtfPublicDhKey) = (rcvPrivateKey, rcvId, notifierKey, rcvNtfPublicDhKey)

disableQueueNotifications :: AgentClient -> RcvQueue -> AM ()
disableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "NDEL" $ \smp ->
    disableSMPQueueNotifications smp rcvPrivateKey rcvId

disableQueuesNtfs :: AgentClient -> [RcvQueue] -> AM' [(RcvQueue, Either AgentErrorType ())]
disableQueuesNtfs = sendTSessionBatches "NDEL" 90 id $ sendBatch disableSMPQueuesNtfs

sendAck :: AgentClient -> RcvQueue -> MsgId -> AM ()
sendAck c rq@RcvQueue {rcvId, rcvPrivateKey} msgId = do
  withSMPClient c rq ("ACK:" <> logSecret msgId) $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId msgId
  atomically $ releaseGetLock c rq

hasGetLock :: AgentClient -> RcvQueue -> STM Bool
hasGetLock c RcvQueue {server, rcvId} =
  TM.member (server, rcvId) $ getMsgLocks c

releaseGetLock :: AgentClient -> RcvQueue -> STM ()
releaseGetLock c RcvQueue {server, rcvId} =
  TM.lookup (server, rcvId) (getMsgLocks c) >>= mapM_ (`tryPutTMVar` ())

suspendQueue :: AgentClient -> RcvQueue -> AM ()
suspendQueue c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentClient -> RcvQueue -> AM ()
deleteQueue c rq@RcvQueue {rcvId, rcvPrivateKey} = do
  withSMPClient c rq "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

deleteQueues :: AgentClient -> [RcvQueue] -> AM' [(RcvQueue, Either AgentErrorType ())]
deleteQueues = sendTSessionBatches "DEL" 90 id $ sendBatch deleteSMPQueues

sendAgentMessage :: AgentClient -> SndQueue -> MsgFlags -> ByteString -> AM (Maybe SMPServer)
sendAgentMessage c sq@SndQueue {userId, server, sndId, sndPrivateKey} msgFlags agentMsg = do
  let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
  msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
  sendOrProxySMPMessage c userId server "<MSG>" (Just sndPrivateKey) sndId msgFlags msg

getQueueInfo :: AgentClient -> RcvQueue -> AM QueueInfo
getQueueInfo c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "QUE" $ \smp ->
    getSMPQueueInfo smp rcvPrivateKey rcvId

agentNtfRegisterToken :: AgentClient -> NtfToken -> NtfPublicAuthKey -> C.PublicKeyX25519 -> AM (NtfTokenId, C.PublicKeyX25519)
agentNtfRegisterToken c NtfToken {deviceToken, ntfServer, ntfPrivKey} ntfPubKey pubDhKey =
  withClient c (0, ntfServer, Nothing) "TNEW" $ \ntf -> ntfRegisterToken ntf ntfPrivKey (NewNtfTkn deviceToken ntfPubKey pubDhKey)

agentNtfVerifyToken :: AgentClient -> NtfTokenId -> NtfToken -> NtfRegCode -> AM ()
agentNtfVerifyToken c tknId NtfToken {ntfServer, ntfPrivKey} code =
  withNtfClient c ntfServer tknId "TVFY" $ \ntf -> ntfVerifyToken ntf ntfPrivKey tknId code

agentNtfCheckToken :: AgentClient -> NtfTokenId -> NtfToken -> AM NtfTknStatus
agentNtfCheckToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer tknId "TCHK" $ \ntf -> ntfCheckToken ntf ntfPrivKey tknId

agentNtfReplaceToken :: AgentClient -> NtfTokenId -> NtfToken -> DeviceToken -> AM ()
agentNtfReplaceToken c tknId NtfToken {ntfServer, ntfPrivKey} token =
  withNtfClient c ntfServer tknId "TRPL" $ \ntf -> ntfReplaceToken ntf ntfPrivKey tknId token

agentNtfDeleteToken :: AgentClient -> NtfTokenId -> NtfToken -> AM ()
agentNtfDeleteToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer tknId "TDEL" $ \ntf -> ntfDeleteToken ntf ntfPrivKey tknId

agentNtfEnableCron :: AgentClient -> NtfTokenId -> NtfToken -> Word16 -> AM ()
agentNtfEnableCron c tknId NtfToken {ntfServer, ntfPrivKey} interval =
  withNtfClient c ntfServer tknId "TCRN" $ \ntf -> ntfEnableCron ntf ntfPrivKey tknId interval

agentNtfCreateSubscription :: AgentClient -> NtfTokenId -> NtfToken -> SMPQueueNtf -> SMP.NtfPrivateAuthKey -> AM NtfSubscriptionId
agentNtfCreateSubscription c tknId NtfToken {ntfServer, ntfPrivKey} smpQueue nKey =
  withNtfClient c ntfServer tknId "SNEW" $ \ntf -> ntfCreateSubscription ntf ntfPrivKey (NewNtfSub tknId smpQueue nKey)

agentNtfCheckSubscription :: AgentClient -> NtfSubscriptionId -> NtfToken -> AM NtfSubStatus
agentNtfCheckSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer subId "SCHK" $ \ntf -> ntfCheckSubscription ntf ntfPrivKey subId

agentNtfDeleteSubscription :: AgentClient -> NtfSubscriptionId -> NtfToken -> AM ()
agentNtfDeleteSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer subId "SDEL" $ \ntf -> ntfDeleteSubscription ntf ntfPrivKey subId

agentXFTPDownloadChunk :: AgentClient -> UserId -> FileDigest -> RcvFileChunkReplica -> XFTPRcvChunkSpec -> AM ()
agentXFTPDownloadChunk c userId (FileDigest chunkDigest) RcvFileChunkReplica {server, replicaId = ChunkReplicaId fId, replicaKey} chunkSpec = do
  g <- asks random
  withXFTPClient c (userId, server, chunkDigest) "FGET" $ \xftp -> X.downloadXFTPChunk g xftp replicaKey fId chunkSpec

agentXFTPNewChunk :: AgentClient -> SndFileChunk -> Int -> XFTPServerWithAuth -> AM NewSndChunkReplica
agentXFTPNewChunk c SndFileChunk {userId, chunkSpec = XFTPChunkSpec {chunkSize}, digest = FileDigest chunkDigest} n (ProtoServerWithAuth srv auth) = do
  rKeys <- xftpRcvKeys n
  (sndKey, replicaKey) <- atomically . C.generateAuthKeyPair C.SEd25519 =<< asks random
  let fileInfo = FileInfo {sndKey, size = chunkSize, digest = chunkDigest}
  logServer "-->" c srv "" "FNEW"
  tSess <- liftIO $ mkTransportSession c userId srv chunkDigest
  (sndId, rIds) <- withClient c tSess "FNEW" $ \xftp -> X.createXFTPChunk xftp replicaKey fileInfo (L.map fst rKeys) auth
  logServer "<--" c srv "" $ B.unwords ["SIDS", logSecret sndId]
  pure NewSndChunkReplica {server = srv, replicaId = ChunkReplicaId sndId, replicaKey, rcvIdsKeys = L.toList $ xftpRcvIdsKeys rIds rKeys}

agentXFTPUploadChunk :: AgentClient -> UserId -> FileDigest -> SndFileChunkReplica -> XFTPChunkSpec -> AM ()
agentXFTPUploadChunk c userId (FileDigest chunkDigest) SndFileChunkReplica {server, replicaId = ChunkReplicaId fId, replicaKey} chunkSpec =
  withXFTPClient c (userId, server, chunkDigest) "FPUT" $ \xftp -> X.uploadXFTPChunk xftp replicaKey fId chunkSpec

agentXFTPAddRecipients :: AgentClient -> UserId -> FileDigest -> SndFileChunkReplica -> Int -> AM (NonEmpty (ChunkReplicaId, C.APrivateAuthKey))
agentXFTPAddRecipients c userId (FileDigest chunkDigest) SndFileChunkReplica {server, replicaId = ChunkReplicaId fId, replicaKey} n = do
  rKeys <- xftpRcvKeys n
  rIds <- withXFTPClient c (userId, server, chunkDigest) "FADD" $ \xftp -> X.addXFTPRecipients xftp replicaKey fId (L.map fst rKeys)
  pure $ xftpRcvIdsKeys rIds rKeys

agentXFTPDeleteChunk :: AgentClient -> UserId -> DeletedSndChunkReplica -> AM ()
agentXFTPDeleteChunk c userId DeletedSndChunkReplica {server, replicaId = ChunkReplicaId fId, replicaKey, chunkDigest = FileDigest chunkDigest} =
  withXFTPClient c (userId, server, chunkDigest) "FDEL" $ \xftp -> X.deleteXFTPChunk xftp replicaKey fId

xftpRcvKeys :: Int -> AM (NonEmpty C.AAuthKeyPair)
xftpRcvKeys n = do
  rKeys <- atomically . replicateM n . C.generateAuthKeyPair C.SEd25519 =<< asks random
  case L.nonEmpty rKeys of
    Just rKeys' -> pure rKeys'
    _ -> throwError $ INTERNAL "non-positive number of recipients"

xftpRcvIdsKeys :: NonEmpty ByteString -> NonEmpty C.AAuthKeyPair -> NonEmpty (ChunkReplicaId, C.APrivateAuthKey)
xftpRcvIdsKeys rIds rKeys = L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys

agentCbEncrypt :: SndQueue -> Maybe C.PublicKeyX25519 -> ByteString -> AM ByteString
agentCbEncrypt SndQueue {e2eDhSecret, smpClientVersion} e2ePubKey msg = do
  cmNonce <- atomically . C.randomCbNonce =<< asks random
  let paddedLen = maybe SMP.e2eEncMessageLength (const SMP.e2eEncConfirmationLength) e2ePubKey
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg paddedLen
  let cmHeader = SMP.PubHeader smpClientVersion e2ePubKey
  pure $ smpEncode SMP.ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

-- add encoding as AgentInvitation'?
agentCbEncryptOnce :: VersionSMPC -> C.PublicKeyX25519 -> ByteString -> AM ByteString
agentCbEncryptOnce clientVersion dhRcvPubKey msg = do
  g <- asks random
  (dhSndPubKey, dhSndPrivKey) <- atomically $ C.generateKeyPair g
  let e2eDhSecret = C.dh' dhRcvPubKey dhSndPrivKey
  cmNonce <- atomically $ C.randomCbNonce g
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg SMP.e2eEncConfirmationLength
  let cmHeader = SMP.PubHeader clientVersion (Just dhSndPubKey)
  pure $ smpEncode SMP.ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

-- | NaCl crypto-box decrypt - both for messages received from the server
-- and per-queue E2E encrypted messages from the sender that were inside.
agentCbDecrypt :: C.DhSecretX25519 -> C.CbNonce -> ByteString -> AM ByteString
agentCbDecrypt dhSecret nonce msg =
  liftEither . first cryptoError $
    C.cbDecrypt dhSecret nonce msg

cryptoError :: C.CryptoError -> AgentErrorType
cryptoError = \case
  C.CryptoLargeMsgError -> CMD LARGE "CryptoLargeMsgError"
  C.CryptoHeaderError _ -> AGENT A_MESSAGE -- parsing error
  C.CERatchetDuplicateMessage -> AGENT A_DUPLICATE
  C.AESDecryptError -> c DECRYPT_AES
  C.CBDecryptError -> c DECRYPT_CB
  C.CERatchetHeader -> c RATCHET_HEADER
  C.CERatchetTooManySkipped n -> c $ RATCHET_SKIPPED n
  C.CERatchetEarlierMessage n -> c $ RATCHET_EARLIER n
  e -> INTERNAL $ show e
  where
    c = AGENT . A_CRYPTO

waitForWork :: MonadIO m => TMVar () -> m ()
waitForWork = void . atomically . readTMVar
{-# INLINE waitForWork #-}

withWork :: AgentClient -> TMVar () -> (DB.Connection -> IO (Either StoreError (Maybe a))) -> (a -> AM ()) -> AM ()
withWork c doWork getWork action =
  withStore' c getWork >>= \case
    Right (Just r) -> action r
    Right Nothing -> noWork
    Left e@SEWorkItemError {} -> noWork >> notifyErr (CRITICAL False) e
    Left e -> notifyErr INTERNAL e
  where
    noWork = liftIO $ noWorkToDo doWork
    notifyErr err e = atomically $ writeTBQueue (subQ c) ("", "", APC SAEConn $ ERR $ err $ show e)

noWorkToDo :: TMVar () -> IO ()
noWorkToDo = void . atomically . tryTakeTMVar
{-# INLINE noWorkToDo #-}

hasWorkToDo :: Worker -> STM ()
hasWorkToDo = hasWorkToDo' . doWork
{-# INLINE hasWorkToDo #-}

hasWorkToDo' :: TMVar () -> STM ()
hasWorkToDo' = void . (`tryPutTMVar` ())
{-# INLINE hasWorkToDo' #-}

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
  writeTBQueue (subQ c) ("", "", APC SAENone SUSPENDED)
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
{-# INLINE whenSuspending #-}

beginAgentOperation :: AgentClient -> AgentOperation -> STM ()
beginAgentOperation c op = do
  let opVar = agentOpSel op c
  s <- readTVar opVar
  -- unsafeIOToSTM $ putStrLn $ "beginOperation? " <> show op <> " " <> show (opsInProgress s)
  when (opSuspended s) retry
  -- unsafeIOToSTM $ putStrLn $ "beginOperation! " <> show op <> " " <> show (opsInProgress s + 1)
  writeTVar opVar $! s {opsInProgress = opsInProgress s + 1}

agentOperationBracket :: MonadUnliftIO m => AgentClient -> AgentOperation -> (AgentClient -> STM ()) -> m a -> m a
agentOperationBracket c op check action =
  E.bracket
    (atomically (check c) >> atomically (beginAgentOperation c op))
    (\_ -> atomically $ endAgentOperation c op)
    (const action)

waitUntilForeground :: AgentClient -> STM ()
waitUntilForeground c = unlessM ((ASForeground ==) <$> readTVar (agentState c)) retry
{-# INLINE waitUntilForeground #-}

withStore' :: AgentClient -> (DB.Connection -> IO a) -> AM a
withStore' c action = withStore c $ fmap Right . action
{-# INLINE withStore' #-}

withStore :: AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> AM a
withStore c action = do
  st <- asks store
  withExceptT storeError . ExceptT . liftIO . agentOperationBracket c AODatabase (\_ -> pure ()) $
    withTransaction st action `E.catches` handleDBErrors
  where
    handleDBErrors :: [E.Handler IO (Either StoreError a)]
    handleDBErrors =
      [ E.Handler $ \(e :: SQL.SQLError) ->
          let se = SQL.sqlError e
              busy = se == SQL.ErrorBusy || se == SQL.ErrorLocked
           in pure . Left . (if busy then SEDatabaseBusy else SEInternal) $ bshow se,
        E.Handler $ \(E.SomeException e) -> pure . Left $ SEInternal $ bshow e
      ]

withStoreBatch :: Traversable t => AgentClient -> (DB.Connection -> t (IO (Either AgentErrorType a))) -> AM' (t (Either AgentErrorType a))
withStoreBatch c actions = do
  st <- asks store
  liftIO . agentOperationBracket c AODatabase (\_ -> pure ()) $
    withTransaction st $
      mapM (`E.catch` handleInternal) . actions
  where
    handleInternal :: E.SomeException -> IO (Either AgentErrorType a)
    handleInternal = pure . Left . INTERNAL . show

withStoreBatch' :: Traversable t => AgentClient -> (DB.Connection -> t (IO a)) -> AM' (t (Either AgentErrorType a))
withStoreBatch' c actions = withStoreBatch c (fmap (fmap Right) . actions)
{-# INLINE withStoreBatch' #-}

storeError :: StoreError -> AgentErrorType
storeError = \case
  SEConnNotFound -> CONN NOT_FOUND
  SERatchetNotFound -> CONN NOT_FOUND
  SEConnDuplicate -> CONN DUPLICATE
  SEBadConnType CRcv -> CONN SIMPLEX
  SEBadConnType CSnd -> CONN SIMPLEX
  SEInvitationNotFound -> CMD PROHIBITED "SEInvitationNotFound"
  -- this error is never reported as store error,
  -- it is used to wrap agent operations when "transaction-like" store access is needed
  -- NOTE: network IO should NOT be used inside AgentStoreMonad
  SEAgentError e -> e
  SEDatabaseBusy e -> CRITICAL True $ B.unpack e
  e -> INTERNAL $ show e

incStat :: AgentClient -> Int -> AgentStatsKey -> STM ()
incStat AgentClient {agentStats} n k = do
  TM.lookup k agentStats >>= \case
    Just v -> modifyTVar' v (+ n)
    _ -> newTVar n >>= \v -> TM.insert k v agentStats

incClientStat :: ProtocolServerClient v err msg => AgentClient -> UserId -> Client msg -> ByteString -> ByteString -> IO ()
incClientStat c userId = incClientStat' c userId . protocolClient
{-# INLINE incClientStat #-}

incClientStat' :: ProtocolServerClient v err msg => AgentClient -> UserId -> ProtoClient msg -> ByteString -> ByteString -> IO ()
incClientStat' c userId pc = incClientStatN c userId pc 1
{-# INLINE incClientStat' #-}

incServerStat :: AgentClient -> UserId -> ProtocolServer p -> ByteString -> ByteString -> IO ()
incServerStat c userId ProtocolServer {host} cmd res = do
  threadDelay 100000
  atomically $ incStat c 1 statsKey
  where
    statsKey = AgentStatsKey {userId, host = strEncode $ L.head host, clientTs = "", cmd, res}

incClientStatN :: ProtocolServerClient v err msg => AgentClient -> UserId -> ProtoClient msg -> Int -> ByteString -> ByteString -> IO ()
incClientStatN c userId pc n cmd res = do
  atomically $ incStat c n statsKey
  where
    statsKey = AgentStatsKey {userId, host = strEncode $ clientTransportHost pc, clientTs = strEncode $ clientSessionTs pc, cmd, res}

userServers :: forall p. (ProtocolTypeI p, UserProtocol p) => AgentClient -> TMap UserId (NonEmpty (ProtoServerWithAuth p))
userServers c = case protocolTypeI @p of
  SPSMP -> smpServers c
  SPXFTP -> xftpServers c
{-# INLINE userServers #-}

pickServer :: forall p. NonEmpty (ProtoServerWithAuth p) -> AM (ProtoServerWithAuth p)
pickServer = \case
  srv :| [] -> pure srv
  servers -> do
    gen <- asks randomServer
    atomically $ (servers L.!!) <$> stateTVar gen (randomR (0, L.length servers - 1))

getNextServer :: forall p. (ProtocolTypeI p, UserProtocol p) => AgentClient -> UserId -> [ProtocolServer p] -> AM (ProtoServerWithAuth p)
getNextServer c userId usedSrvs = withUserServers c userId $ \srvs ->
  case L.nonEmpty $ deleteFirstsBy sameSrvAddr' (L.toList srvs) (map noAuthSrv usedSrvs) of
    Just srvs' -> pickServer srvs'
    _ -> pickServer srvs

withUserServers :: forall p a. (ProtocolTypeI p, UserProtocol p) => AgentClient -> UserId -> (NonEmpty (ProtoServerWithAuth p) -> AM a) -> AM a
withUserServers c userId action =
  atomically (TM.lookup userId $ userServers c) >>= \case
    Just srvs -> action srvs
    _ -> throwError $ INTERNAL "unknown userId - no user servers"

withNextSrv :: forall p a. (ProtocolTypeI p, UserProtocol p) => AgentClient -> UserId -> TVar [ProtocolServer p] -> [ProtocolServer p] -> (ProtoServerWithAuth p -> AM a) -> AM a
withNextSrv c userId usedSrvs initUsed action = do
  used <- readTVarIO usedSrvs
  srvAuth@(ProtoServerWithAuth srv _) <- getNextServer c userId used
  atomically $ do
    srvs_ <- TM.lookup userId $ userServers c
    let unused = maybe [] ((\\ used) . map protoServer . L.toList) srvs_
        used' = if null unused then initUsed else srv : used
    writeTVar usedSrvs $! used'
  action srvAuth

data SubInfo = SubInfo {userId :: UserId, server :: Text, rcvId :: Text, subError :: Maybe String}
  deriving (Show)

data SubscriptionsInfo = SubscriptionsInfo
  { activeSubscriptions :: [SubInfo],
    pendingSubscriptions :: [SubInfo],
    removedSubscriptions :: [SubInfo]
  }
  deriving (Show)

getAgentSubscriptions :: AgentClient -> IO SubscriptionsInfo
getAgentSubscriptions c = do
  activeSubscriptions <- getSubs activeSubs
  pendingSubscriptions <- getSubs pendingSubs
  removedSubscriptions <- getRemovedSubs
  pure $ SubscriptionsInfo {activeSubscriptions, pendingSubscriptions, removedSubscriptions}
  where
    getSubs sel = map (`subInfo` Nothing) . M.keys <$> readTVarIO (getRcvQueues $ sel c)
    getRemovedSubs = map (uncurry subInfo . second Just) . M.assocs <$> readTVarIO (removedSubs c)
    subInfo :: (UserId, SMPServer, SMP.RecipientId) -> Maybe SMPClientError -> SubInfo
    subInfo (uId, srv, rId) err = SubInfo {userId = uId, server = enc srv, rcvId = enc rId, subError = show <$> err}
    enc :: StrEncoding a => a -> Text
    enc = decodeLatin1 . strEncode

data AgentWorkersDetails = AgentWorkersDetails
  { smpClients_ :: [Text],
    ntfClients_ :: [Text],
    xftpClients_ :: [Text],
    smpDeliveryWorkers_ :: Map Text WorkersDetails,
    asyncCmdWorkers_ :: Map Text WorkersDetails,
    smpSubWorkers_ :: [Text],
    ntfWorkers_ :: Map Text WorkersDetails,
    ntfSMPWorkers_ :: Map Text WorkersDetails,
    xftpRcvWorkers_ :: Map Text WorkersDetails,
    xftpSndWorkers_ :: Map Text WorkersDetails,
    xftpDelWorkers_ :: Map Text WorkersDetails
  }
  deriving (Show)

data WorkersDetails = WorkersDetails
  { restarts :: Int,
    hasWork :: Bool,
    hasAction :: Bool
  }
  deriving (Show)

getAgentWorkersDetails :: AgentClient -> IO AgentWorkersDetails
getAgentWorkersDetails AgentClient {smpClients, ntfClients, xftpClients, smpDeliveryWorkers, asyncCmdWorkers, smpSubWorkers, agentEnv} = do
  smpClients_ <- textKeys <$> readTVarIO smpClients
  ntfClients_ <- textKeys <$> readTVarIO ntfClients
  xftpClients_ <- textKeys <$> readTVarIO xftpClients
  smpDeliveryWorkers_ <- workerStats . fmap fst =<< readTVarIO smpDeliveryWorkers
  asyncCmdWorkers_ <- workerStats =<< readTVarIO asyncCmdWorkers
  smpSubWorkers_ <- textKeys <$> readTVarIO smpSubWorkers
  ntfWorkers_ <- workerStats =<< readTVarIO ntfWorkers
  ntfSMPWorkers_ <- workerStats =<< readTVarIO ntfSMPWorkers
  xftpRcvWorkers_ <- workerStats =<< readTVarIO xftpRcvWorkers
  xftpSndWorkers_ <- workerStats =<< readTVarIO xftpSndWorkers
  xftpDelWorkers_ <- workerStats =<< readTVarIO xftpDelWorkers
  pure
    AgentWorkersDetails
      { smpClients_,
        ntfClients_,
        xftpClients_,
        smpDeliveryWorkers_,
        asyncCmdWorkers_,
        smpSubWorkers_,
        ntfWorkers_,
        ntfSMPWorkers_,
        xftpRcvWorkers_,
        xftpSndWorkers_,
        xftpDelWorkers_
      }
  where
    textKeys :: StrEncoding k => Map k v -> [Text]
    textKeys = map textKey . M.keys
    textKey :: StrEncoding k => k -> Text
    textKey = decodeASCII . strEncode
    workerStats :: StrEncoding k => Map k Worker -> IO (Map Text WorkersDetails)
    workerStats ws = fmap M.fromList . forM (M.toList ws) $ \(qa, Worker {restarts, doWork, action}) -> do
      RestartCount {restartCount} <- readTVarIO restarts
      hasWork <- atomically $ not <$> isEmptyTMVar doWork
      hasAction <- atomically $ not <$> isEmptyTMVar action
      pure (textKey qa, WorkersDetails {restarts = restartCount, hasWork, hasAction})
    Env {ntfSupervisor, xftpAgent} = agentEnv
    NtfSupervisor {ntfWorkers, ntfSMPWorkers} = ntfSupervisor
    XFTPAgent {xftpRcvWorkers, xftpSndWorkers, xftpDelWorkers} = xftpAgent

data AgentWorkersSummary = AgentWorkersSummary
  { smpClientsCount :: Int,
    ntfClientsCount :: Int,
    xftpClientsCount :: Int,
    smpDeliveryWorkersCount :: WorkersSummary,
    asyncCmdWorkersCount :: WorkersSummary,
    smpSubWorkersCount :: Int,
    ntfWorkersCount :: WorkersSummary,
    ntfSMPWorkersCount :: WorkersSummary,
    xftpRcvWorkersCount :: WorkersSummary,
    xftpSndWorkersCount :: WorkersSummary,
    xftpDelWorkersCount :: WorkersSummary
  }
  deriving (Show)

data WorkersSummary = WorkersSummary
  { numActive :: Int,
    numIdle :: Int,
    totalRestarts :: Int
  }
  deriving (Show)

getAgentWorkersSummary :: AgentClient -> IO AgentWorkersSummary
getAgentWorkersSummary AgentClient {smpClients, ntfClients, xftpClients, smpDeliveryWorkers, asyncCmdWorkers, smpSubWorkers, agentEnv} = do
  smpClientsCount <- M.size <$> readTVarIO smpClients
  ntfClientsCount <- M.size <$> readTVarIO ntfClients
  xftpClientsCount <- M.size <$> readTVarIO xftpClients
  smpDeliveryWorkersCount <- readTVarIO smpDeliveryWorkers >>= workerSummary . fmap fst
  asyncCmdWorkersCount <- readTVarIO asyncCmdWorkers >>= workerSummary
  smpSubWorkersCount <- M.size <$> readTVarIO smpSubWorkers
  ntfWorkersCount <- readTVarIO ntfWorkers >>= workerSummary
  ntfSMPWorkersCount <- readTVarIO ntfSMPWorkers >>= workerSummary
  xftpRcvWorkersCount <- readTVarIO xftpRcvWorkers >>= workerSummary
  xftpSndWorkersCount <- readTVarIO xftpSndWorkers >>= workerSummary
  xftpDelWorkersCount <- readTVarIO xftpDelWorkers >>= workerSummary
  pure
    AgentWorkersSummary
      { smpClientsCount,
        ntfClientsCount,
        xftpClientsCount,
        smpDeliveryWorkersCount,
        asyncCmdWorkersCount,
        smpSubWorkersCount,
        ntfWorkersCount,
        ntfSMPWorkersCount,
        xftpRcvWorkersCount,
        xftpSndWorkersCount,
        xftpDelWorkersCount
      }
  where
    Env {ntfSupervisor, xftpAgent} = agentEnv
    NtfSupervisor {ntfWorkers, ntfSMPWorkers} = ntfSupervisor
    XFTPAgent {xftpRcvWorkers, xftpSndWorkers, xftpDelWorkers} = xftpAgent
    workerSummary :: M.Map k Worker -> IO WorkersSummary
    workerSummary = liftIO . foldM byWork WorkersSummary {numActive = 0, numIdle = 0, totalRestarts = 0}
      where
        byWork WorkersSummary {numActive, numIdle, totalRestarts} Worker {action, restarts} = do
          RestartCount {restartCount} <- readTVarIO restarts
          ifM
            (atomically $ isJust <$> tryReadTMVar action)
            (pure WorkersSummary {numActive, numIdle = numIdle + 1, totalRestarts = totalRestarts + restartCount})
            (pure WorkersSummary {numActive = numActive + 1, numIdle, totalRestarts = totalRestarts + restartCount})

data AgentQueuesInfo = AgentQueuesInfo
  { msgQInfo :: TBQueueInfo,
    subQInfo :: TBQueueInfo,
    smpClientsQueues :: Map Text (Int, UTCTime, ClientInfo)
  }
  deriving (Show)

data ClientInfo
  = ClientInfoQueues {sndQInfo :: TBQueueInfo, rcvQInfo :: TBQueueInfo}
  | ClientInfoError {clientError :: (AgentErrorType, Maybe UTCTime)}
  | ClientInfoConnecting
  deriving (Show)

getAgentQueuesInfo :: AgentClient -> IO AgentQueuesInfo
getAgentQueuesInfo AgentClient {msgQ, subQ, smpClients} = do
  msgQInfo <- atomically $ getTBQueueInfo msgQ
  subQInfo <- atomically $ getTBQueueInfo subQ
  smpClientsMap <- readTVarIO smpClients
  let smpClientsMap' = M.mapKeys (decodeLatin1 . strEncode) smpClientsMap
  smpClientsQueues <- mapM getClientQueuesInfo smpClientsMap'
  pure AgentQueuesInfo {msgQInfo, subQInfo, smpClientsQueues}
  where
    getClientQueuesInfo :: SMPClientVar -> IO (Int, UTCTime, ClientInfo)
    getClientQueuesInfo SessionVar {sessionVar, sessionVarId, sessionVarTs} = do
      clientInfo <- atomically (tryReadTMVar sessionVar) >>= \case
        Just (Right c) -> do
          (sndQInfo, rcvQInfo) <- getProtocolClientQueuesInfo $ protocolClient c
          pure ClientInfoQueues {sndQInfo, rcvQInfo}
        Just (Left e) -> pure $ ClientInfoError e
        Nothing -> pure ClientInfoConnecting
      pure (sessionVarId, sessionVarTs, clientInfo)

$(J.deriveJSON defaultJSON ''AgentLocks)

$(J.deriveJSON (enumJSON $ dropPrefix "TS") ''ProtocolTestStep)

$(J.deriveJSON defaultJSON ''ProtocolTestFailure)

$(J.deriveJSON defaultJSON ''SubInfo)

$(J.deriveJSON defaultJSON ''SubscriptionsInfo)

$(J.deriveJSON defaultJSON ''WorkersDetails)

$(J.deriveJSON defaultJSON ''WorkersSummary)

$(J.deriveJSON defaultJSON {J.fieldLabelModifier = takeWhile (/= '_')} ''AgentWorkersDetails)

$(J.deriveJSON defaultJSON ''AgentWorkersSummary)

$(J.deriveJSON (sumTypeJSON $ dropPrefix "ClientInfo") ''ClientInfo)

$(J.deriveJSON defaultJSON ''AgentQueuesInfo)

$(J.deriveJSON (enumJSON $ dropPrefix "UN") ''UserNetworkType)

$(J.deriveJSON defaultJSON ''UserNetworkInfo)
