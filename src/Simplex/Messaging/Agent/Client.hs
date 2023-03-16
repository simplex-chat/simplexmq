{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
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
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    SMPTestFailure (..),
    SMPTestStep (..),
    newAgentClient,
    withConnLock,
    closeAgentClient,
    closeProtocolServerClients,
    runSMPServerTest,
    mkTransportSession,
    newRcvQueue,
    subscribeQueues,
    getQueueMessage,
    decryptSMPMessage,
    addSubscription,
    getSubscriptions,
    sendConfirmation,
    sendInvitation,
    temporaryAgentError,
    temporaryOrHostError,
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
    agentXFTPDownloadChunk,
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
    agentClientStore,
    AgentOperation (..),
    AgentOpState (..),
    AgentState (..),
    AgentLocks (..),
    AgentStatsKey (..),
    agentOperations,
    agentOperationBracket,
    waitUntilActive,
    throwWhenInactive,
    throwWhenNoDelivery,
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

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry, throwSTM)
import Control.Exception (AsyncException (..))
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (lefts, partitionEithers)
import Data.Functor (($>))
import Data.List (foldl', partition)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, listToMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time (UTCTime)
import Data.Word (Word16)
import qualified Database.SQLite.Simple as DB
import GHC.Generics (Generic)
import Network.Socket (HostName)
import Simplex.FileTransfer.Client (XFTPClient, XFTPClientConfig (..))
import qualified Simplex.FileTransfer.Client as X
import Simplex.FileTransfer.Description (ChunkReplicaId (..))
import Simplex.FileTransfer.Protocol (FileResponse, XFTPErrorType)
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec)
import Simplex.FileTransfer.Types (RcvFileChunkReplica (..))
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore (..), withTransaction)
import Simplex.Messaging.Agent.TAsyncs
import Simplex.Messaging.Agent.TRcvQueues (TRcvQueues)
import qualified Simplex.Messaging.Agent.TRcvQueues as RQ
import Simplex.Messaging.Client
import Simplex.Messaging.Client.Agent ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (dropPrefix, enumJSON, parse)
import Simplex.Messaging.Protocol
  ( AProtocolType (..),
    BrokerMsg,
    EntityId,
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
    XFTPServerWithAuth,
  )
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Timeout (timeout)
import UnliftIO (mapConcurrently)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type ClientVar msg = TMVar (Either AgentErrorType (Client msg))

type SMPClientVar = ClientVar SMP.BrokerMsg

type NtfClientVar = ClientVar NtfResponse

type XFTPClientVar = TMVar (Either AgentErrorType XFTPClient)

type SMPTransportSession = TransportSession SMP.BrokerMsg

type NtfTransportSession = TransportSession NtfResponse

type XFTPTransportSession = TransportSession FileResponse

data AgentClient = AgentClient
  { active :: TVar Bool,
    rcvQ :: TBQueue (ATransmission 'Client),
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue (ServerTransmission BrokerMsg),
    smpServers :: TMap UserId (NonEmpty SMPServerWithAuth),
    smpClients :: TMap SMPTransportSession SMPClientVar,
    ntfServers :: TVar [NtfServer],
    ntfClients :: TMap NtfTransportSession NtfClientVar,
    xftpServers :: TMap UserId (NonEmpty XFTPServerWithAuth),
    xftpClients :: TMap XFTPTransportSession XFTPClientVar,
    useNetworkConfig :: TVar NetworkConfig,
    subscrConns :: TVar (Set ConnId),
    activeSubs :: TRcvQueues,
    pendingSubs :: TRcvQueues,
    pendingMsgsQueued :: TMap SndQAddr Bool,
    smpQueueMsgQueues :: TMap SndQAddr (TQueue InternalId, TMVar ()),
    smpQueueMsgDeliveries :: TMap SndQAddr (Async ()),
    connCmdsQueued :: TMap ConnId Bool,
    asyncCmdQueues :: TMap (Maybe SMPServer) (TQueue AsyncCmdId),
    asyncCmdProcesses :: TMap (Maybe SMPServer) (Async ()),
    ntfNetworkOp :: TVar AgentOpState,
    rcvNetworkOp :: TVar AgentOpState,
    msgDeliveryOp :: TVar AgentOpState,
    sndNetworkOp :: TVar AgentOpState,
    databaseOp :: TVar AgentOpState,
    agentState :: TVar AgentState,
    getMsgLocks :: TMap (SMPServer, SMP.RecipientId) (TMVar ()),
    -- locks to prevent concurrent operations with connection
    connLocks :: TMap ConnId Lock,
    -- lock to prevent concurrency between periodic and async connection deletions
    deleteLock :: Lock,
    -- locks to prevent concurrent reconnections to SMP servers
    reconnectLocks :: TMap SMPTransportSession Lock,
    reconnections :: TAsyncs,
    asyncClients :: TAsyncs,
    agentStats :: TMap AgentStatsKey (TVar Int),
    clientId :: Int,
    agentEnv :: Env
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

data AgentLocks = AgentLocks {connLocks :: Map String String, srvLocks :: Map String String, delLock :: Maybe String}
  deriving (Show, Generic)

instance ToJSON AgentLocks where toEncoding = J.genericToEncoding J.defaultOptions

data AgentStatsKey = AgentStatsKey
  { userId :: UserId,
    host :: ByteString,
    clientTs :: ByteString,
    cmd :: ByteString,
    res :: ByteString
  }
  deriving (Eq, Ord, Show)

newAgentClient :: InitialAgentServers -> Env -> STM AgentClient
newAgentClient InitialAgentServers {smp, ntf, xftp, netCfg} agentEnv = do
  let qSize = tbqSize $ config agentEnv
  active <- newTVar True
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpServers <- newTVar smp
  smpClients <- TM.empty
  ntfServers <- newTVar ntf
  ntfClients <- TM.empty
  xftpServers <- newTVar xftp
  xftpClients <- TM.empty
  useNetworkConfig <- newTVar netCfg
  subscrConns <- newTVar S.empty
  activeSubs <- RQ.empty
  pendingSubs <- RQ.empty
  pendingMsgsQueued <- TM.empty
  smpQueueMsgQueues <- TM.empty
  smpQueueMsgDeliveries <- TM.empty
  connCmdsQueued <- TM.empty
  asyncCmdQueues <- TM.empty
  asyncCmdProcesses <- TM.empty
  ntfNetworkOp <- newTVar $ AgentOpState False 0
  rcvNetworkOp <- newTVar $ AgentOpState False 0
  msgDeliveryOp <- newTVar $ AgentOpState False 0
  sndNetworkOp <- newTVar $ AgentOpState False 0
  databaseOp <- newTVar $ AgentOpState False 0
  agentState <- newTVar ASActive
  getMsgLocks <- TM.empty
  connLocks <- TM.empty
  deleteLock <- createLock
  reconnectLocks <- TM.empty
  reconnections <- newTAsyncs
  asyncClients <- newTAsyncs
  agentStats <- TM.empty
  clientId <- stateTVar (clientCounter agentEnv) $ \i -> let i' = i + 1 in (i', i')
  return
    AgentClient
      { active,
        rcvQ,
        subQ,
        msgQ,
        smpServers,
        smpClients,
        ntfServers,
        ntfClients,
        xftpServers,
        xftpClients,
        useNetworkConfig,
        subscrConns,
        activeSubs,
        pendingSubs,
        pendingMsgsQueued,
        smpQueueMsgQueues,
        smpQueueMsgDeliveries,
        connCmdsQueued,
        asyncCmdQueues,
        asyncCmdProcesses,
        ntfNetworkOp,
        rcvNetworkOp,
        msgDeliveryOp,
        sndNetworkOp,
        databaseOp,
        agentState,
        getMsgLocks,
        connLocks,
        deleteLock,
        reconnectLocks,
        reconnections,
        asyncClients,
        agentStats,
        clientId,
        agentEnv
      }

agentClientStore :: AgentClient -> SQLiteStore
agentClientStore AgentClient {agentEnv = Env {store}} = store

class (Encoding err, Show err) => ProtocolServerClient err msg | msg -> err where
  type Client msg = c | c -> msg
  getProtocolServerClient :: AgentMonad m => AgentClient -> TransportSession msg -> m (Client msg)
  clientProtocolError :: err -> AgentErrorType
  closeProtocolServerClient :: Client msg -> IO ()
  clientServer :: Client msg -> String
  clientTransportHost :: Client msg -> TransportHost
  clientSessionTs :: Client msg -> UTCTime

instance ProtocolServerClient ErrorType BrokerMsg where
  type Client BrokerMsg = ProtocolClient ErrorType BrokerMsg
  getProtocolServerClient = getSMPServerClient
  clientProtocolError = SMP
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'
  clientSessionTs = sessionTs

instance ProtocolServerClient ErrorType NtfResponse where
  type Client NtfResponse = ProtocolClient ErrorType NtfResponse
  getProtocolServerClient = getNtfServerClient
  clientProtocolError = NTF
  closeProtocolServerClient = closeProtocolClient
  clientServer = protocolClientServer
  clientTransportHost = transportHost'
  clientSessionTs = sessionTs

instance ProtocolServerClient XFTPErrorType FileResponse where
  type Client FileResponse = XFTPClient
  getProtocolServerClient = getXFTPServerClient
  clientProtocolError = XFTP
  closeProtocolServerClient = X.closeXFTPClient
  clientServer = X.xftpClientServer
  clientTransportHost = X.xftpTransportHost
  clientSessionTs = X.xftpSessionTs

getSMPServerClient :: forall m. AgentMonad m => AgentClient -> SMPTransportSession -> m SMPClient
getSMPServerClient c@AgentClient {active, smpClients, msgQ} tSess@(userId, srv, _) = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar tSess smpClients)
    >>= either
      (newProtocolClient c tSess smpClients connectClient reconnectSMPClient)
      (waitForProtocolClient c tSess)
  where
    connectClient :: m SMPClient
    connectClient = do
      cfg <- getClientConfig c smpCfg
      u <- askUnliftIO
      liftEitherError (protocolClientError SMP $ B.unpack $ strEncode srv) (getProtocolClient tSess cfg (Just msgQ) $ clientDisconnected u)

    clientDisconnected :: UnliftIO m -> SMPClient -> IO ()
    clientDisconnected u client = do
      removeClientAndSubs >>= serverDown
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv
      where
        removeClientAndSubs :: IO ([RcvQueue], [ConnId])
        removeClientAndSubs = atomically $ do
          TM.delete tSess smpClients
          qs <- RQ.getDelSessQueues tSess $ activeSubs c
          mapM_ (`RQ.addQueue` pendingSubs c) qs
          let cs = S.fromList $ map qConnId qs
          cs' <- RQ.getConns $ activeSubs c
          pure (qs, S.toList $ cs `S.difference` cs')

        serverDown :: ([RcvQueue], [ConnId]) -> IO ()
        serverDown (qs, conns) = whenM (readTVarIO active) $ do
          incClientStat c userId client "DISCONNECT" ""
          notifySub "" $ hostEvent DISCONNECT client
          unless (null conns) $ notifySub "" $ DOWN srv conns
          unless (null qs) $ do
            atomically $ mapM_ (releaseGetLock c) qs
            unliftIO u $ reconnectServer c tSess

        notifySub :: forall e. AEntityI e => ConnId -> ACommand 'Agent e -> IO ()
        notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, APC (sAEntity @e) cmd)

reconnectServer :: AgentMonad m => AgentClient -> SMPTransportSession -> m ()
reconnectServer c tSess = newAsyncAction tryReconnectSMPClient $ reconnections c
  where
    tryReconnectSMPClient aId = do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \_ loop ->
        reconnectSMPClient c tSess `catchError` const loop
      atomically . removeAsyncAction aId $ reconnections c

reconnectSMPClient :: forall m. AgentMonad m => AgentClient -> SMPTransportSession -> m ()
reconnectSMPClient c tSess@(_, srv, _) =
  withLockMap_ (reconnectLocks c) tSess "reconnect" $
    atomically (RQ.getSessQueues tSess $ pendingSubs c) >>= mapM_ resubscribe . L.nonEmpty
  where
    resubscribe :: NonEmpty RcvQueue -> m ()
    resubscribe qs = do
      cs <- atomically . RQ.getConns $ activeSubs c
      rs <- subscribeQueues c $ L.toList qs
      let (errs, okConns) = partitionEithers $ map (\(RcvQueue {connId}, r) -> bimap (connId,) (const connId) r) rs
      liftIO $ do
        let conns = S.toList $ S.fromList okConns `S.difference` cs
        unless (null conns) $ notifySub "" $ UP srv conns
      let (tempErrs, finalErrs) = partition (temporaryAgentError . snd) errs
      liftIO $ mapM_ (\(connId, e) -> notifySub connId $ ERR e) finalErrs
      mapM_ (throwError . snd) $ listToMaybe tempErrs
    notifySub :: forall e. AEntityI e => ConnId -> ACommand 'Agent e -> IO ()
    notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, APC (sAEntity @e) cmd)

getNtfServerClient :: forall m. AgentMonad m => AgentClient -> NtfTransportSession -> m NtfClient
getNtfServerClient c@AgentClient {active, ntfClients} tSess@(userId, srv, _) = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar tSess ntfClients)
    >>= either
      (newProtocolClient c tSess ntfClients connectClient $ \_ _ -> pure ())
      (waitForProtocolClient c tSess)
  where
    connectClient :: m NtfClient
    connectClient = do
      cfg <- getClientConfig c ntfCfg
      liftEitherError (protocolClientError NTF $ B.unpack $ strEncode srv) (getProtocolClient tSess cfg Nothing clientDisconnected)

    clientDisconnected :: NtfClient -> IO ()
    clientDisconnected client = do
      atomically $ TM.delete tSess ntfClients
      incClientStat c userId client "DISCONNECT" ""
      atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getXFTPServerClient :: forall m. AgentMonad m => AgentClient -> XFTPTransportSession -> m XFTPClient
getXFTPServerClient c@AgentClient {active, xftpClients, useNetworkConfig} tSess@(userId, srv, _) = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar tSess xftpClients)
    >>= either
      (newProtocolClient c tSess xftpClients connectClient $ \_ _ -> pure ())
      (waitForProtocolClient c tSess)
  where
    connectClient :: m XFTPClient
    connectClient = do
      cfg <- asks $ xftpCfg . config
      xftpNetworkConfig <- readTVarIO useNetworkConfig
      liftEitherError (protocolClientError XFTP $ B.unpack $ strEncode srv) (X.getXFTPClient tSess cfg {xftpNetworkConfig} clientDisconnected)

    clientDisconnected :: XFTPClient -> IO ()
    clientDisconnected client = do
      atomically $ TM.delete tSess xftpClients
      incClientStat c userId client "DISCONNECT" ""
      atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent DISCONNECT client)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getClientVar :: forall a s. TransportSession s -> TMap (TransportSession s) (TMVar a) -> STM (Either (TMVar a) (TMVar a))
getClientVar tSess clients = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup tSess clients
  where
    newClientVar :: STM (TMVar a)
    newClientVar = do
      var <- newEmptyTMVar
      TM.insert tSess var clients
      pure var

waitForProtocolClient :: (AgentMonad m, ProtocolTypeI (ProtoType msg)) => AgentClient -> TransportSession msg -> ClientVar msg -> m (Client msg)
waitForProtocolClient c (_, srv, _) clientVar = do
  NetworkConfig {tcpConnectTimeout} <- readTVarIO $ useNetworkConfig c
  client_ <- liftIO $ tcpConnectTimeout `timeout` atomically (readTMVar clientVar)
  liftEither $ case client_ of
    Just (Right smpClient) -> Right smpClient
    Just (Left e) -> Left e
    Nothing -> Left $ BROKER (B.unpack $ strEncode srv) TIMEOUT

newProtocolClient ::
  forall err msg m.
  (AgentMonad m, ProtocolTypeI (ProtoType msg), ProtocolServerClient err msg) =>
  AgentClient ->
  TransportSession msg ->
  TMap (TransportSession msg) (ClientVar msg) ->
  m (Client msg) ->
  (AgentClient -> TransportSession msg -> m ()) ->
  ClientVar msg ->
  m (Client msg)
newProtocolClient c tSess@(userId, srv, entityId_) clients connectClient reconnectClient clientVar = tryConnectClient pure tryConnectAsync
  where
    tryConnectClient :: (Client msg -> m a) -> m () -> m a
    tryConnectClient successAction retryAction =
      tryError connectClient >>= \r -> case r of
        Right client -> do
          logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv <> " (user " <> bshow userId <> maybe "" (" for entity " <>) entityId_ <> ")"
          atomically $ putTMVar clientVar r
          liftIO $ incClientStat c userId client "CLIENT" "OK"
          atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ hostEvent CONNECT client)
          successAction client
        Left e -> do
          liftIO $ incServerStat c userId srv "CLIENT" $ strEncode e
          if temporaryAgentError e
            then retryAction
            else atomically $ do
              putTMVar clientVar (Left e)
              TM.delete tSess clients
          throwError e
    tryConnectAsync :: m ()
    tryConnectAsync = newAsyncAction connectAsync $ asyncClients c
    connectAsync :: Int -> m ()
    connectAsync aId = do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \_ loop -> void $ tryConnectClient (const $ reconnectClient c tSess) loop
      atomically . removeAsyncAction aId $ asyncClients c

hostEvent :: forall err msg. (ProtocolTypeI (ProtoType msg), ProtocolServerClient err msg) => (AProtocolType -> TransportHost -> ACommand 'Agent 'AENone) -> Client msg -> ACommand 'Agent 'AENone
hostEvent event = event (AProtocolType $ protocolTypeI @(ProtoType msg)) . clientTransportHost

getClientConfig :: AgentMonad m => AgentClient -> (AgentConfig -> ProtocolClientConfig) -> m ProtocolClientConfig
getClientConfig AgentClient {useNetworkConfig} cfgSel = do
  cfg <- asks $ cfgSel . config
  networkConfig <- readTVarIO useNetworkConfig
  pure cfg {networkConfig}

closeAgentClient :: MonadIO m => AgentClient -> m ()
closeAgentClient c = liftIO $ do
  atomically $ writeTVar (active c) False
  closeProtocolServerClients c smpClients
  closeProtocolServerClients c ntfClients
  closeProtocolServerClients c xftpClients
  cancelActions . actions $ reconnections c
  cancelActions . actions $ asyncClients c
  cancelActions $ smpQueueMsgDeliveries c
  cancelActions $ asyncCmdProcesses c
  atomically . RQ.clear $ activeSubs c
  atomically . RQ.clear $ pendingSubs c
  clear subscrConns
  clear pendingMsgsQueued
  clear smpQueueMsgQueues
  clear connCmdsQueued
  clear asyncCmdQueues
  clear getMsgLocks
  where
    clear :: Monoid m => (AgentClient -> TVar m) -> IO ()
    clear sel = atomically $ writeTVar (sel c) mempty

waitUntilActive :: AgentClient -> STM ()
waitUntilActive c = unlessM (readTVar $ active c) retry

throwWhenInactive :: AgentClient -> STM ()
throwWhenInactive c = unlessM (readTVar $ active c) $ throwSTM ThreadKilled

throwWhenNoDelivery :: AgentClient -> SndQueue -> STM ()
throwWhenNoDelivery c SndQueue {server, sndId} =
  unlessM (isJust <$> TM.lookup k (smpQueueMsgQueues c)) $ do
    TM.delete k $ smpQueueMsgDeliveries c
    throwSTM ThreadKilled
  where
    k = (server, sndId)

closeProtocolServerClients :: ProtocolServerClient err msg => AgentClient -> (AgentClient -> TMap (TransportSession msg) (ClientVar msg)) -> IO ()
closeProtocolServerClients c clientsSel =
  atomically (swapTVar cs M.empty) >>= mapM_ (forkIO . closeClient)
  where
    cs = clientsSel c
    closeClient cVar = do
      NetworkConfig {tcpConnectTimeout} <- readTVarIO $ useNetworkConfig c
      tcpConnectTimeout `timeout` atomically (readTMVar cVar) >>= \case
        Just (Right client) -> closeProtocolServerClient client `catchAll_` pure ()
        _ -> pure ()

cancelActions :: (Foldable f, Monoid (f (Async ()))) => TVar (f (Async ())) -> IO ()
cancelActions as = atomically (swapTVar as mempty) >>= mapM_ (forkIO . uninterruptibleCancel)

withConnLock :: MonadUnliftIO m => AgentClient -> ConnId -> String -> m a -> m a
withConnLock _ "" _ = id
withConnLock AgentClient {connLocks} connId name = withLockMap_ connLocks connId name

withLockMap_ :: (Ord k, MonadUnliftIO m) => TMap k Lock -> k -> String -> m a -> m a
withLockMap_ locks key = withGetLock $ TM.lookup key locks >>= maybe newLock pure
  where
    newLock = createLock >>= \l -> TM.insert key l locks $> l

withClient_ :: forall a m err msg. (AgentMonad m, ProtocolServerClient err msg) => AgentClient -> TransportSession msg -> ByteString -> (Client msg -> m a) -> m a
withClient_ c tSess@(userId, srv, _) statCmd action = do
  cl <- getProtocolServerClient c tSess
  (action cl <* stat cl "OK") `catchError` logServerError cl
  where
    stat cl = liftIO . incClientStat c userId cl statCmd
    logServerError :: Client msg -> AgentErrorType -> m a
    logServerError cl e = do
      logServer "<--" c srv "" $ strEncode e
      stat cl $ strEncode e
      throwError e

withLogClient_ :: (AgentMonad m, ProtocolServerClient err msg) => AgentClient -> TransportSession msg -> EntityId -> ByteString -> (Client msg -> m a) -> m a
withLogClient_ c tSess@(_, srv, _) entId cmdStr action = do
  logServer "-->" c srv entId cmdStr
  res <- withClient_ c tSess cmdStr action
  logServer "<--" c srv entId "OK"
  return res

withClient :: forall m err msg a. (AgentMonad m, ProtocolServerClient err msg) => AgentClient -> TransportSession msg -> ByteString -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> m a
withClient c tSess statKey action = withClient_ c tSess statKey $ \client -> liftClient (clientProtocolError @err @msg) (clientServer client) $ action client

withLogClient :: forall m err msg a. (AgentMonad m, ProtocolServerClient err msg) => AgentClient -> TransportSession msg -> EntityId -> ByteString -> (Client msg -> ExceptT (ProtocolClientError err) IO a) -> m a
withLogClient c tSess entId cmdStr action = withLogClient_ c tSess entId cmdStr $ \client -> liftClient (clientProtocolError @err @msg) (clientServer client) $ action client

withSMPClient :: (AgentMonad m, SMPQueueRec q) => AgentClient -> q -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withSMPClient c q cmdStr action = do
  tSess <- mkSMPTransportSession c q
  withLogClient c tSess (queueId q) cmdStr action

withSMPClient_ :: (AgentMonad m, SMPQueueRec q) => AgentClient -> q -> ByteString -> (SMPClient -> m a) -> m a
withSMPClient_ c q cmdStr action = do
  tSess <- mkSMPTransportSession c q
  withLogClient_ c tSess (queueId q) cmdStr action

withNtfClient :: forall m a. AgentMonad m => AgentClient -> NtfServer -> EntityId -> ByteString -> (NtfClient -> ExceptT NtfClientError IO a) -> m a
withNtfClient c srv = withLogClient c (0, srv, Nothing)

withXFTPClient ::
  (AgentMonad m, ProtocolServerClient err msg) =>
  AgentClient ->
  (UserId, ProtoServer msg, EntityId) ->
  ByteString ->
  (Client msg -> ExceptT (ProtocolClientError err) IO b) ->
  m b
withXFTPClient c (userId, srv, fId) cmdStr action = do
  tSess <- mkTransportSession c userId srv fId
  withLogClient c tSess (strEncode fId) cmdStr action

liftClient :: (AgentMonad m, Show err, Encoding err) => (err -> AgentErrorType) -> HostName -> ExceptT (ProtocolClientError err) IO a -> m a
liftClient protocolError_ = liftError . protocolClientError protocolError_

protocolClientError :: (Show err, Encoding err) => (err -> AgentErrorType) -> HostName -> ProtocolClientError err -> AgentErrorType
protocolClientError protocolError_ host = \case
  PCEProtocolError e -> protocolError_ e
  PCEResponseError e -> BROKER host $ RESPONSE $ B.unpack $ smpEncode e
  PCEUnexpectedResponse _ -> BROKER host UNEXPECTED
  PCEResponseTimeout -> BROKER host TIMEOUT
  PCENetworkError -> BROKER host NETWORK
  PCEIncompatibleHost -> BROKER host HOST
  PCETransportError e -> BROKER host $ TRANSPORT e
  e@PCECryptoError {} -> INTERNAL $ show e
  PCEIOError {} -> BROKER host NETWORK

data SMPTestStep = TSConnect | TSCreateQueue | TSSecureQueue | TSDeleteQueue | TSDisconnect
  deriving (Eq, Show, Generic)

instance ToJSON SMPTestStep where
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "TS"
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "TS"

data SMPTestFailure = SMPTestFailure
  { testStep :: SMPTestStep,
    testError :: AgentErrorType
  }
  deriving (Eq, Show, Generic)

instance ToJSON SMPTestFailure where
  toEncoding = J.genericToEncoding J.defaultOptions
  toJSON = J.genericToJSON J.defaultOptions

runSMPServerTest :: AgentMonad m => AgentClient -> UserId -> SMPServerWithAuth -> m (Maybe SMPTestFailure)
runSMPServerTest c userId (ProtoServerWithAuth srv auth) = do
  cfg <- getClientConfig c smpCfg
  C.SignAlg a <- asks $ cmdSignAlg . config
  liftIO $ do
    let tSess = (userId, srv, Nothing)
    getProtocolClient tSess cfg Nothing (\_ -> pure ()) >>= \case
      Right smp -> do
        (rKey, rpKey) <- C.generateSignatureKeyPair a
        (sKey, _) <- C.generateSignatureKeyPair a
        (dhKey, _) <- C.generateKeyPair'
        r <- runExceptT $ do
          SMP.QIK {rcvId} <- liftError (testErr TSCreateQueue) $ createSMPQueue smp rpKey rKey dhKey auth
          liftError (testErr TSSecureQueue) $ secureSMPQueue smp rpKey rcvId sKey
          liftError (testErr TSDeleteQueue) $ deleteSMPQueue smp rpKey rcvId
        ok <- tcpTimeout (networkConfig cfg) `timeout` closeProtocolClient smp
        incClientStat c userId smp "TEST" "OK"
        pure $ either Just (const Nothing) r <|> maybe (Just (SMPTestFailure TSDisconnect $ BROKER addr TIMEOUT)) (const Nothing) ok
      Left e -> pure (Just $ testErr TSConnect e)
  where
    addr = B.unpack $ strEncode srv
    testErr :: SMPTestStep -> SMPClientError -> SMPTestFailure
    testErr step = SMPTestFailure step . protocolClientError SMP addr

mkTransportSession :: AgentMonad m => AgentClient -> UserId -> ProtoServer msg -> EntityId -> m (TransportSession msg)
mkTransportSession c userId srv entityId = mkTSession userId srv entityId <$> getSessionMode c

mkTSession :: UserId -> ProtoServer msg -> EntityId -> TransportSessionMode -> TransportSession msg
mkTSession userId srv entityId mode = (userId, srv, if mode == TSMEntity then Just entityId else Nothing)

mkSMPTransportSession :: (AgentMonad m, SMPQueueRec q) => AgentClient -> q -> m SMPTransportSession
mkSMPTransportSession c q = mkSMPTSession q <$> getSessionMode c

mkSMPTSession :: SMPQueueRec q => q -> TransportSessionMode -> SMPTransportSession
mkSMPTSession q = mkTSession (qUserId q) (qServer q) (qConnId q)

getSessionMode :: AgentMonad m => AgentClient -> m TransportSessionMode
getSessionMode = fmap sessionMode . readTVarIO . useNetworkConfig

newRcvQueue :: AgentMonad m => AgentClient -> UserId -> ConnId -> SMPServerWithAuth -> VersionRange -> m (RcvQueue, SMPQueueUri)
newRcvQueue c userId connId (ProtoServerWithAuth srv auth) vRange = do
  C.SignAlg a <- asks (cmdSignAlg . config)
  (recipientKey, rcvPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (dhKey, privDhKey) <- liftIO C.generateKeyPair'
  (e2eDhKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  logServer "-->" c srv "" "NEW"
  tSess <- mkTransportSession c userId srv connId
  QIK {rcvId, sndId, rcvPublicDhKey} <-
    withClient c tSess "NEW" $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey dhKey auth
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sndId]
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
            dbQueueId = 0,
            primary = True,
            dbReplaceQueueId = Nothing,
            smpClientVersion = maxVersion vRange,
            clientNtfCreds = Nothing,
            deleteErrors = 0
          }
  pure (rq, SMPQueueUri vRange $ SMPQueueAddress srv sndId e2eDhKey)

processSubResult :: AgentClient -> RcvQueue -> Either SMPClientError () -> IO (Either SMPClientError ())
processSubResult c rq r = do
  case r of
    Left e ->
      atomically . unless (temporaryClientError e) $
        RQ.deleteQueue rq (pendingSubs c)
    _ -> addSubscription c rq
  pure r

temporaryAgentError :: AgentErrorType -> Bool
temporaryAgentError = \case
  BROKER _ NETWORK -> True
  BROKER _ TIMEOUT -> True
  _ -> False

temporaryOrHostError :: AgentErrorType -> Bool
temporaryOrHostError = \case
  BROKER _ HOST -> True
  e -> temporaryAgentError e

-- | Subscribe to queues. The list of results can have a different order.
subscribeQueues :: forall m. AgentMonad m => AgentClient -> [RcvQueue] -> m [(RcvQueue, Either AgentErrorType ())]
subscribeQueues c qs = do
  (errs, qs') <- partitionEithers <$> mapM checkQueue qs
  forM_ qs' $ \rq@RcvQueue {connId} -> atomically $ do
    modifyTVar (subscrConns c) $ S.insert connId
    RQ.addQueue rq $ pendingSubs c
  u <- askUnliftIO
  (errs <>) <$> sendTSessionBatches "SUB" 90 (subscribeQueues_ u) c qs
  where
    checkQueue rq@RcvQueue {rcvId, server} = do
      prohibited <- atomically . TM.member (server, rcvId) $ getMsgLocks c
      pure $ if prohibited then Left (rq, Left $ CMD PROHIBITED) else Right rq
    subscribeQueues_ u smp qs' = do
      rs <- sendBatch subscribeSMPQueues smp qs'
      mapM_ (uncurry $ processSubResult c) rs
      when (any temporaryClientError . lefts . map snd $ L.toList rs) $
        unliftIO u $ reconnectServer c $ transportSession' smp
      pure rs

type BatchResponses e = (NonEmpty (RcvQueue, Either e ()))

-- statBatchSize is not used to batch the commands, only for traffic statistics
sendTSessionBatches :: forall m. AgentMonad m => ByteString -> Int -> (SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses SMPClientError)) -> AgentClient -> [RcvQueue] -> m [(RcvQueue, Either AgentErrorType ())]
sendTSessionBatches statCmd statBatchSize action c qs =
  concatMap L.toList <$> (mapConcurrently sendClientBatch =<< batchQueues)
  where
    batchQueues :: m [(SMPTransportSession, NonEmpty RcvQueue)]
    batchQueues = do
      mode <- sessionMode <$> readTVarIO (useNetworkConfig c)
      pure . M.assocs $ foldl' (batch mode) M.empty qs
      where
        batch mode m rq =
          let tSess = mkSMPTSession rq mode
           in M.alter (Just . maybe [rq] (rq <|)) tSess m
    sendClientBatch :: (SMPTransportSession, NonEmpty RcvQueue) -> m (BatchResponses AgentErrorType)
    sendClientBatch (tSess@(userId, srv, _), qs') =
      tryError (getSMPServerClient c tSess) >>= \case
        Left e -> pure $ L.map (,Left e) qs'
        Right smp -> liftIO $ do
          logServer "-->" c srv (bshow (length qs') <> " queues") statCmd
          rs <- L.map agentError <$> action smp qs'
          statBatch
          pure rs
          where
            agentError = second . first $ protocolClientError SMP $ clientServer smp
            statBatch =
              let n = (length qs - 1) `div` statBatchSize + 1
               in incClientStatN c userId smp n (statCmd <> "S") "OK"

sendBatch :: (SMPClient -> NonEmpty (SMP.RcvPrivateSignKey, SMP.RecipientId) -> IO (NonEmpty (Either SMPClientError ()))) -> SMPClient -> NonEmpty RcvQueue -> IO (BatchResponses SMPClientError)
sendBatch smpCmdFunc smp qs = L.zip qs <$> smpCmdFunc smp (L.map queueCreds qs)
  where
    queueCreds RcvQueue {rcvPrivateKey, rcvId} = (rcvPrivateKey, rcvId)

addSubscription :: MonadIO m => AgentClient -> RcvQueue -> m ()
addSubscription c rq@RcvQueue {connId} = atomically $ do
  modifyTVar' (subscrConns c) $ S.insert connId
  RQ.addQueue rq $ activeSubs c
  RQ.deleteQueue rq $ pendingSubs c

hasActiveSubscription :: AgentClient -> ConnId -> STM Bool
hasActiveSubscription c connId = RQ.hasConn connId $ activeSubs c

removeSubscription :: AgentClient -> ConnId -> STM ()
removeSubscription c connId = do
  modifyTVar' (subscrConns c) $ S.delete connId
  RQ.deleteConn connId $ activeSubs c
  RQ.deleteConn connId $ pendingSubs c

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
sendConfirmation c sq@SndQueue {sndId, sndPublicKey = Just sndPublicKey, e2ePubKey = e2ePubKey@Just {}} agentConfirmation =
  withSMPClient_ c sq "SEND <CONF>" $ \smp -> do
    let clientMsg = SMP.ClientMessage (SMP.PHConfirmation sndPublicKey) agentConfirmation
    msg <- agentCbEncrypt sq e2ePubKey $ smpEncode clientMsg
    liftClient SMP (clientServer smp) $ sendSMPMessage smp Nothing sndId (SMP.MsgFlags {notification = True}) msg
sendConfirmation _ _ _ = throwError $ INTERNAL "sendConfirmation called without snd_queue public key(s) in the database"

sendInvitation :: forall m. AgentMonad m => AgentClient -> UserId -> Compatible SMPQueueInfo -> Compatible Version -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
sendInvitation c userId (Compatible (SMPQueueInfo v SMPQueueAddress {smpServer, senderId, dhPublicKey})) (Compatible agentVersion) connReq connInfo = do
  tSess <- mkTransportSession c userId smpServer senderId
  withLogClient_ c tSess senderId "SEND <INV>" $ \smp -> do
    msg <- mkInvitation
    liftClient SMP (clientServer smp) $ sendSMPMessage smp Nothing senderId MsgFlags {notification = True} msg
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
  (v, msg_) <- withSMPClient c rq "GET" $ \smp ->
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
secureQueue c rq@RcvQueue {rcvId, rcvPrivateKey} senderKey =
  withSMPClient c rq "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

enableQueueNotifications :: AgentMonad m => AgentClient -> RcvQueue -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> m (NotifierId, RcvNtfPublicDhKey)
enableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} notifierKey rcvNtfPublicDhKey =
  withSMPClient c rq "NKEY <nkey>" $ \smp ->
    enableSMPQueueNotifications smp rcvPrivateKey rcvId notifierKey rcvNtfPublicDhKey

disableQueueNotifications :: AgentMonad m => AgentClient -> RcvQueue -> m ()
disableQueueNotifications c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "NDEL" $ \smp ->
    disableSMPQueueNotifications smp rcvPrivateKey rcvId

sendAck :: AgentMonad m => AgentClient -> RcvQueue -> MsgId -> m ()
sendAck c rq@RcvQueue {rcvId, rcvPrivateKey} msgId = do
  withSMPClient c rq "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId msgId
  atomically $ releaseGetLock c rq

releaseGetLock :: AgentClient -> RcvQueue -> STM ()
releaseGetLock c RcvQueue {server, rcvId} =
  TM.lookup (server, rcvId) (getMsgLocks c) >>= mapM_ (`tryPutTMVar` ())

suspendQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
suspendQueue c rq@RcvQueue {rcvId, rcvPrivateKey} =
  withSMPClient c rq "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
deleteQueue c rq@RcvQueue {rcvId, rcvPrivateKey} = do
  withSMPClient c rq "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

deleteQueues :: forall m. AgentMonad m => AgentClient -> [RcvQueue] -> m [(RcvQueue, Either AgentErrorType ())]
deleteQueues = sendTSessionBatches "DEL" 90 $ sendBatch deleteSMPQueues

sendAgentMessage :: AgentMonad m => AgentClient -> SndQueue -> MsgFlags -> ByteString -> m ()
sendAgentMessage c sq@SndQueue {sndId, sndPrivateKey} msgFlags agentMsg =
  withSMPClient_ c sq "SEND <MSG>" $ \smp -> do
    let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
    msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
    liftClient SMP (clientServer smp) $ sendSMPMessage smp (Just sndPrivateKey) sndId msgFlags msg

agentNtfRegisterToken :: AgentMonad m => AgentClient -> NtfToken -> C.APublicVerifyKey -> C.PublicKeyX25519 -> m (NtfTokenId, C.PublicKeyX25519)
agentNtfRegisterToken c NtfToken {deviceToken, ntfServer, ntfPrivKey} ntfPubKey pubDhKey =
  withClient c (0, ntfServer, Nothing) "TNEW" $ \ntf -> ntfRegisterToken ntf ntfPrivKey (NewNtfTkn deviceToken ntfPubKey pubDhKey)

agentNtfVerifyToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> NtfRegCode -> m ()
agentNtfVerifyToken c tknId NtfToken {ntfServer, ntfPrivKey} code =
  withNtfClient c ntfServer tknId "TVFY" $ \ntf -> ntfVerifyToken ntf ntfPrivKey tknId code

agentNtfCheckToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> m NtfTknStatus
agentNtfCheckToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer tknId "TCHK" $ \ntf -> ntfCheckToken ntf ntfPrivKey tknId

agentNtfReplaceToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> DeviceToken -> m ()
agentNtfReplaceToken c tknId NtfToken {ntfServer, ntfPrivKey} token =
  withNtfClient c ntfServer tknId "TRPL" $ \ntf -> ntfReplaceToken ntf ntfPrivKey tknId token

agentNtfDeleteToken :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> m ()
agentNtfDeleteToken c tknId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer tknId "TDEL" $ \ntf -> ntfDeleteToken ntf ntfPrivKey tknId

agentNtfEnableCron :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> Word16 -> m ()
agentNtfEnableCron c tknId NtfToken {ntfServer, ntfPrivKey} interval =
  withNtfClient c ntfServer tknId "TCRN" $ \ntf -> ntfEnableCron ntf ntfPrivKey tknId interval

agentNtfCreateSubscription :: AgentMonad m => AgentClient -> NtfTokenId -> NtfToken -> SMPQueueNtf -> NtfPrivateSignKey -> m NtfSubscriptionId
agentNtfCreateSubscription c tknId NtfToken {ntfServer, ntfPrivKey} smpQueue nKey =
  withNtfClient c ntfServer tknId "SNEW" $ \ntf -> ntfCreateSubscription ntf ntfPrivKey (NewNtfSub tknId smpQueue nKey)

agentNtfCheckSubscription :: AgentMonad m => AgentClient -> NtfSubscriptionId -> NtfToken -> m NtfSubStatus
agentNtfCheckSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer subId "SCHK" $ \ntf -> ntfCheckSubscription ntf ntfPrivKey subId

agentNtfDeleteSubscription :: AgentMonad m => AgentClient -> NtfSubscriptionId -> NtfToken -> m ()
agentNtfDeleteSubscription c subId NtfToken {ntfServer, ntfPrivKey} =
  withNtfClient c ntfServer subId "SDEL" $ \ntf -> ntfDeleteSubscription ntf ntfPrivKey subId

agentXFTPDownloadChunk :: AgentMonad m => AgentClient -> UserId -> RcvFileChunkReplica -> XFTPRcvChunkSpec -> m ()
agentXFTPDownloadChunk c userId RcvFileChunkReplica {server, replicaId = ChunkReplicaId fId, replicaKey} chunkSpec =
  withXFTPClient c (userId, server, fId) "FGET" $ \xftp -> X.downloadXFTPChunk xftp replicaKey fId chunkSpec

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

withStore' :: AgentMonad m => AgentClient -> (DB.Connection -> IO a) -> m a
withStore' c action = withStore c $ fmap Right . action

withStore :: AgentMonad m => AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> m a
withStore c action = do
  st <- asks store
  liftEitherError storeError . agentOperationBracket c AODatabase (\_ -> pure ()) $
    withTransaction st action `E.catch` handleInternal
  where
    handleInternal :: E.SomeException -> IO (Either StoreError a)
    handleInternal = pure . Left . SEInternal . bshow

storeError :: StoreError -> AgentErrorType
storeError = \case
  SEConnNotFound -> CONN NOT_FOUND
  SERatchetNotFound -> CONN NOT_FOUND
  SEConnDuplicate -> CONN DUPLICATE
  SEBadConnType CRcv -> CONN SIMPLEX
  SEBadConnType CSnd -> CONN SIMPLEX
  SEInvitationNotFound -> CMD PROHIBITED
  -- this error is never reported as store error,
  -- it is used to wrap agent operations when "transaction-like" store access is needed
  -- NOTE: network IO should NOT be used inside AgentStoreMonad
  SEAgentError e -> e
  e -> INTERNAL $ show e

incStat :: AgentClient -> Int -> AgentStatsKey -> STM ()
incStat AgentClient {agentStats} n k = do
  TM.lookup k agentStats >>= \case
    Just v -> modifyTVar' v (+ n)
    _ -> newTVar n >>= \v -> TM.insert k v agentStats

incClientStat :: ProtocolServerClient err msg => AgentClient -> UserId -> Client msg -> ByteString -> ByteString -> IO ()
incClientStat c userId pc = incClientStatN c userId pc 1

incServerStat :: AgentClient -> UserId -> ProtocolServer p -> ByteString -> ByteString -> IO ()
incServerStat c userId ProtocolServer {host} cmd res = do
  threadDelay 100000
  atomically $ incStat c 1 statsKey
  where
    statsKey = AgentStatsKey {userId, host = strEncode $ L.head host, clientTs = "", cmd, res}

incClientStatN :: ProtocolServerClient err msg => AgentClient -> UserId -> Client msg -> Int -> ByteString -> ByteString -> IO ()
incClientStatN c userId pc n cmd res = do
  atomically $ incStat c n statsKey
  where
    statsKey = AgentStatsKey {userId, host = strEncode $ clientTransportHost pc, clientTs = strEncode $ clientSessionTs pc, cmd, res}
