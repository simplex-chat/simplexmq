{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
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
{-# LANGUAGE PatternSynonyms #-}
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
    getMapLock,
    ipAddressProtected,
    closeAgentClient,
    closeProtocolServerClients,
    reconnectServerClients,
    reconnectSMPServer,
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
    secureSndQueue,
    enableQueueNotifications,
    EnableQueueNtfReq (..),
    enableQueuesNtfs,
    disableQueueNotifications,
    DisableQueueNtfReq,
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
    agentNtfCreateSubscriptions,
    agentNtfCheckSubscription,
    agentNtfCheckSubscriptions,
    agentNtfDeleteSubscription,
    agentXFTPDownloadChunk,
    agentXFTPNewChunk,
    agentXFTPUploadChunk,
    agentXFTPAddRecipients,
    agentXFTPDeleteChunk,
    agentCbDecrypt,
    cryptoError,
    sendAck,
    suspendQueue,
    deleteQueue,
    deleteQueues,
    logServer,
    logSecret,
    logSecret',
    removeSubscription,
    hasActiveSubscription,
    hasPendingSubscription,
    hasGetLock,
    releaseGetLock,
    activeClientSession,
    agentClientStore,
    agentDRG,
    ServerQueueInfo (..),
    AgentServersSummary (..),
    ServerSessions (..),
    SMPServerSubs (..),
    getAgentSubsTotal,
    getAgentServersSummary,
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
    getAgentWorker,
    getAgentWorker',
    cancelWorker,
    waitForWork,
    hasWorkToDo,
    hasWorkToDo',
    withWork,
    withWorkItems,
    agentOperations,
    agentOperationBracket,
    waitUntilActive,
    UserNetworkInfo (..),
    UserNetworkType (..),
    getFastNetworkConfig,
    waitForUserNetwork,
    isNetworkOnline,
    isOnline,
    throwWhenInactive,
    throwWhenNoDelivery,
    beginAgentOperation,
    endAgentOperation,
    waitUntilForeground,
    waitWhileSuspended,
    suspendSendingAndDatabase,
    suspendOperation,
    notifySuspended,
    whenSuspending,
    withStore,
    withStore',
    withStoreBatch,
    withStoreBatch',
    unsafeWithStore,
    storeError,
    userServers,
    pickServer,
    getNextServer,
    withNextSrv,
    incSMPServerStat,
    incSMPServerStat',
    incXFTPServerStat,
    incXFTPServerStat',
    incXFTPServerSizeStat,
    incNtfServerStat,
    incNtfServerStat',
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
import Control.Concurrent (ThreadId, killThread)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry)
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
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (isRight, partitionEithers)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find, foldl', partition)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Word (Word16)
import Network.Socket (HostName)
import Simplex.FileTransfer.Client (XFTPChunkSpec (..), XFTPClient, XFTPClientConfig (..), XFTPClientError)
import qualified Simplex.FileTransfer.Client as X
import Simplex.FileTransfer.Description (ChunkReplicaId (..), FileDigest (..), kb)
import Simplex.FileTransfer.Protocol (FileInfo (..), FileResponse)
import Simplex.FileTransfer.Transport (XFTPErrorType (DIGEST), XFTPRcvChunkSpec (..), XFTPVersion)
import qualified Simplex.FileTransfer.Transport as XFTP
import Simplex.FileTransfer.Types (DeletedSndChunkReplica (..), NewSndChunkReplica (..), RcvFileChunkReplica (..), SndFileChunk (..), SndFileChunkReplica (..))
import Simplex.FileTransfer.Util (uniqueCombine)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Stats
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.Common (DBStore, withTransaction)
import qualified Simplex.Messaging.Agent.Store.DB as DB
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
    EntityId (..),
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
    ProtocolType (..),
    ProtocolTypeI (..),
    QueueIdsKeys (..),
    RcvMessage (..),
    RcvNtfPublicDhKey,
    SMPMsgMeta (..),
    SProtocolType (..),
    SndPublicAuthKey,
    SubscriptionMode (..),
    QueueReqData (..),
    NewNtfCreds,
    UserProtocol,
    VersionRangeSMPC,
    VersionSMPC,
    XFTPServer,
    XFTPServerWithAuth,
    pattern NoEntity,
    senderCanSecure,
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
import System.Mem.Weak (Weak, deRefWeak)
import System.Random (randomR)
import UnliftIO (mapConcurrently, timeout)
import UnliftIO.Async (async)
import UnliftIO.Concurrent (forkIO, mkWeakThreadId)
import UnliftIO.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import qualified UnliftIO.Exception as E
import UnliftIO.STM
#if !defined(dbPostgres)
import qualified Database.SQLite.Simple as SQL
#endif

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
    subQ :: TBQueue ATransmission,
    msgQ :: TBQueue (ServerTransmissionBatch SMPVersion ErrorType BrokerMsg),
    smpServers :: TMap UserId (UserServers 'PSMP),
    smpClients :: TMap SMPTransportSession SMPClientVar,
    -- smpProxiedRelays:
    -- SMPTransportSession defines connection from proxy to relay,
    -- SMPServerWithAuth defines client connected to SMP proxy (with the same userId and entityId in TransportSession)
    smpProxiedRelays :: TMap SMPTransportSession SMPServerWithAuth,
    ntfServers :: TVar [NtfServer],
    ntfClients :: TMap NtfTransportSession NtfClientVar,
    xftpServers :: TMap UserId (UserServers 'PXFTP),
    xftpClients :: TMap XFTPTransportSession XFTPClientVar,
    useNetworkConfig :: TVar (NetworkConfig, NetworkConfig), -- (slow, fast) networks
    userNetworkInfo :: TVar UserNetworkInfo,
    userNetworkUpdated :: TVar (Maybe UTCTime),
    subscrConns :: TVar (Set ConnId),
    activeSubs :: TRcvQueues (SessionId, RcvQueue),
    pendingSubs :: TRcvQueues RcvQueue,
    removedSubs :: TMap (UserId, SMPServer, SMP.RecipientId) SMPClientError,
    workerSeq :: TVar Int,
    smpDeliveryWorkers :: TMap SndQAddr (Worker, TMVar ()),
    asyncCmdWorkers :: TMap (ConnId, Maybe SMPServer) Worker,
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
    clientId :: Int,
    agentEnv :: Env,
    proxySessTs :: TVar UTCTime,
    smpServersStats :: TMap (UserId, SMPServer) AgentSMPServerStats,
    xftpServersStats :: TMap (UserId, XFTPServer) AgentXFTPServerStats,
    ntfServersStats :: TMap (UserId, NtfServer) AgentNtfServerStats,
    srvStatsStartedAt :: TVar UTCTime
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
          | wId == workerId (toW w') = do
              rc <- readTVar restarts
              isActive <- readTVar $ active c
              checkRestarts isActive $ updateRestartCount t rc
          | otherwise =
              pure False -- there is a new worker in the map, no action
          where
            checkRestarts isActive rc
              | isActive && restartCount rc < maxRestarts = do
                  writeTVar restarts rc
                  hasWorkToDo' doWork
                  void $ tryPutTMVar action Nothing
                  notifyErr INTERNAL
                  pure True
              | otherwise = do
                  TM.delete key ws
                  when isActive $ notifyErr $ CRITICAL True
                  pure False
              where
                notifyErr err = do
                  let e = either ((", error: " <>) . show) (\_ -> ", no error") e_
                      msg = "Worker " <> name <> " for " <> show key <> " terminated " <> show (restartCount rc) <> " times" <> e
                  writeTBQueue (subQ c) ("", "", AEvt SAEConn $ ERR $ err msg)

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
    start = atomically . putTMVar action . Just =<< mkWeakThreadId =<< forkIO work

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
newAgentClient :: Int -> InitialAgentServers -> UTCTime -> Env -> IO AgentClient
newAgentClient clientId InitialAgentServers {smp, ntf, xftp, netCfg} currentTs agentEnv = do
  let cfg = config agentEnv
      qSize = tbqSize cfg
  proxySessTs <- newTVarIO =<< getCurrentTime
  acThread <- newTVarIO Nothing
  active <- newTVarIO True
  subQ <- newTBQueueIO qSize
  msgQ <- newTBQueueIO qSize
  smpServers <- newTVarIO $ M.map mkUserServers smp
  smpClients <- TM.emptyIO
  smpProxiedRelays <- TM.emptyIO
  ntfServers <- newTVarIO ntf
  ntfClients <- TM.emptyIO
  xftpServers <- newTVarIO $ M.map mkUserServers xftp
  xftpClients <- TM.emptyIO
  useNetworkConfig <- newTVarIO (slowNetworkConfig netCfg, netCfg)
  userNetworkInfo <- newTVarIO $ UserNetworkInfo UNOther True
  userNetworkUpdated <- newTVarIO Nothing
  subscrConns <- newTVarIO S.empty
  activeSubs <- RQ.empty
  pendingSubs <- RQ.empty
  removedSubs <- TM.emptyIO
  workerSeq <- newTVarIO 0
  smpDeliveryWorkers <- TM.emptyIO
  asyncCmdWorkers <- TM.emptyIO
  ntfNetworkOp <- newTVarIO $ AgentOpState False 0
  rcvNetworkOp <- newTVarIO $ AgentOpState False 0
  msgDeliveryOp <- newTVarIO $ AgentOpState False 0
  sndNetworkOp <- newTVarIO $ AgentOpState False 0
  databaseOp <- newTVarIO $ AgentOpState False 0
  agentState <- newTVarIO ASForeground
  getMsgLocks <- TM.emptyIO
  connLocks <- TM.emptyIO
  invLocks <- TM.emptyIO
  deleteLock <- createLockIO
  smpSubWorkers <- TM.emptyIO
  smpServersStats <- TM.emptyIO
  xftpServersStats <- TM.emptyIO
  ntfServersStats <- TM.emptyIO
  srvStatsStartedAt <- newTVarIO currentTs
  return
    AgentClient
      { acThread,
        active,
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
        clientId,
        agentEnv,
        proxySessTs,
        smpServersStats,
        xftpServersStats,
        ntfServersStats,
        srvStatsStartedAt
      }

slowNetworkConfig :: NetworkConfig -> NetworkConfig
slowNetworkConfig cfg@NetworkConfig {tcpConnectTimeout, tcpTimeout, tcpTimeoutPerKb} =
  cfg {tcpConnectTimeout = slow tcpConnectTimeout, tcpTimeout = slow tcpTimeout, tcpTimeoutPerKb = slow tcpTimeoutPerKb}
  where
    slow :: Integral a => a -> a
    slow t = (t * 3) `div` 2

agentClientStore :: AgentClient -> DBStore
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

instance ProtocolServerClient SMPVersion ErrorType BrokerMsg where
  type Client BrokerMsg = SMPConnectedClient
  getProtocolServerClient = getSMPServerClient
  type ProtoClient BrokerMsg = ProtocolClient SMPVersion ErrorType BrokerMsg
  protocolClient = connectedClient
  clientProtocolError = SMP
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'

instance ProtocolServerClient NTFVersion ErrorType NtfResponse where
  type Client NtfResponse = ProtocolClient NTFVersion ErrorType NtfResponse
  getProtocolServerClient = getNtfServerClient
  type ProtoClient NtfResponse = ProtocolClient NTFVersion ErrorType NtfResponse
  protocolClient = id
  clientProtocolError = NTF
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'

instance ProtocolServerClient XFTPVersion XFTPErrorType FileResponse where
  type Client FileResponse = XFTPClient
  getProtocolServerClient = getXFTPServerClient
  type ProtoClient FileResponse = XFTPClient
  protocolClient = id
  clientProtocolError = XFTP
  closeProtocolServerClient = X.closeXFTPClient
  clientServer = X.xftpClientServer
  clientTransportHost = X.xftpTransportHost

getSMPServerClient :: AgentClient -> SMPTransportSession -> AM SMPConnectedClient
getSMPServerClient c@AgentClient {active, smpClients, workerSeq} tSess = do
  unlessM (readTVarIO active) $ throwE INACTIVE
  ts <- liftIO getCurrentTime
  atomically (getSessVar workerSeq tSess smpClients ts)
    >>= either newClient (waitForProtocolClient c tSess smpClients)
  where
    newClient v = do
      prs <- liftIO TM.emptyIO
      smpConnectClient c tSess prs v

getSMPProxyClient :: AgentClient -> Maybe SMPServerWithAuth -> SMPTransportSession -> AM (SMPConnectedClient, Either AgentErrorType ProxiedRelay)
getSMPProxyClient c@AgentClient {active, smpClients, smpProxiedRelays, workerSeq} proxySrv_ destSess@(userId, destSrv, qId) = do
  unlessM (readTVarIO active) $ throwE INACTIVE
  proxySrv <- maybe (getNextServer c userId proxySrvs [destSrv]) pure proxySrv_
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
      prs <- liftIO TM.emptyIO
      -- we do not need to check if it is a new proxied relay session,
      -- as the client is just created and there are no sessions yet
      rv <- atomically $ either id id <$> getSessVar workerSeq destSrv prs ts
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
    newProxiedRelay (SMPConnectedClient smp prs) proxyAuth rv =
      tryAgentError (liftClient SMP (clientServer smp) $ connectSMPProxiedRelay smp destSrv proxyAuth) >>= \case
        Right sess -> do
          atomically $ putTMVar (sessionVar rv) (Right sess)
          pure $ Right sess
        Left e -> do
          atomically $ do
            unless (serverHostError e) $ do
              removeSessVar rv destSrv prs
              TM.delete destSess smpProxiedRelays
            putTMVar (sessionVar rv) (Left e)
            pure $ Left e
    waitForProxiedRelay :: SMPTransportSession -> ProxiedRelayVar -> AM (Either AgentErrorType ProxiedRelay)
    waitForProxiedRelay (_, srv, _) rv = do
      NetworkConfig {tcpConnectTimeout} <- getNetworkConfig c
      sess_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar $ sessionVar rv)
      pure $ case sess_ of
        Just (Right sess) -> Right sess
        Just (Left e) -> Left e
        Nothing -> Left $ BROKER (B.unpack $ strEncode srv) TIMEOUT

smpConnectClient :: AgentClient -> SMPTransportSession -> TMap SMPServer ProxiedRelayVar -> SMPClientVar -> AM SMPConnectedClient
smpConnectClient c@AgentClient {smpClients, msgQ, proxySessTs} tSess@(_, srv, _) prs v =
  newProtocolClient c tSess smpClients connectClient v
    `catchAgentError` \e -> lift (resubscribeSMPSession c tSess) >> throwE e
  where
    connectClient :: SMPClientVar -> AM SMPConnectedClient
    connectClient v' = do
      cfg <- lift $ getClientConfig c smpCfg
      g <- asks random
      env <- ask
      liftError (protocolClientError SMP $ B.unpack $ strEncode srv) $ do
        ts <- readTVarIO proxySessTs
        smp <- ExceptT $ getProtocolClient g tSess cfg (Just msgQ) ts $ smpClientDisconnected c tSess env v' prs
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
    removeClientAndSubs = atomically $ do
      removeSessVar v tSess smpClients
      ifM (readTVar active) removeSubs (pure ([], []))
      where
        sessId = sessionId $ thParams client
        removeSubs = do
          (qs, cs) <- RQ.getDelSessQueues tSess sessId $ activeSubs c
          RQ.batchAddQueues (pendingSubs c) qs
          -- this removes proxied relays that this client created sessions to
          destSrvs <- M.keys <$> readTVar prs
          forM_ destSrvs $ \destSrv -> TM.delete (userId, destSrv, qId) smpProxiedRelays
          pure (qs, cs)

    serverDown :: ([RcvQueue], [ConnId]) -> IO ()
    serverDown (qs, conns) = whenM (readTVarIO active) $ do
      notifySub "" $ hostEvent' DISCONNECT client
      unless (null conns) $ notifySub "" $ DOWN srv conns
      unless (null qs) $ do
        atomically $ mapM_ (releaseGetLock c) qs
        runReaderT (resubscribeSMPSession c tSess) env

    notifySub :: forall e. AEntityI e => ConnId -> AEvent e -> IO ()
    notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, AEvt (sAEntity @e) cmd)

resubscribeSMPSession :: AgentClient -> SMPTransportSession -> AM' ()
resubscribeSMPSession c@AgentClient {smpSubWorkers, workerSeq} tSess = do
  ts <- liftIO getCurrentTime
  atomically (getWorkerVar ts) >>= mapM_ (either newSubWorker (\_ -> pure ()))
  where
    getWorkerVar ts =
      ifM
        (not <$> RQ.hasSessQueues tSess (pendingSubs c))
        (pure Nothing) -- prevent race with cleanup and adding pending queues in another call
        (Just <$> getSessVar workerSeq tSess smpSubWorkers ts)
    newSubWorker v = do
      a <- async $ void (E.tryAny runSubWorker) >> atomically (cleanup v)
      atomically $ putTMVar (sessionVar v) a
    runSubWorker = do
      ri <- asks $ reconnectInterval . config
      withRetryForeground ri isForeground (isNetworkOnline c) $ \_ loop -> do
        pending <- liftIO $ RQ.getSessQueues tSess $ pendingSubs c
        forM_ (L.nonEmpty pending) $ \qs -> do
          liftIO $ waitUntilForeground c
          liftIO $ waitForUserNetwork c
          reconnectSMPClient c tSess qs
          loop
    isForeground = (ASForeground ==) <$> readTVar (agentState c)
    cleanup :: SessionVar (Async ()) -> STM ()
    cleanup v = do
      -- Here we wait until TMVar is not empty to prevent worker cleanup happening before worker is added to TMVar.
      -- Not waiting may result in terminated worker remaining in the map.
      whenM (isEmptyTMVar $ sessionVar v) retry
      removeSessVar v tSess smpSubWorkers

reconnectSMPClient :: AgentClient -> SMPTransportSession -> NonEmpty RcvQueue -> AM' ()
reconnectSMPClient c tSess@(_, srv, _) qs = handleNotify $ do
  cs <- readTVarIO $ RQ.getConnections $ activeSubs c
  (rs, sessId_) <- subscribeQueues c $ L.toList qs
  let (errs, okConns) = partitionEithers $ map (\(RcvQueue {connId}, r) -> bimap (connId,) (const connId) r) rs
      conns = filter (`M.notMember` cs) okConns
  unless (null conns) $ notifySub "" $ UP srv conns
  let (tempErrs, finalErrs) = partition (temporaryAgentError . snd) errs
  mapM_ (\(connId, e) -> notifySub connId $ ERR e) finalErrs
  forM_ (listToMaybe tempErrs) $ \(connId, e) -> do
    when (null okConns && M.null cs && null finalErrs) . liftIO $
      forM_ sessId_ $ \sessId -> do
        -- We only close the client session that was used to subscribe.
        v_ <- atomically $ ifM (activeClientSession c tSess sessId) (TM.lookupDelete tSess $ smpClients c) (pure Nothing)
        mapM_ (closeClient_ c) v_
    notifySub connId $ ERR e
  where
    handleNotify :: AM' () -> AM' ()
    handleNotify = E.handleAny $ notifySub "" . ERR . INTERNAL . show
    notifySub :: forall e. AEntityI e => ConnId -> AEvent e -> AM' ()
    notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, AEvt (sAEntity @e) cmd)

getNtfServerClient :: AgentClient -> NtfTransportSession -> AM NtfClient
getNtfServerClient c@AgentClient {active, ntfClients, workerSeq, proxySessTs} tSess@(_, srv, _) = do
  unlessM (readTVarIO active) $ throwE INACTIVE
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
      ts <- readTVarIO proxySessTs
      liftError' (protocolClientError NTF $ B.unpack $ strEncode srv) $
        getProtocolClient g tSess cfg Nothing ts $
          clientDisconnected v

    clientDisconnected :: NtfClientVar -> NtfClient -> IO ()
    clientDisconnected v client = do
      atomically $ removeSessVar v tSess ntfClients
      atomically $ writeTBQueue (subQ c) ("", "", AEvt SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getXFTPServerClient :: AgentClient -> XFTPTransportSession -> AM XFTPClient
getXFTPServerClient c@AgentClient {active, xftpClients, workerSeq, proxySessTs} tSess@(_, srv, _) = do
  unlessM (readTVarIO active) $ throwE INACTIVE
  ts <- liftIO getCurrentTime
  atomically (getSessVar workerSeq tSess xftpClients ts)
    >>= either
      (newProtocolClient c tSess xftpClients connectClient)
      (waitForProtocolClient c tSess xftpClients)
  where
    connectClient :: XFTPClientVar -> AM XFTPClient
    connectClient v = do
      cfg <- asks $ xftpCfg . config
      xftpNetworkConfig <- getNetworkConfig c
      ts <- readTVarIO proxySessTs
      liftError' (protocolClientError XFTP $ B.unpack $ strEncode srv) $
        X.getXFTPClient tSess cfg {xftpNetworkConfig} ts $
          clientDisconnected v

    clientDisconnected :: XFTPClientVar -> XFTPClient -> IO ()
    clientDisconnected v client = do
      atomically $ removeSessVar v tSess xftpClients
      atomically $ writeTBQueue (subQ c) ("", "", AEvt SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

waitForProtocolClient ::
  (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) =>
  AgentClient ->
  TransportSession msg ->
  TMap (TransportSession msg) (ClientVar msg) ->
  ClientVar msg ->
  AM (Client msg)
waitForProtocolClient c tSess@(_, srv, _) clients v = do
  NetworkConfig {tcpConnectTimeout} <- getNetworkConfig c
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
      atomically $ writeTBQueue (subQ c) ("", "", AEvt SAENone $ hostEvent CONNECT client)
      pure client
    Left e -> do
      ei <- asks $ persistErrorInterval . config
      if ei == 0
        then atomically $ do
          removeSessVar v tSess clients
          putTMVar (sessionVar v) (Left (e, Nothing))
        else do
          ts <- addUTCTime ei <$> liftIO getCurrentTime
          atomically $ putTMVar (sessionVar v) (Left (e, Just ts))
      throwE e -- signal error to caller

hostEvent :: forall v err msg. (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) => (AProtocolType -> TransportHost -> AEvent 'AENone) -> Client msg -> AEvent 'AENone
hostEvent event = hostEvent' event . protocolClient
{-# INLINE hostEvent #-}

hostEvent' :: forall v err msg. (ProtocolTypeI (ProtoType msg), ProtocolServerClient v err msg) => (AProtocolType -> TransportHost -> AEvent 'AENone) -> ProtoClient msg -> AEvent 'AENone
hostEvent' event = event (AProtocolType $ protocolTypeI @(ProtoType msg)) . clientTransportHost

getClientConfig :: AgentClient -> (AgentConfig -> ProtocolClientConfig v) -> AM' (ProtocolClientConfig v)
getClientConfig c cfgSel = do
  cfg <- asks $ cfgSel . config
  networkConfig <- getNetworkConfig c
  pure cfg {networkConfig}

getNetworkConfig :: MonadIO m => AgentClient -> m NetworkConfig
getNetworkConfig c = do
  (slowCfg, fastCfg) <- readTVarIO $ useNetworkConfig c
  UserNetworkInfo {networkType} <- readTVarIO $ userNetworkInfo c
  pure $ case networkType of
    UNCellular -> slowCfg
    UNNone -> slowCfg
    _ -> fastCfg

-- returns fast network config
getFastNetworkConfig :: AgentClient -> IO NetworkConfig
getFastNetworkConfig = fmap snd . readTVarIO . useNetworkConfig
{-# INLINE getFastNetworkConfig #-}

waitForUserNetwork :: AgentClient -> IO ()
waitForUserNetwork c =
  unlessM (isOnline <$> readTVarIO (userNetworkInfo c)) $ do
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
  atomically (tryTakeTMVar action) >>= mapM_ (mapM_ $ deRefWeak >=> mapM_ killThread)

waitUntilActive :: AgentClient -> IO ()
waitUntilActive AgentClient {active} = unlessM (readTVarIO active) $ atomically $ unlessM (readTVar active) retry

throwWhenInactive :: AgentClient -> IO ()
throwWhenInactive c = unlessM (readTVarIO $ active c) $ E.throwIO ThreadKilled
{-# INLINE throwWhenInactive #-}

-- this function is used to remove workers once delivery is complete, not when it is removed from the map
throwWhenNoDelivery :: AgentClient -> SndQueue -> IO ()
throwWhenNoDelivery c sq =
  unlessM (TM.memberIO (qAddress sq) $ smpDeliveryWorkers c) $
    E.throwIO ThreadKilled

closeProtocolServerClients :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> IO ()
closeProtocolServerClients c clientsSel =
  atomically (clientsSel c `swapTVar` M.empty) >>= mapM_ (forkIO . closeClient_ c)

reconnectServerClients :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> IO ()
reconnectServerClients c clientsSel =
  readTVarIO (clientsSel c) >>= mapM_ (forkIO . closeClient_ c)

reconnectSMPServer :: AgentClient -> UserId -> SMPServer -> IO ()
reconnectSMPServer c userId srv = do
  cs <- readTVarIO $ smpClients c
  let vs = M.foldrWithKey srvClient [] cs
  mapM_ (forkIO . closeClient_ c) vs
  where
    srvClient (userId', srv', _) v
      | userId == userId' && srv == srv' = (v :)
      | otherwise = id

closeClient :: ProtocolServerClient v err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> TransportSession msg -> IO ()
closeClient c clientSel tSess =
  atomically (TM.lookupDelete tSess $ clientSel c) >>= mapM_ (closeClient_ c)

closeClient_ :: ProtocolServerClient v err msg => AgentClient -> ClientVar msg -> IO ()
closeClient_ c v = do
  NetworkConfig {tcpConnectTimeout} <- getNetworkConfig c
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

withClient_ :: forall a v err msg. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> (Client msg -> AM a) -> AM a
withClient_ c tSess@(_, srv, _) action = do
  cl <- getProtocolServerClient c tSess
  action cl `catchAgentError` logServerError
  where
    logServerError :: AgentErrorType -> AM a
    logServerError e = do
      logServer "<--" c srv NoEntity $ bshow e
      throwE e

withProxySession :: AgentClient -> Maybe SMPServerWithAuth -> SMPTransportSession -> SMP.SenderId -> ByteString -> ((SMPConnectedClient, ProxiedRelay) -> AM a) -> AM a
withProxySession c proxySrv_ destSess@(_, destSrv, _) entId cmdStr action = do
  (cl, sess_) <- getSMPProxyClient c proxySrv_ destSess
  logServer ("--> " <> proxySrv cl <> " >") c destSrv entId cmdStr
  case sess_ of
    Right sess -> do
      r <- action (cl, sess) `catchAgentError` logServerError cl
      logServer ("<-- " <> proxySrv cl <> " <") c destSrv entId "OK"
      pure r
    Left e -> logServerError cl e
  where
    proxySrv = showServer . protocolClientServer' . protocolClient
    logServerError :: SMPConnectedClient -> AgentErrorType -> AM a
    logServerError cl e = do
      logServer ("<-- " <> proxySrv cl <> " <") c destSrv NoEntity $ bshow e
      throwE e

withLogClient_ :: ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> ByteString -> ByteString -> (Client msg -> AM a) -> AM a
withLogClient_ c tSess@(_, srv, _) entId cmdStr action = do
  logServer' "-->" c srv entId cmdStr
  res <- withClient_ c tSess action
  logServer' "<--" c srv entId "OK"
  return res

withClient :: forall v err msg a. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> AM a
withClient c tSess action = withClient_ c tSess $ \client -> liftClient (clientProtocolError @v @err @msg) (clientServer $ protocolClient client) $ action client
{-# INLINE withClient #-}

withLogClient :: forall v err msg a. ProtocolServerClient v err msg => AgentClient -> TransportSession msg -> ByteString -> ByteString -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> AM a
withLogClient c tSess entId cmdStr action = withLogClient_ c tSess entId cmdStr $ \client -> liftClient (clientProtocolError @v @err @msg) (clientServer $ protocolClient client) $ action client
{-# INLINE withLogClient #-}

withSMPClient :: SMPQueueRec q => AgentClient -> q -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> AM a
withSMPClient c q cmdStr action = do
  tSess <- mkSMPTransportSession c q
  withLogClient c tSess (unEntityId $ queueId q) cmdStr $ action . connectedClient

sendOrProxySMPMessage :: AgentClient -> UserId -> SMPServer -> ConnId -> ByteString -> Maybe SMP.SndPrivateAuthKey -> SMP.SenderId -> MsgFlags -> SMP.MsgBody -> AM (Maybe SMPServer)
sendOrProxySMPMessage c userId destSrv connId cmdStr spKey_ senderId msgFlags msg =
  sendOrProxySMPCommand c userId destSrv connId cmdStr senderId sendViaProxy sendDirectly
  where
    sendViaProxy smp proxySess = do
      atomically $ incSMPServerStat c userId destSrv sentViaProxyAttempts
      atomically $ incSMPServerStat c userId (protocolClientServer' smp) sentProxiedAttempts
      proxySMPMessage smp proxySess spKey_ senderId msgFlags msg
    sendDirectly smp = do
      atomically $ incSMPServerStat c userId destSrv sentDirectAttempts
      sendSMPMessage smp spKey_ senderId msgFlags msg

sendOrProxySMPCommand ::
  AgentClient ->
  UserId ->
  SMPServer ->
  ConnId ->
  ByteString ->
  SMP.SenderId ->
  (SMPClient -> ProxiedRelay -> ExceptT SMPClientError IO (Either ProxyClientError ())) ->
  (SMPClient -> ExceptT SMPClientError IO ()) ->
  AM (Maybe SMPServer)
sendOrProxySMPCommand c userId destSrv@ProtocolServer {host = destHosts} connId cmdStr senderId sendCmdViaProxy sendCmdDirectly = do
  tSess <- mkTransportSession c userId destSrv connId
  ifM shouldUseProxy (sendViaProxy Nothing tSess) (sendDirectly tSess $> Nothing)
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
    unknownServer = liftIO $ maybe True (\srvs -> all (`S.notMember` knownHosts srvs) destHosts) <$> TM.lookupIO userId (smpServers c)
    sendViaProxy :: Maybe SMPServerWithAuth -> SMPTransportSession -> AM (Maybe SMPServer)
    sendViaProxy proxySrv_ destSess@(_, _, connId_) = do
      r <- tryAgentError . withProxySession c proxySrv_ destSess senderId ("PFWD " <> cmdStr) $ \(SMPConnectedClient smp _, proxySess@ProxiedRelay {prBasicAuth}) -> do
        r' <- liftClient SMP (clientServer smp) $ sendCmdViaProxy smp proxySess
        let proxySrv = protocolClientServer' smp
        case r' of
          Right () -> pure $ Just proxySrv
          Left proxyErr -> do
            case proxyErr of
              ProxyProtocolError (SMP.PROXY SMP.NO_SESSION) -> do
                atomically deleteRelaySession
                case proxySrv_ of
                  Just _ -> proxyError
                  -- sendViaProxy is called recursively here to re-create the session via the same server
                  -- to avoid failure in interactive calls that don't retry after the session disconnection.
                  Nothing -> sendViaProxy (Just $ ProtoServerWithAuth proxySrv prBasicAuth) destSess
              _ -> proxyError
            where
              proxyError =
                throwE
                  PROXY
                    { proxyServer = protocolClientServer smp,
                      relayServer = B.unpack $ strEncode destSrv,
                      proxyErr
                    }
              -- checks that the current proxied relay session is the same one that was used to send the message and removes it
              deleteRelaySession =
                ( TM.lookup destSess (smpProxiedRelays c)
                    $>>= \(ProtoServerWithAuth srv _) -> tryReadSessVar (userId, srv, connId_) (smpClients c)
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
        Right r' -> do
          atomically $ incSMPServerStat c userId destSrv sentViaProxy
          forM_ r' $ \proxySrv -> atomically $ incSMPServerStat c userId proxySrv sentProxied
          pure r'
        Left e
          | serverHostError e -> ifM directAllowed (sendDirectly destSess $> Nothing) (throwE e)
          | otherwise -> throwE e
    sendDirectly tSess =
      withLogClient_ c tSess (unEntityId senderId) ("SEND " <> cmdStr) $ \(SMPConnectedClient smp _) -> do
        r <- tryAgentError $ liftClient SMP (clientServer smp) $ sendCmdDirectly smp
        case r of
          Right () -> atomically $ incSMPServerStat c userId destSrv sentDirect
          Left e -> throwE e

ipAddressProtected :: NetworkConfig -> ProtocolServer p -> Bool
ipAddressProtected NetworkConfig {socksProxy, hostMode} (ProtocolServer _ hosts _ _) = do
  isJust socksProxy || (hostMode == HMOnion && any isOnionHost hosts)
  where
    isOnionHost = \case THOnionHost _ -> True; _ -> False

withNtfClient :: AgentClient -> NtfServer -> EntityId -> ByteString -> (NtfClient -> ExceptT NtfClientError IO a) -> AM a
withNtfClient c srv (EntityId entId) = withLogClient c (0, srv, Nothing) entId

withXFTPClient ::
  ProtocolServerClient v err msg =>
  AgentClient ->
  (UserId, ProtoServer msg, ByteString) ->
  ByteString ->
  (Client msg -> ExceptT (ProtocolClientError err) IO b) ->
  AM b
withXFTPClient c (userId, srv, sessEntId) cmdStr action = do
  tSess <- mkTransportSession c userId srv sessEntId
  withLogClient c tSess sessEntId cmdStr action

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
    ts <- readTVarIO $ proxySessTs c
    getProtocolClient g tSess cfg Nothing ts (\_ -> pure ()) >>= \case
      Right smp -> do
        rKeys@(_, rpKey) <- atomically $ C.generateAuthKeyPair ra g
        (sKey, spKey) <- atomically $ C.generateAuthKeyPair sa g
        (dhKey, _) <- atomically $ C.generateKeyPair g
        r <- runExceptT $ do
          SMP.QIK {rcvId, sndId, queueMode} <- liftError (testErr TSCreateQueue) $ createSMPQueue smp rKeys dhKey auth SMSubscribe (QRMessaging Nothing) Nothing
          liftError (testErr TSSecureQueue) $
            case queueMode of
              Just QMMessaging -> secureSndSMPQueue smp spKey sndId sKey
              _ -> secureSMPQueue smp rpKey rcvId sKey
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
  xftpNetworkConfig <- getNetworkConfig c
  workDir <- getXFTPWorkPath
  filePath <- getTempFilePath workDir
  rcvPath <- getTempFilePath workDir
  liftIO $ do
    let tSess = (userId, srv, Nothing)
    ts <- readTVarIO $ proxySessTs c
    X.getXFTPClient tSess cfg {xftpNetworkConfig} ts (\_ -> pure ()) >>= \case
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
          unless (digest == rcvDigest) $ throwE $ ProtocolTestFailure TSCompareFile $ XFTP (B.unpack $ strEncode srv) DIGEST
          liftError (testErr TSDeleteFile) $ X.deleteXFTPChunk xftp spKey sId
        ok <- tcpTimeout xftpNetworkConfig `timeout` X.closeXFTPClient xftp
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
    ts <- readTVarIO $ proxySessTs c
    getProtocolClient g tSess cfg Nothing ts (\_ -> pure ()) >>= \case
      Right ntf -> do
        (nKey, npKey) <- atomically $ C.generateAuthKeyPair a g
        (dhKey, _) <- atomically $ C.generateKeyPair g
        r <- runExceptT $ do
          let deviceToken = DeviceToken PPApnsNull "test_ntf_token"
          (tknId, _) <- liftError (testErr TSCreateNtfToken) $ ntfRegisterToken ntf npKey (NewNtfTkn deviceToken nKey dhKey)
          liftError (testErr TSDeleteNtfToken) $ ntfDeleteToken ntf npKey tknId
        ok <- tcpTimeout (networkConfig cfg) `timeout` closeProtocolClient ntf
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

mkTransportSession :: MonadIO m => AgentClient -> UserId -> ProtoServer msg -> ByteString -> m (TransportSession msg)
mkTransportSession c userId srv sessEntId = mkTSession userId srv sessEntId <$> getSessionMode c
{-# INLINE mkTransportSession #-}

mkTSession :: UserId -> ProtoServer msg -> ByteString -> TransportSessionMode -> TransportSession msg
mkTSession userId srv sessEntId mode = (userId, srv, if mode == TSMEntity then Just sessEntId else Nothing)
{-# INLINE mkTSession #-}

mkSMPTransportSession :: (SMPQueueRec q, MonadIO m) => AgentClient -> q -> m SMPTransportSession
mkSMPTransportSession c q = mkSMPTSession q <$> getSessionMode c
{-# INLINE mkSMPTransportSession #-}

mkSMPTSession :: SMPQueueRec q => q -> TransportSessionMode -> SMPTransportSession
mkSMPTSession q = mkTSession (qUserId q) (qServer q) (qConnId q)
{-# INLINE mkSMPTSession #-}

getSessionMode :: MonadIO m => AgentClient -> m TransportSessionMode
getSessionMode = fmap sessionMode . getNetworkConfig
{-# INLINE getSessionMode #-}

-- TODO [short links] add ntf credentials too RcvQueue
newRcvQueue :: AgentClient -> UserId -> ConnId -> SMPServerWithAuth -> VersionRangeSMPC -> SubscriptionMode -> QueueReqData -> Maybe NewNtfCreds -> AM (NewRcvQueue, SMPQueueUri, SMPTransportSession, SessionId)
newRcvQueue c userId connId (ProtoServerWithAuth srv auth) vRange subMode qrd ntfCreds = do
  C.AuthAlg a <- asks (rcvAuthAlg . config)
  g <- asks random
  rKeys@(_, rcvPrivateKey) <- atomically $ C.generateAuthKeyPair a g
  (dhKey, privDhKey) <- atomically $ C.generateKeyPair g
  (e2eDhKey, e2ePrivKey) <- atomically $ C.generateKeyPair g
  logServer "-->" c srv NoEntity "NEW"
  tSess <- mkTransportSession c userId srv connId
  (sessId, QIK {rcvId, sndId, rcvPublicDhKey, queueMode}) <-
    withClient c tSess $ \(SMPConnectedClient smp _) ->
      (sessionId $ thParams smp,) <$> createSMPQueue smp rKeys dhKey auth subMode qrd ntfCreds
  liftIO . logServer "<--" c srv NoEntity $ B.unwords ["IDS", logSecret rcvId, logSecret sndId]
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
            sndSecure,
            shortLink = Nothing, -- TODO [short links]
            status = New,
            dbQueueId = DBNewQueue,
            primary = True,
            dbReplaceQueueId = Nothing,
            rcvSwchStatus = Nothing,
            smpClientVersion = maxVersion vRange,
            clientNtfCreds = Nothing, -- TODO [short links]
            deleteErrors = 0
          }
      qUri = SMPQueueUri vRange $ SMPQueueAddress srv sndId e2eDhKey sndSecure
      -- TODO [short links]
      sndSecure = senderCanSecure queueMode
  pure (rq, qUri, tSess, sessId)

processSubResult :: AgentClient -> SessionId -> RcvQueue -> Either SMPClientError () -> STM ()
processSubResult c sessId rq@RcvQueue {userId, server, connId} = \case
  Left e ->
    unless (temporaryClientError e) $ do
      incSMPServerStat c userId server connSubErrs
      failSubscription c rq e
  Right () ->
    ifM
      (hasPendingSubscription c connId)
      (incSMPServerStat c userId server connSubscribed >> addSubscription c sessId rq)
      (incSMPServerStat c userId server connSubIgnored)

temporaryAgentError :: AgentErrorType -> Bool
temporaryAgentError = \case
  BROKER _ e -> tempBrokerError e
  SMP _ (SMP.PROXY (SMP.BROKER e)) -> tempBrokerError e
  XFTP _ XFTP.TIMEOUT -> True
  PROXY _ _ (ProxyProtocolError (SMP.PROXY (SMP.BROKER e))) -> tempBrokerError e
  PROXY _ _ (ProxyProtocolError (SMP.PROXY SMP.NO_SESSION)) -> True
  INACTIVE -> True
  CRITICAL True _ -> True -- critical errors that do not show restart button are likely to be permanent
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
  rs <- sendTSessionBatches "SUB" id (subscribeQueues_ env session) c qs'
  (errs <> rs,) <$> readTVarIO session
  where
    checkQueue rq = do
      prohibited <- liftIO $ hasGetLock c rq
      pure $ if prohibited then Left (rq, Left $ CMD PROHIBITED "subscribeQueues") else Right rq
    subscribeQueues_ :: Env -> TVar (Maybe SessionId) -> SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses RcvQueue SMPClientError ())
    subscribeQueues_ env session smp qs' = do
      let (userId, srv, _) = transportSession' smp
      atomically $ incSMPServerStat' c userId srv connSubAttempts $ length qs'
      rs <- sendBatch subscribeSMPQueues smp qs'
      active <-
        atomically $
          ifM
            (activeClientSession c tSess sessId)
            (writeTVar session (Just sessId) >> processSubResults rs $> True)
            (incSMPServerStat' c userId srv connSubIgnored (length rs) $> False)
      if active
        then when (hasTempErrors rs) resubscribe $> rs
        else do
          logWarn "subcription batch result for replaced SMP client, resubscribing"
          resubscribe $> L.map (second $ \_ -> Left PCENetworkError) rs
      where
        tSess = transportSession' smp
        sessId = sessionId $ thParams smp
        hasTempErrors = any (either temporaryClientError (const False) . snd)
        processSubResults :: NonEmpty (RcvQueue, Either SMPClientError ()) -> STM ()
        processSubResults = mapM_ $ uncurry $ processSubResult c sessId
        resubscribe = resubscribeSMPSession c tSess `runReaderT` env

activeClientSession :: AgentClient -> SMPTransportSession -> SessionId -> STM Bool
activeClientSession c tSess sessId = sameSess <$> tryReadSessVar tSess (smpClients c)
  where
    sameSess = \case
      Just (Right (SMPConnectedClient smp _)) -> sessId == sessionId (thParams smp)
      _ -> False

type BatchResponses q e r = NonEmpty (q, Either e r)

-- Please note: this function does not preserve order of results to be the same as the order of arguments,
-- it includes arguments in the results instead.
sendTSessionBatches :: forall q r. ByteString -> (q -> RcvQueue) -> (SMPClient -> NonEmpty q -> IO (BatchResponses q SMPClientError r)) -> AgentClient -> [q] -> AM' [(q, Either AgentErrorType r)]
sendTSessionBatches statCmd toRQ action c qs =
  concatMap L.toList <$> (mapConcurrently sendClientBatch =<< batchQueues)
  where
    batchQueues :: AM' [(SMPTransportSession, NonEmpty q)]
    batchQueues = do
      mode <- getSessionMode c
      pure . M.assocs $ foldr (batch mode) M.empty qs
      where
        batch mode q m =
          let tSess = mkSMPTSession (toRQ q) mode
           in M.alter (Just . maybe [q] (q <|)) tSess m
    sendClientBatch :: (SMPTransportSession, NonEmpty q) -> AM' (BatchResponses q AgentErrorType r)
    sendClientBatch (tSess@(_, srv, _), qs') =
      tryAgentError' (getSMPServerClient c tSess) >>= \case
        Left e -> pure $ L.map (,Left e) qs'
        Right (SMPConnectedClient smp _) -> liftIO $ do
          logServer' "-->" c srv (bshow (length qs') <> " queues") statCmd
          L.map agentError <$> action smp qs'
          where
            agentError = second . first $ protocolClientError SMP $ clientServer smp

sendBatch :: (SMPClient -> NonEmpty (SMP.RcvPrivateAuthKey, SMP.RecipientId) -> IO (NonEmpty (Either SMPClientError ()))) -> SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses RcvQueue SMPClientError ())
sendBatch smpCmdFunc smp qs = L.zip qs <$> smpCmdFunc smp (L.map queueCreds qs)
  where
    queueCreds RcvQueue {rcvPrivateKey, rcvId} = (rcvPrivateKey, rcvId)

addSubscription :: AgentClient -> SessionId -> RcvQueue -> STM ()
addSubscription c sessId rq@RcvQueue {connId} = do
  modifyTVar' (subscrConns c) $ S.insert connId
  RQ.addQueue (sessId, rq) $ activeSubs c
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
        (True <$ addSubscription c sessId rq)
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

getSubscriptions :: AgentClient -> IO (Set ConnId)
getSubscriptions = readTVarIO . subscrConns
{-# INLINE getSubscriptions #-}

logServer :: MonadIO m => ByteString -> AgentClient -> ProtocolServer s -> EntityId -> ByteString -> m ()
logServer dir c srv = logServer' dir c srv . unEntityId
{-# INLINE logServer #-}

logServer' :: MonadIO m => ByteString -> AgentClient -> ProtocolServer s -> ByteString -> ByteString -> m ()
logServer' dir AgentClient {clientId} srv qStr cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret' qStr, cmdStr]

showServer :: ProtocolServer s -> ByteString
showServer ProtocolServer {host, port} =
  strEncode host <> B.pack (if null port then "" else ':' : port)
{-# INLINE showServer #-}

logSecret :: EntityId -> ByteString
logSecret = logSecret' . unEntityId
{-# INLINE logSecret #-}

logSecret' :: ByteString -> ByteString
logSecret' = B64.encode . B.take 3
{-# INLINE logSecret' #-}

sendConfirmation :: AgentClient -> SndQueue -> ByteString -> AM (Maybe SMPServer)
sendConfirmation c sq@SndQueue {userId, server, connId, sndId, sndSecure, sndPublicKey, sndPrivateKey, e2ePubKey = e2ePubKey@Just {}} agentConfirmation = do
  let (privHdr, spKey) = if sndSecure then (SMP.PHEmpty, Just sndPrivateKey) else (SMP.PHConfirmation sndPublicKey, Nothing)
      clientMsg = SMP.ClientMessage privHdr agentConfirmation
  msg <- agentCbEncrypt sq e2ePubKey $ smpEncode clientMsg
  sendOrProxySMPMessage c userId server connId "<CONF>" spKey sndId (MsgFlags {notification = True}) msg
sendConfirmation _ _ _ = throwE $ INTERNAL "sendConfirmation called without snd_queue public key(s) in the database"

sendInvitation :: AgentClient -> UserId -> ConnId -> Compatible SMPQueueInfo -> Compatible VersionSMPA -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> AM (Maybe SMPServer)
sendInvitation c userId connId (Compatible (SMPQueueInfo v SMPQueueAddress {smpServer, senderId, dhPublicKey})) (Compatible agentVersion) connReq connInfo = do
  msg <- mkInvitation
  sendOrProxySMPMessage c userId smpServer connId "<INV>" Nothing senderId (MsgFlags {notification = True}) msg
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
  liftEither $ parse SMP.clientRcvMsgBodyP (AGENT A_MESSAGE) =<< decrypt body
  where
    decrypt = agentCbDecrypt (rcvDhSecret rq) (C.cbNonce msgId)

secureQueue :: AgentClient -> RcvQueue -> SndPublicAuthKey -> AM ()
secureQueue c rq@RcvQueue {rcvId, rcvPrivateKey} senderKey =
  withSMPClient c rq "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

secureSndQueue :: AgentClient -> SndQueue -> AM ()
secureSndQueue c SndQueue {userId, connId, server, sndId, sndPrivateKey, sndPublicKey} =
  void $ sendOrProxySMPCommand c userId server connId "SKEY <key>" sndId secureViaProxy secureDirectly
  where
    -- TODO track statistics
    secureViaProxy smp proxySess = proxySecureSndSMPQueue smp proxySess sndPrivateKey sndId sndPublicKey
    secureDirectly smp = secureSndSMPQueue smp sndPrivateKey sndId sndPublicKey

enableQueueNotifications :: AgentClient -> RcvQueue -> SMP.NtfPublicAuthKey -> SMP.RcvNtfPublicDhKey -> AM (SMP.NotifierId, SMP.RcvNtfPublicDhKey)
enableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} notifierKey rcvNtfPublicDhKey =
  withSMPClient c rq "NKEY <nkey>" $ \smp ->
    enableSMPQueueNotifications smp rcvPrivateKey rcvId notifierKey rcvNtfPublicDhKey

data EnableQueueNtfReq = EnableQueueNtfReq
  { eqnrNtfSub :: NtfSubscription,
    eqnrRq :: RcvQueue,
    eqnrAuthKeyPair :: C.AAuthKeyPair,
    eqnrRcvKeyPair :: C.KeyPairX25519
  }

enableQueuesNtfs :: AgentClient -> [EnableQueueNtfReq] -> AM' [(EnableQueueNtfReq, Either AgentErrorType (SMP.NotifierId, SMP.RcvNtfPublicDhKey))]
enableQueuesNtfs = sendTSessionBatches "NKEY" eqnrRq enableQueues_
  where
    enableQueues_ :: SMPClient -> NonEmpty EnableQueueNtfReq -> IO (NonEmpty (EnableQueueNtfReq, Either (ProtocolClientError ErrorType) (SMP.NotifierId, RcvNtfPublicDhKey)))
    enableQueues_ smp qs' = L.zip qs' <$> enableSMPQueuesNtfs smp (L.map queueCreds qs')
    queueCreds :: EnableQueueNtfReq -> (SMP.RcvPrivateAuthKey, SMP.RecipientId, SMP.NtfPublicAuthKey, SMP.RcvNtfPublicDhKey)
    queueCreds EnableQueueNtfReq {eqnrRq, eqnrAuthKeyPair, eqnrRcvKeyPair} =
      let RcvQueue {rcvPrivateKey, rcvId} = eqnrRq
          (ntfPublicKey, _) = eqnrAuthKeyPair
          (rcvNtfPubDhKey, _) = eqnrRcvKeyPair
       in (rcvPrivateKey, rcvId, ntfPublicKey, rcvNtfPubDhKey)

disableQueueNotifications :: AgentClient -> RcvQueue -> AM ()
disableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "NDEL" $ \smp ->
    disableSMPQueueNotifications smp rcvPrivateKey rcvId

type DisableQueueNtfReq = (NtfSubscription, RcvQueue)

disableQueuesNtfs :: AgentClient -> [DisableQueueNtfReq] -> AM' [(DisableQueueNtfReq, Either AgentErrorType ())]
disableQueuesNtfs = sendTSessionBatches "NDEL" snd disableQueues_
  where
    disableQueues_ :: SMPClient -> NonEmpty DisableQueueNtfReq -> IO (NonEmpty (DisableQueueNtfReq, Either (ProtocolClientError ErrorType) ()))
    disableQueues_ smp qs' = L.zip qs' <$> disableSMPQueuesNtfs smp (L.map queueCreds qs')
    queueCreds :: DisableQueueNtfReq -> (SMP.RcvPrivateAuthKey, SMP.RecipientId)
    queueCreds (_, RcvQueue {rcvPrivateKey, rcvId}) = (rcvPrivateKey, rcvId)

sendAck :: AgentClient -> RcvQueue -> MsgId -> AM ()
sendAck c rq@RcvQueue {rcvId, rcvPrivateKey} msgId =
  withSMPClient c rq ("ACK:" <> logSecret' msgId) $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId msgId

hasGetLock :: AgentClient -> RcvQueue -> IO Bool
hasGetLock c RcvQueue {server, rcvId} =
  TM.memberIO (server, rcvId) $ getMsgLocks c

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
deleteQueues c = sendTSessionBatches "DEL" id deleteQueues_ c
  where
    deleteQueues_ smp rqs = do
      let (userId, srv, _) = transportSession' smp
      atomically $ incSMPServerStat' c userId srv connDelAttempts $ length rqs
      rs <- sendBatch deleteSMPQueues smp rqs
      let successes = foldl' (\n (_, r) -> if isRight r then n + 1 else n) 0 rs
      atomically $ incSMPServerStat' c userId srv connDeleted successes
      pure rs

sendAgentMessage :: AgentClient -> SndQueue -> MsgFlags -> ByteString -> AM (Maybe SMPServer)
sendAgentMessage c sq@SndQueue {userId, server, connId, sndId, sndPrivateKey} msgFlags agentMsg = do
  let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
  msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
  sendOrProxySMPMessage c userId server connId "<MSG>" (Just sndPrivateKey) sndId msgFlags msg

data ServerQueueInfo = ServerQueueInfo
  { server :: SMPServer,
    rcvId :: Text,
    sndId :: Text,
    ntfId :: Maybe Text,
    status :: Text,
    info :: QueueInfo
  }
  deriving (Show)

getQueueInfo :: AgentClient -> RcvQueue -> AM ServerQueueInfo
getQueueInfo c rq@RcvQueue {server, rcvId, rcvPrivateKey, sndId, status, clientNtfCreds} =
  withSMPClient c rq "QUE" $ \smp -> do
    info <- getSMPQueueInfo smp rcvPrivateKey rcvId
    let ntfId = enc . (\ClientNtfCreds {notifierId} -> notifierId) <$> clientNtfCreds
    pure ServerQueueInfo {server, rcvId = enc rcvId, sndId = enc sndId, ntfId, status = serializeQueueStatus status, info}
  where
    enc = decodeLatin1 . B64.encode . unEntityId

agentNtfRegisterToken :: AgentClient -> NtfToken -> NtfPublicAuthKey -> C.PublicKeyX25519 -> AM (NtfTokenId, C.PublicKeyX25519)
agentNtfRegisterToken c NtfToken {deviceToken, ntfServer, ntfPrivKey} ntfPubKey pubDhKey =
  withClient c (0, ntfServer, Nothing) $ \ntf -> ntfRegisterToken ntf ntfPrivKey (NewNtfTkn deviceToken ntfPubKey pubDhKey)

agentNtfVerifyToken :: AgentClient -> NtfTokenId -> NtfToken -> NtfRegCode -> AM ()
agentNtfVerifyToken c tknId NtfToken {ntfServer, ntfPrivKey} code =
  withNtfClient c ntfServer tknId "TVFY" $ \ntf -> ntfVerifyToken ntf ntfPrivKey tknId code

agentNtfCheckToken :: AgentClient -> NtfTokenId -> NtfToken -> AM NtfTknStatus
agentNtfCheckToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer tknId "TCHK" $ \ntf -> ntfCheckToken ntf ntfPrivKey tknId

agentNtfReplaceToken :: AgentClient -> NtfTokenId -> NtfToken -> DeviceToken -> AM ()
agentNtfReplaceToken c tknId NtfToken {ntfServer, ntfPrivKey} token =
  withNtfClient c ntfServer tknId "TRPL" $ \ntf -> ntfReplaceToken ntf ntfPrivKey tknId token

agentNtfDeleteToken :: AgentClient -> NtfServer -> C.APrivateAuthKey -> NtfTokenId -> AM ()
agentNtfDeleteToken c ntfServer ntfPrivKey tknId =
  withNtfClient c ntfServer tknId "TDEL" $ \ntf -> ntfDeleteToken ntf ntfPrivKey tknId

agentNtfEnableCron :: AgentClient -> NtfTokenId -> NtfToken -> Word16 -> AM ()
agentNtfEnableCron c tknId NtfToken {ntfServer, ntfPrivKey} interval =
  withNtfClient c ntfServer tknId "TCRN" $ \ntf -> ntfEnableCron ntf ntfPrivKey tknId interval

agentNtfCreateSubscription :: AgentClient -> NtfTokenId -> NtfToken -> SMPQueueNtf -> SMP.NtfPrivateAuthKey -> AM NtfSubscriptionId
agentNtfCreateSubscription c tknId NtfToken {ntfServer, ntfPrivKey} smpQueue nKey =
  withNtfClient c ntfServer tknId "SNEW" $ \ntf -> ntfCreateSubscription ntf ntfPrivKey (NewNtfSub tknId smpQueue nKey)

agentNtfCreateSubscriptions :: AgentClient -> NtfToken -> NonEmpty (NewNtfEntity 'Subscription) -> AM' (NonEmpty (Either AgentErrorType NtfSubscriptionId))
agentNtfCreateSubscriptions = withNtfBatch "SNEW" ntfCreateSubscriptions

agentNtfCheckSubscription :: AgentClient -> NtfToken -> NtfSubscriptionId -> AM NtfSubStatus
agentNtfCheckSubscription c NtfToken {ntfServer, ntfPrivKey} subId =
  withNtfClient c ntfServer subId "SCHK" $ \ntf -> ntfCheckSubscription ntf ntfPrivKey subId

agentNtfCheckSubscriptions :: AgentClient -> NtfToken -> NonEmpty NtfSubscriptionId -> AM' (NonEmpty (Either AgentErrorType NtfSubStatus))
agentNtfCheckSubscriptions = withNtfBatch "SCHK" ntfCheckSubscriptions

-- This batch sends all commands to one ntf server (client can only use one server at a time)
withNtfBatch ::
  ByteString ->
  (NtfClient -> C.APrivateAuthKey -> NonEmpty a -> IO (NonEmpty (Either NtfClientError r))) ->
  AgentClient ->
  NtfToken ->
  NonEmpty a ->
  AM' (NonEmpty (Either AgentErrorType r))
withNtfBatch cmdStr action c NtfToken {ntfServer, ntfPrivKey} subs = do
  let tSess = (0, ntfServer, Nothing)
  tryAgentError' (getNtfServerClient c tSess) >>= \case
    Left e -> pure $ L.map (\_ -> Left e) subs
    Right ntf -> liftIO $ do
      logServer' "-->" c ntfServer (bshow (length subs) <> " subscriptions") cmdStr
      L.map agentError <$> action ntf ntfPrivKey subs
      where
        agentError = first $ protocolClientError NTF $ clientServer ntf

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
  logServer "-->" c srv NoEntity "FNEW"
  tSess <- mkTransportSession c userId srv chunkDigest
  (sndId, rIds) <- withClient c tSess $ \xftp -> X.createXFTPChunk xftp replicaKey fileInfo (L.map fst rKeys) auth
  logServer "<--" c srv NoEntity $ B.unwords ["SIDS", logSecret sndId]
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
    _ -> throwE $ INTERNAL "non-positive number of recipients"

xftpRcvIdsKeys :: NonEmpty EntityId -> NonEmpty C.AAuthKeyPair -> NonEmpty (ChunkReplicaId, C.APrivateAuthKey)
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
agentCbDecrypt :: C.DhSecretX25519 -> C.CbNonce -> ByteString -> Either AgentErrorType ByteString
agentCbDecrypt dhSecret nonce msg =
  first cryptoError $
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
    -- worker is stopped here (noWork) because the next iteration is likely to produce the same result
    Left e@SEWorkItemError {} -> noWork >> notifyErr (CRITICAL False) e
    Left e -> notifyErr INTERNAL e
  where
    noWork = liftIO $ noWorkToDo doWork
    notifyErr err e = atomically $ writeTBQueue (subQ c) ("", "", AEvt SAEConn $ ERR $ err $ show e)

withWorkItems :: AgentClient -> TMVar () -> (DB.Connection -> IO (Either StoreError [Either StoreError a])) -> (NonEmpty a -> AM ()) -> AM ()
withWorkItems c doWork getWork action = do
  withStore' c getWork >>= \case
    Right [] -> noWork
    Right rs -> do
      let (errs, items) = partitionEithers rs
      case L.nonEmpty items of
        Just items' -> action items'
        Nothing -> do
          let criticalErr = find workItemError errs
          forM_ criticalErr $ \err -> do
            notifyErr (CRITICAL False) err
            when (all workItemError errs) noWork
      unless (null errs) $
        atomically $
          writeTBQueue (subQ c) ("", "", AEvt SAENone $ ERRS $ map (\e -> ("", INTERNAL $ show e)) errs)
    Left e
      | workItemError e -> noWork >> notifyErr (CRITICAL False) e
      | otherwise -> notifyErr INTERNAL e
  where
    workItemError = \case
      SEWorkItemError {} -> True
      _ -> False
    noWork = liftIO $ noWorkToDo doWork
    notifyErr err e = atomically $ writeTBQueue (subQ c) ("", "", AEvt SAEConn $ ERR $ err $ show e)

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
  writeTBQueue (subQ c) ("", "", AEvt SAENone SUSPENDED)
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

agentOperationBracket :: MonadUnliftIO m => AgentClient -> AgentOperation -> (AgentClient -> IO ()) -> m a -> m a
agentOperationBracket c op check action =
  E.bracket
    (liftIO (check c) >> atomically (beginAgentOperation c op))
    (\_ -> atomically $ endAgentOperation c op)
    (const action)

waitUntilForeground :: AgentClient -> IO ()
waitUntilForeground c =
  unlessM (foreground readTVarIO) $ atomically $ unlessM (foreground readTVar) retry
  where
    foreground :: Monad m => (TVar AgentState -> m AgentState) -> m Bool
    foreground rd = (ASForeground ==) <$> rd (agentState c)

-- This function waits while agent is suspended, but will proceed while it is suspending,
-- to allow completing in-flight operations.
waitWhileSuspended :: AgentClient -> IO ()
waitWhileSuspended c =
  whenM (suspended readTVarIO) $ atomically $ whenM (suspended readTVar) retry
  where
    suspended :: Monad m => (TVar AgentState -> m AgentState) -> m Bool
    suspended rd = (ASSuspended ==) <$> rd (agentState c)

withStore' :: AgentClient -> (DB.Connection -> IO a) -> AM a
withStore' c action = withStore c $ fmap Right . action
{-# INLINE withStore' #-}

withStore :: AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> AM a
withStore c action = do
  st <- asks store
  withExceptT storeError . ExceptT . liftIO . agentOperationBracket c AODatabase (\_ -> pure ()) $
    withTransaction st action `E.catches` handleDBErrors
  where
#if defined(dbPostgres)
    -- TODO [postgres] postgres specific error handling
    handleDBErrors :: [E.Handler IO (Either StoreError a)]
    handleDBErrors =
      [ E.Handler $ \(E.SomeException e) -> pure . Left $ SEInternal $ bshow e
      ]
#else
    handleDBErrors :: [E.Handler IO (Either StoreError a)]
    handleDBErrors =
      [ E.Handler $ \(e :: SQL.SQLError) ->
          let se = SQL.sqlError e
              busy = se == SQL.ErrorBusy || se == SQL.ErrorLocked
           in pure . Left . (if busy then SEDatabaseBusy else SEInternal) $ bshow se,
        E.Handler $ \(E.SomeException e) -> pure . Left $ SEInternal $ bshow e
      ]
#endif

unsafeWithStore :: AgentClient -> (DB.Connection -> IO a) -> AM' a
unsafeWithStore c action = do
  st <- asks store
  liftIO $ agentOperationBracket c AODatabase (\_ -> pure ()) $ withTransaction st action

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
  SEUserNotFound -> NO_USER
  SERatchetNotFound -> CONN NOT_FOUND
  SEConnDuplicate -> CONN DUPLICATE
  SEBadConnType CRcv -> CONN SIMPLEX
  SEBadConnType CSnd -> CONN SIMPLEX
  SEInvitationNotFound cxt invId -> CMD PROHIBITED $ "SEInvitationNotFound " <> cxt <> ", invitationId = " <> show invId
  -- this error is never reported as store error,
  -- it is used to wrap agent operations when "transaction-like" store access is needed
  -- NOTE: network IO should NOT be used inside AgentStoreMonad
  SEAgentError e -> e
  SEDatabaseBusy e -> CRITICAL True $ B.unpack e
  e -> INTERNAL $ show e

userServers :: forall p. (ProtocolTypeI p, UserProtocol p) => AgentClient -> TMap UserId (UserServers p)
userServers c = case protocolTypeI @p of
  SPSMP -> smpServers c
  SPXFTP -> xftpServers c
{-# INLINE userServers #-}

pickServer :: NonEmpty (Maybe OperatorId, ProtoServerWithAuth p) -> AM (ProtoServerWithAuth p)
pickServer = \case
  (_, srv) :| [] -> pure srv
  servers -> do
    gen <- asks randomServer
    atomically $ snd . (servers L.!!) <$> stateTVar gen (randomR (0, L.length servers - 1))

getNextServer ::
  (ProtocolTypeI p, UserProtocol p) =>
  AgentClient ->
  UserId ->
  (UserServers p -> NonEmpty (Maybe OperatorId, ProtoServerWithAuth p)) ->
  [ProtocolServer p] ->
  AM (ProtoServerWithAuth p)
getNextServer c userId srvsSel usedSrvs = do
  srvs <- getUserServers_ c userId srvsSel
  snd <$> getNextServer_ srvs (usedOperatorsHosts srvs usedSrvs)

usedOperatorsHosts :: NonEmpty (Maybe OperatorId, ProtoServerWithAuth p) -> [ProtocolServer p] -> (Set (Maybe OperatorId), Set TransportHost)
usedOperatorsHosts srvs usedSrvs = (usedOperators, usedHosts)
  where
    usedHosts = S.unions $ map serverHosts usedSrvs
    usedOperators = S.fromList $ mapMaybe usedOp $ L.toList srvs
    usedOp (op, srv) = if hasUsedHost srv then Just op else Nothing
    hasUsedHost (ProtoServerWithAuth srv _) = any (`S.member` usedHosts) $ serverHosts srv

getNextServer_ ::
  (ProtocolTypeI p, UserProtocol p) =>
  NonEmpty (Maybe OperatorId, ProtoServerWithAuth p) ->
  (Set (Maybe OperatorId), Set TransportHost) ->
  AM (NonEmpty (Maybe OperatorId, ProtoServerWithAuth p), ProtoServerWithAuth p)
getNextServer_ servers (usedOperators, usedHosts) = do
  -- choose from servers of unused operators, when possible
  let otherOpsSrvs = filterOrAll ((`S.notMember` usedOperators) . fst) servers
      -- choose from servers with unused hosts when possible
      unusedSrvs = filterOrAll (isUnusedServer usedHosts) otherOpsSrvs
  (otherOpsSrvs,) <$> pickServer unusedSrvs
  where
    filterOrAll p srvs = fromMaybe srvs $ L.nonEmpty $ L.filter p srvs

isUnusedServer :: Set TransportHost -> (Maybe OperatorId, ProtoServerWithAuth p) -> Bool
isUnusedServer usedHosts (_, ProtoServerWithAuth ProtocolServer {host} _) = all (`S.notMember` usedHosts) host

getUserServers_ ::
  (ProtocolTypeI p, UserProtocol p) =>
  AgentClient ->
  UserId ->
  (UserServers p -> NonEmpty (Maybe OperatorId, ProtoServerWithAuth p)) ->
  AM (NonEmpty (Maybe OperatorId, ProtoServerWithAuth p))
getUserServers_ c userId srvsSel =
  liftIO (TM.lookupIO userId $ userServers c) >>= \case
    Just srvs -> pure $ srvsSel srvs
    _ -> throwE $ INTERNAL "unknown userId - no user servers"

-- This function checks used servers and operators every time to allow
-- changing configuration while retry look is executing.
-- This function is not thread safe.
withNextSrv ::
  (ProtocolTypeI p, UserProtocol p) =>
  AgentClient ->
  UserId ->
  (UserServers p -> NonEmpty (Maybe OperatorId, ProtoServerWithAuth p)) ->
  TVar (Set TransportHost) ->
  [ProtocolServer p] ->
  (ProtoServerWithAuth p -> AM a) ->
  AM a
withNextSrv c userId srvsSel triedHosts usedSrvs action = do
  srvs <- getUserServers_ c userId srvsSel
  let (usedOperators, usedHosts) = usedOperatorsHosts srvs usedSrvs
  tried <- readTVarIO triedHosts
  let triedOrUsed = S.union tried usedHosts
  (otherOpsSrvs, srvAuth@(ProtoServerWithAuth srv _)) <- getNextServer_ srvs (usedOperators, triedOrUsed)
  let newHosts = serverHosts srv
      unusedSrvs = L.filter (isUnusedServer $ S.union triedOrUsed newHosts) otherOpsSrvs
      !tried' = if null unusedSrvs then S.empty else S.union tried newHosts
  atomically $ writeTVar triedHosts tried'
  action srvAuth

incSMPServerStat :: AgentClient -> UserId -> SMPServer -> (AgentSMPServerStats -> TVar Int) -> STM ()
incSMPServerStat c userId srv sel = incSMPServerStat' c userId srv sel 1

incSMPServerStat' :: AgentClient -> UserId -> SMPServer -> (AgentSMPServerStats -> TVar Int) -> Int -> STM ()
incSMPServerStat' = incServerStat (\AgentClient {smpServersStats = s} -> s) newAgentSMPServerStats

incXFTPServerStat :: AgentClient -> UserId -> XFTPServer -> (AgentXFTPServerStats -> TVar Int) -> STM ()
incXFTPServerStat c userId srv sel = incXFTPServerStat_ c userId srv sel 1
{-# INLINE incXFTPServerStat #-}

incXFTPServerStat' :: AgentClient -> UserId -> XFTPServer -> (AgentXFTPServerStats -> TVar Int) -> Int -> STM ()
incXFTPServerStat' = incXFTPServerStat_
{-# INLINE incXFTPServerStat' #-}

incXFTPServerSizeStat :: AgentClient -> UserId -> XFTPServer -> (AgentXFTPServerStats -> TVar Int64) -> Int64 -> STM ()
incXFTPServerSizeStat = incXFTPServerStat_
{-# INLINE incXFTPServerSizeStat #-}

incXFTPServerStat_ :: Num n => AgentClient -> UserId -> XFTPServer -> (AgentXFTPServerStats -> TVar n) -> n -> STM ()
incXFTPServerStat_ = incServerStat (\AgentClient {xftpServersStats = s} -> s) newAgentXFTPServerStats
{-# INLINE incXFTPServerStat_ #-}

incNtfServerStat :: AgentClient -> UserId -> NtfServer -> (AgentNtfServerStats -> TVar Int) -> STM ()
incNtfServerStat c userId srv sel = incNtfServerStat' c userId srv sel 1
{-# INLINE incNtfServerStat #-}

incNtfServerStat' :: AgentClient -> UserId -> NtfServer -> (AgentNtfServerStats -> TVar Int) -> Int -> STM ()
incNtfServerStat' = incServerStat (\AgentClient {ntfServersStats = s} -> s) newAgentNtfServerStats
{-# INLINE incNtfServerStat' #-}

incServerStat :: Num n => (AgentClient -> TMap (UserId, ProtocolServer p) s) -> STM s -> AgentClient -> UserId -> ProtocolServer p -> (s -> TVar n) -> n -> STM ()
incServerStat statsSel mkNewStats c userId srv sel n = do
  TM.lookup (userId, srv) (statsSel c) >>= \case
    Just v -> modifyTVar' (sel v) (+ n)
    Nothing -> do
      newStats <- mkNewStats
      modifyTVar' (sel newStats) (+ n)
      TM.insert (userId, srv) newStats (statsSel c)

data AgentServersSummary = AgentServersSummary
  { smpServersStats :: Map (UserId, SMPServer) AgentSMPServerStatsData,
    xftpServersStats :: Map (UserId, XFTPServer) AgentXFTPServerStatsData,
    ntfServersStats :: Map (UserId, NtfServer) AgentNtfServerStatsData,
    statsStartedAt :: UTCTime,
    smpServersSessions :: Map (UserId, SMPServer) ServerSessions,
    smpServersSubs :: Map (UserId, SMPServer) SMPServerSubs,
    xftpServersSessions :: Map (UserId, XFTPServer) ServerSessions,
    xftpRcvInProgress :: [XFTPServer],
    xftpSndInProgress :: [XFTPServer],
    xftpDelInProgress :: [XFTPServer],
    ntfServersSessions :: Map (UserId, NtfServer) ServerSessions
  }
  deriving (Show)

data SMPServerSubs = SMPServerSubs
  { ssActive :: Int, -- based on activeSubs
    ssPending :: Int -- based on pendingSubs
  }
  deriving (Show)

data ServerSessions = ServerSessions
  { ssConnected :: Int,
    ssErrors :: Int,
    ssConnecting :: Int
  }
  deriving (Show)

getAgentSubsTotal :: AgentClient -> [UserId] -> IO (SMPServerSubs, Bool)
getAgentSubsTotal c userIds = do
  ssActive <- getSubsCount activeSubs
  ssPending <- getSubsCount pendingSubs
  sess <- hasSession . M.toList =<< readTVarIO (smpClients c)
  pure (SMPServerSubs {ssActive, ssPending}, sess)
  where
    getSubsCount :: (AgentClient -> TRcvQueues q) -> IO Int
    getSubsCount subs = M.foldrWithKey' addSub 0 <$> readTVarIO (getRcvQueues $ subs c)
    addSub :: (UserId, SMPServer, SMP.RecipientId) -> q -> Int -> Int
    addSub (userId, _, _) _ cnt = if userId `elem` userIds then cnt + 1 else cnt
    hasSession :: [(SMPTransportSession, SMPClientVar)] -> IO Bool
    hasSession = \case
      [] -> pure False
      (s : ss) -> ifM (isConnected s) (pure True) (hasSession ss)
    isConnected ((userId, _, _), SessionVar {sessionVar})
      | userId `elem` userIds = atomically $ maybe False isRight <$> tryReadTMVar sessionVar
      | otherwise = pure False

getAgentServersSummary :: AgentClient -> IO AgentServersSummary
getAgentServersSummary c@AgentClient {smpServersStats, xftpServersStats, ntfServersStats, srvStatsStartedAt, agentEnv} = do
  sss <- mapM getAgentSMPServerStats =<< readTVarIO smpServersStats
  xss <- mapM getAgentXFTPServerStats =<< readTVarIO xftpServersStats
  nss <- mapM getAgentNtfServerStats =<< readTVarIO ntfServersStats
  statsStartedAt <- readTVarIO srvStatsStartedAt
  smpServersSessions <- countSessions =<< readTVarIO (smpClients c)
  smpServersSubs <- getServerSubs
  xftpServersSessions <- countSessions =<< readTVarIO (xftpClients c)
  xftpRcvInProgress <- catMaybes <$> getXFTPWorkerSrvs xftpRcvWorkers
  xftpSndInProgress <- catMaybes <$> getXFTPWorkerSrvs xftpSndWorkers
  xftpDelInProgress <- getXFTPWorkerSrvs xftpDelWorkers
  ntfServersSessions <- countSessions =<< readTVarIO (ntfClients c)
  pure
    AgentServersSummary
      { smpServersStats = sss,
        xftpServersStats = xss,
        ntfServersStats = nss,
        statsStartedAt,
        smpServersSessions,
        smpServersSubs,
        xftpServersSessions,
        xftpRcvInProgress,
        xftpSndInProgress,
        xftpDelInProgress,
        ntfServersSessions
      }
  where
    getServerSubs = do
      subs <- M.foldrWithKey' (addSub incActive) M.empty <$> readTVarIO (getRcvQueues $ activeSubs c)
      M.foldrWithKey' (addSub incPending) subs <$> readTVarIO (getRcvQueues $ pendingSubs c)
      where
        addSub f (userId, srv, _) _ = M.alter (Just . f . fromMaybe SMPServerSubs {ssActive = 0, ssPending = 0}) (userId, srv)
        incActive ss = ss {ssActive = ssActive ss + 1}
        incPending ss = ss {ssPending = ssPending ss + 1}
    Env {xftpAgent = XFTPAgent {xftpRcvWorkers, xftpSndWorkers, xftpDelWorkers}} = agentEnv
    getXFTPWorkerSrvs workers = foldM addSrv [] . M.toList =<< readTVarIO workers
      where
        addSrv acc (srv, Worker {doWork}) = do
          hasWork <- atomically $ not <$> isEmptyTMVar doWork
          pure $ if hasWork then srv : acc else acc
    countSessions :: Map (TransportSession msg) (ClientVar msg) -> IO (Map (UserId, ProtoServer msg) ServerSessions)
    countSessions = foldM addClient M.empty . M.toList
      where
        addClient !acc ((userId, srv, _), SessionVar {sessionVar}) = do
          c_ <- atomically $ tryReadTMVar sessionVar
          pure $ M.alter (Just . add c_) (userId, srv) acc
          where
            add c_ = modifySessions c_ . fromMaybe ServerSessions {ssConnected = 0, ssErrors = 0, ssConnecting = 0}
            modifySessions c_ ss = case c_ of
              Just (Right _) -> ss {ssConnected = ssConnected ss + 1}
              Just (Left _) -> ss {ssErrors = ssErrors ss + 1}
              Nothing -> ss {ssConnecting = ssConnecting ss + 1}

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
    getSubs :: (AgentClient -> TRcvQueues q) -> IO [SubInfo]
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
      clientInfo <-
        atomically (tryReadTMVar sessionVar) >>= \case
          Just (Right c) -> do
            (sndQInfo, rcvQInfo) <- getProtocolClientQueuesInfo $ protocolClient c
            pure ClientInfoQueues {sndQInfo, rcvQInfo}
          Just (Left e) -> pure $ ClientInfoError e
          Nothing -> pure ClientInfoConnecting
      pure (sessionVarId, sessionVarTs, clientInfo)

$(J.deriveJSON defaultJSON ''AgentLocks)

$(J.deriveJSON (enumJSON $ dropPrefix "TS") ''ProtocolTestStep)

$(J.deriveJSON defaultJSON ''ProtocolTestFailure)

$(J.deriveJSON defaultJSON ''ServerSessions)

$(J.deriveJSON defaultJSON ''SMPServerSubs)

$(J.deriveJSON defaultJSON ''AgentServersSummary)

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

$(J.deriveJSON defaultJSON ''ServerQueueInfo)
