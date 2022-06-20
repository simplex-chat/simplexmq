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
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    newAgentClient,
    withAgentLock,
    closeAgentClient,
    newRcvQueue,
    subscribeQueue,
    getQueueMessage,
    addSubscription,
    getSubscriptions,
    sendConfirmation,
    sendInvitation,
    RetryInterval (..),
    secureQueue,
    enableQueueNotifications,
    sendAgentMessage,
    agentNtfRegisterToken,
    agentNtfVerifyToken,
    agentNtfCheckToken,
    agentNtfDeleteToken,
    agentNtfEnableCron,
    agentNtfCreateSubscription,
    agentNtfCheckSubscription,
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
    beginAgentOperation,
    endAgentOperation,
    notifyAgentPhaseChanged,
    withStore,
    withStore',
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (retry, stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Text.Encoding
import Data.Word (Word16)
import Database.SQLite.Simple (SQLError)
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
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (BrokerMsg, ErrorType, MsgFlags (..), MsgId, NotifierId, NtfPrivateSignKey, NtfPublicVerifyKey, ProtocolServer (..), QueueId, QueueIdsKeys (..), RcvNtfPublicDhKey, SMPMsgMeta, SndPublicVerifyKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (bshow, catchAll_, ifM, liftEitherError, liftError, tryError, unlessM, whenM)
import Simplex.Messaging.Version
import System.Timeout (timeout)
import UnliftIO (async, pooledForConcurrentlyN)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type ClientVar msg = TMVar (Either AgentErrorType (ProtocolClient msg))

type SMPClientVar = TMVar (Either AgentErrorType SMPClient)

type NtfClientVar = TMVar (Either AgentErrorType NtfClient)

data AgentClient = AgentClient
  { active :: TVar Bool,
    rcvQ :: TBQueue (ATransmission 'Client),
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue (ServerTransmission BrokerMsg),
    smpServers :: TVar (NonEmpty SMPServer),
    smpClients :: TMap SMPServer SMPClientVar,
    ntfServers :: TVar [NtfServer],
    ntfClients :: TMap NtfServer NtfClientVar,
    subscrSrvrs :: TMap SMPServer (TMap ConnId RcvQueue),
    pendingSubscrSrvrs :: TMap SMPServer (TMap ConnId RcvQueue),
    subscrConns :: TMap ConnId SMPServer,
    connMsgsQueued :: TMap ConnId Bool,
    smpQueueMsgQueues :: TMap (ConnId, SMPServer, SMP.SenderId) (TQueue InternalId),
    smpQueueMsgDeliveries :: TMap (ConnId, SMPServer, SMP.SenderId) (Async ()),
    getMsgLocks :: TMap (ConnId, SMPServer, SMP.RecipientId) (TMVar ()),
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()],
    clientId :: Int,
    agentEnv :: Env,
    lock :: TMVar ()
  }

newAgentClient :: InitialAgentServers -> Env -> STM AgentClient
newAgentClient InitialAgentServers {smp, ntf} agentEnv = do
  let qSize = tbqSize $ config agentEnv
  active <- newTVar True
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpServers <- newTVar smp
  smpClients <- TM.empty
  ntfServers <- newTVar ntf
  ntfClients <- TM.empty
  subscrSrvrs <- TM.empty
  pendingSubscrSrvrs <- TM.empty
  subscrConns <- TM.empty
  connMsgsQueued <- TM.empty
  smpQueueMsgQueues <- TM.empty
  smpQueueMsgDeliveries <- TM.empty
  getMsgLocks <- TM.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  clientId <- stateTVar (clientCounter agentEnv) $ \i -> (i + 1, i + 1)
  lock <- newTMVar ()
  return AgentClient {active, rcvQ, subQ, msgQ, smpServers, smpClients, ntfServers, ntfClients, subscrSrvrs, pendingSubscrSrvrs, subscrConns, connMsgsQueued, smpQueueMsgQueues, smpQueueMsgDeliveries, getMsgLocks, reconnections, asyncClients, clientId, agentEnv, lock}

agentDbPath :: AgentClient -> FilePath
agentDbPath AgentClient {agentEnv = Env {store = SQLiteStore {dbFilePath}}} = dbFilePath

class ProtocolServerClient msg where
  getProtocolServerClient :: AgentMonad m => AgentClient -> ProtocolServer -> m (ProtocolClient msg)
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
      (waitForProtocolClient smpCfg)
  where
    connectClient :: m SMPClient
    connectClient = do
      cfg <- asks $ smpCfg . config
      u <- askUnliftIO
      liftEitherError (protocolClientError SMP) (getProtocolClient srv cfg (Just msgQ) $ clientDisconnected u)

    clientDisconnected :: UnliftIO m -> IO ()
    clientDisconnected u = do
      removeClientAndSubs >>= (`forM_` serverDown u)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientAndSubs :: IO (Maybe (Map ConnId RcvQueue))
    removeClientAndSubs = atomically $ do
      TM.delete srv smpClients
      TM.lookupDelete srv (subscrSrvrs c) >>= mapM updateSubs
      where
        updateSubs cVar = do
          cs <- readTVar cVar
          modifyTVar' (subscrConns c) (`M.withoutKeys` M.keysSet cs)
          addPendingSubs cVar cs
          pure cs

        addPendingSubs cVar cs = do
          let ps = pendingSubscrSrvrs c
          TM.lookup srv ps >>= \case
            Just v -> TM.union cs v
            _ -> TM.insert srv cVar ps

    serverDown :: UnliftIO m -> Map ConnId RcvQueue -> IO ()
    serverDown u cs = unless (M.null cs) $
      whenM (readTVarIO active) $ do
        let conns = M.keys cs
        unless (null conns) . notifySub "" $ DOWN srv conns
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
    reconnectClient = do
      n <- asks $ resubscriptionConcurrency . config
      withAgentLock c . withClient c srv $ \smp -> do
        cs <- atomically $ mapM readTVar =<< TM.lookup srv (pendingSubscrSrvrs c)
        -- TODO if any of the subscriptions fails here (e.g. because of timeout), it terminates the whole process for all subscriptions
        -- instead it should only report successful subscriptions and schedule the next call to reconnectClient to subscribe for the remaining subscriptions
        -- this way, for each DOWN event there can be several UP events
        conns <- pooledForConcurrentlyN n (maybe [] M.toList cs) $ \sub@(connId, _) ->
          ifM
            (atomically $ hasActiveSubscription c connId)
            (pure $ Just connId)
            (subscribe_ smp sub `catchError` handleError connId)
        liftIO . unless (null conns) . notifySub "" . UP srv $ catMaybes conns
      where
        subscribe_ :: SMPClient -> (ConnId, RcvQueue) -> ExceptT ProtocolClientError IO (Maybe ConnId)
        subscribe_ smp (connId, rq@RcvQueue {rcvPrivateKey, rcvId}) = do
          subscribeSMPQueue smp rcvPrivateKey rcvId
          addSubscription c rq connId
          pure $ Just connId

        handleError :: ConnId -> ProtocolClientError -> ExceptT ProtocolClientError IO (Maybe ConnId)
        handleError connId = \case
          e@PCEResponseTimeout -> throwError e
          e@PCENetworkError -> throwError e
          e -> do
            liftIO . notifySub connId . ERR $ protocolClientError SMP e
            atomically $ removePendingSubscription c srv connId
            pure Nothing

    notifySub :: ConnId -> ACommand 'Agent -> IO ()
    notifySub connId cmd = atomically $ writeTBQueue (subQ c) ("", connId, cmd)

getNtfServerClient :: forall m. AgentMonad m => AgentClient -> NtfServer -> m NtfClient
getNtfServerClient c@AgentClient {active, ntfClients} srv = do
  unlessM (readTVarIO active) . throwError $ INTERNAL "agent is stopped"
  atomically (getClientVar srv ntfClients)
    >>= either
      (newProtocolClient c srv ntfClients connectClient $ pure ())
      (waitForProtocolClient ntfCfg)
  where
    connectClient :: m NtfClient
    connectClient = do
      cfg <- asks $ ntfCfg . config
      liftEitherError (protocolClientError NTF) (getProtocolClient srv cfg Nothing clientDisconnected)

    clientDisconnected :: IO ()
    clientDisconnected = do
      atomically $ TM.delete srv ntfClients
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

getClientVar :: forall a. ProtocolServer -> TMap ProtocolServer (TMVar a) -> STM (Either (TMVar a) (TMVar a))
getClientVar srv clients = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup srv clients
  where
    newClientVar :: STM (TMVar a)
    newClientVar = do
      var <- newEmptyTMVar
      TM.insert srv var clients
      pure var

waitForProtocolClient :: AgentMonad m => (AgentConfig -> ProtocolClientConfig) -> ClientVar msg -> m (ProtocolClient msg)
waitForProtocolClient clientConfig clientVar = do
  ProtocolClientConfig {tcpTimeout} <- asks $ clientConfig . config
  client_ <- liftIO $ tcpTimeout `timeout` atomically (readTMVar clientVar)
  liftEither $ case client_ of
    Just (Right smpClient) -> Right smpClient
    Just (Left e) -> Left e
    Nothing -> Left $ BROKER TIMEOUT

newProtocolClient ::
  forall msg m.
  AgentMonad m =>
  AgentClient ->
  ProtocolServer ->
  TMap ProtocolServer (ClientVar msg) ->
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
          successAction client
        Left e -> do
          if e == BROKER NETWORK || e == BROKER TIMEOUT
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

closeAgentClient :: MonadIO m => AgentClient -> m ()
closeAgentClient c = liftIO $ do
  atomically $ writeTVar (active c) False
  closeProtocolServerClients (clientTimeout smpCfg) $ smpClients c
  closeProtocolServerClients (clientTimeout ntfCfg) $ ntfClients c
  cancelActions $ reconnections c
  cancelActions $ asyncClients c
  cancelActions $ smpQueueMsgDeliveries c
  clear subscrSrvrs
  clear pendingSubscrSrvrs
  clear subscrConns
  clear connMsgsQueued
  clear smpQueueMsgQueues
  where
    clientTimeout sel = tcpTimeout . sel . config $ agentEnv c
    clear :: (AgentClient -> TMap k a) -> IO ()
    clear sel = atomically $ writeTVar (sel c) M.empty

closeProtocolServerClients :: Int -> TMap ProtocolServer (ClientVar msg) -> IO ()
closeProtocolServerClients tcpTimeout cs = readTVarIO cs >>= mapM_ (forkIO . closeClient) >> atomically (writeTVar cs M.empty)
  where
    closeClient cVar =
      tcpTimeout `timeout` atomically (readTMVar cVar) >>= \case
        Just (Right client) -> closeProtocolClient client `catchAll_` pure ()
        _ -> pure ()

cancelActions :: (Foldable f, Monoid (f (Async ()))) => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel >> atomically (writeTVar as mempty)

withAgentLock :: MonadUnliftIO m => AgentClient -> m a -> m a
withAgentLock AgentClient {lock} =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

withClient_ :: forall a m msg. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtocolServer -> (ProtocolClient msg -> m a) -> m a
withClient_ c srv action = (getProtocolServerClient c srv >>= action) `catchError` logServerError
  where
    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ bshow e
      throwError e

withLogClient_ :: (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtocolServer -> QueueId -> ByteString -> (ProtocolClient msg -> m a) -> m a
withLogClient_ c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withClient_ c srv action
  logServer "<--" c srv qId "OK"
  return res

withClient :: forall m msg a. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtocolServer -> (ProtocolClient msg -> ExceptT ProtocolClientError IO a) -> m a
withClient c srv action = withClient_ c srv $ liftClient (clientProtocolError @msg) . action

withLogClient :: forall m msg a. (AgentMonad m, ProtocolServerClient msg) => AgentClient -> ProtocolServer -> QueueId -> ByteString -> (ProtocolClient msg -> ExceptT ProtocolClientError IO a) -> m a
withLogClient c srv qId cmdStr action = withLogClient_ c srv qId cmdStr $ liftClient (clientProtocolError @msg) . action

liftClient :: AgentMonad m => (ErrorType -> AgentErrorType) -> ExceptT ProtocolClientError IO a -> m a
liftClient = liftError . protocolClientError

protocolClientError :: (ErrorType -> AgentErrorType) -> ProtocolClientError -> AgentErrorType
protocolClientError protocolError_ = \case
  PCEProtocolError e -> protocolError_ e
  PCEResponseError e -> BROKER $ RESPONSE e
  PCEUnexpectedResponse -> BROKER UNEXPECTED
  PCEResponseTimeout -> BROKER TIMEOUT
  PCENetworkError -> BROKER NETWORK
  PCETransportError e -> BROKER $ TRANSPORT e
  e@PCESignatureError {} -> INTERNAL $ show e
  e@PCEIOError {} -> INTERNAL $ show e

newRcvQueue :: AgentMonad m => AgentClient -> SMPServer -> m (RcvQueue, SMPQueueUri)
newRcvQueue c srv =
  asks (cmdSignAlg . config) >>= \case
    C.SignAlg a -> newRcvQueue_ a c srv

newRcvQueue_ ::
  (C.SignatureAlgorithm a, C.AlgorithmI a, AgentMonad m) =>
  C.SAlgorithm a ->
  AgentClient ->
  SMPServer ->
  m (RcvQueue, SMPQueueUri)
newRcvQueue_ a c srv = do
  (recipientKey, rcvPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (dhKey, privDhKey) <- liftIO C.generateKeyPair'
  (e2eDhKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  logServer "-->" c srv "" "NEW"
  QIK {rcvId, sndId, rcvPublicDhKey} <-
    withClient c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey dhKey
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sndId]
  let rq =
        RcvQueue
          { server = srv,
            rcvId,
            rcvPrivateKey,
            rcvDhSecret = C.dh' rcvPublicDhKey privDhKey,
            e2ePrivKey,
            e2eDhSecret = Nothing,
            sndId = Just sndId,
            status = New,
            clientNtfCreds = Nothing
          }
  pure (rq, SMPQueueUri srv sndId SMP.smpClientVRange e2eDhKey)

subscribeQueue :: AgentMonad m => AgentClient -> RcvQueue -> ConnId -> m ()
subscribeQueue c rq@RcvQueue {server, rcvPrivateKey, rcvId} connId = do
  whenM (atomically . TM.member (connId, server, rcvId) $ getMsgLocks c) . throwError $ CMD PROHIBITED
  atomically $ addPendingSubscription c rq connId
  withLogClient c server rcvId "SUB" $ \smp -> do
    liftIO (runExceptT $ subscribeSMPQueue smp rcvPrivateKey rcvId) >>= \case
      Left e -> do
        atomically . when (e /= PCENetworkError && e /= PCEResponseTimeout) $
          removePendingSubscription c server connId
        throwError e
      Right _ -> do
        addSubscription c rq connId

addSubscription :: MonadIO m => AgentClient -> RcvQueue -> ConnId -> m ()
addSubscription c rq@RcvQueue {server} connId = atomically $ do
  TM.insert connId server $ subscrConns c
  addSubs_ (subscrSrvrs c) rq connId
  removePendingSubscription c server connId

hasActiveSubscription :: AgentClient -> ConnId -> STM Bool
hasActiveSubscription c connId = TM.member connId (subscrConns c)

addPendingSubscription :: AgentClient -> RcvQueue -> ConnId -> STM ()
addPendingSubscription = addSubs_ . pendingSubscrSrvrs

addSubs_ :: TMap SMPServer (TMap ConnId RcvQueue) -> RcvQueue -> ConnId -> STM ()
addSubs_ ss rq@RcvQueue {server} connId =
  TM.lookup server ss >>= \case
    Just m -> TM.insert connId rq m
    _ -> TM.singleton connId rq >>= \m -> TM.insert server m ss

removeSubscription :: AgentClient -> ConnId -> STM ()
removeSubscription c@AgentClient {subscrConns} connId = do
  server_ <- TM.lookupDelete connId subscrConns
  mapM_ (\server -> removeSubs_ (subscrSrvrs c) server connId) server_

removePendingSubscription :: AgentClient -> SMPServer -> ConnId -> STM ()
removePendingSubscription = removeSubs_ . pendingSubscrSrvrs

removeSubs_ :: TMap SMPServer (TMap ConnId RcvQueue) -> SMPServer -> ConnId -> STM ()
removeSubs_ ss server connId =
  TM.lookup server ss >>= mapM_ (TM.delete connId)

getSubscriptions :: AgentClient -> STM (Set ConnId)
getSubscriptions AgentClient {subscrConns} = do
  m <- readTVar subscrConns
  pure $ M.keysSet m

logServer :: MonadIO m => ByteString -> AgentClient -> SMPServer -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: SMPServer -> ByteString
showServer ProtocolServer {host, port} =
  B.pack $ host <> if null port then "" else ':' : port

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SndQueue -> ByteString -> m ()
sendConfirmation c sq@SndQueue {server, sndId, sndPublicKey = Just sndPublicKey, e2ePubKey = e2ePubKey@Just {}} agentConfirmation =
  withLogClient_ c server sndId "SEND <CONF>" $ \smp -> do
    let clientMsg = SMP.ClientMessage (SMP.PHConfirmation sndPublicKey) agentConfirmation
    msg <- agentCbEncrypt sq e2ePubKey $ smpEncode clientMsg
    liftClient SMP $ sendSMPMessage smp Nothing sndId (SMP.MsgFlags {notification = True}) msg
sendConfirmation _ _ _ = throwError $ INTERNAL "sendConfirmation called without snd_queue public key(s) in the database"

sendInvitation :: forall m. AgentMonad m => AgentClient -> Compatible SMPQueueInfo -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
sendInvitation c (Compatible SMPQueueInfo {smpServer, senderId, dhPublicKey}) connReq connInfo =
  withLogClient_ c smpServer senderId "SEND <INV>" $ \smp -> do
    msg <- mkInvitation
    liftClient SMP $ sendSMPMessage smp Nothing senderId MsgFlags {notification = True} msg
  where
    mkInvitation :: m ByteString
    -- this is only encrypted with per-queue E2E, not with double ratchet
    mkInvitation = do
      agentVersion <- asks $ smpAgentVersion . config
      let agentEnvelope = AgentInvitation {agentVersion, connReq, connInfo}
      agentCbEncryptOnce dhPublicKey . smpEncode $
        SMP.ClientMessage SMP.PHEmpty $ smpEncode agentEnvelope

getQueueMessage :: AgentMonad m => AgentClient -> RcvQueue -> ConnId -> m (Maybe SMPMsgMeta)
getQueueMessage c@AgentClient {getMsgLocks} RcvQueue {server, rcvId, rcvPrivateKey} connId =
  E.bracket (atomically createTakeLock) (atomically . (`putTMVar` ())) $ \_ ->
    withLogClient c server rcvId "GET" $ \smp ->
      getSMPMessage smp rcvPrivateKey rcvId
  where
    k = (connId, server, rcvId)
    createTakeLock = do
      l <- TM.lookup k getMsgLocks >>= maybe newLock pure
      takeTMVar l
      pure l
      where
        newLock = do
          l <- newTMVar ()
          TM.insert k l getMsgLocks
          pure l

secureQueue :: AgentMonad m => AgentClient -> RcvQueue -> SndPublicVerifyKey -> m ()
secureQueue c RcvQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogClient c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

enableQueueNotifications :: AgentMonad m => AgentClient -> RcvQueue -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> m (NotifierId, RcvNtfPublicDhKey)
enableQueueNotifications c RcvQueue {server, rcvId, rcvPrivateKey} notifierKey rcvNtfPublicDhKey =
  withLogClient c server rcvId "NKEY <nkey>" $ \smp ->
    enableSMPQueueNotifications smp rcvPrivateKey rcvId notifierKey rcvNtfPublicDhKey

sendAck :: AgentMonad m => AgentClient -> RcvQueue -> MsgId -> m ()
sendAck c RcvQueue {server, rcvId, rcvPrivateKey} msgId =
  withLogClient c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId msgId

suspendQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
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

agentCbEncrypt :: AgentMonad m => SndQueue -> Maybe C.PublicKeyX25519 -> ByteString -> m ByteString
agentCbEncrypt SndQueue {e2eDhSecret} e2ePubKey msg = do
  cmNonce <- liftIO C.randomCbNonce
  let paddedLen = maybe SMP.e2eEncMessageLength (const SMP.e2eEncConfirmationLength) e2ePubKey
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg paddedLen
  -- TODO per-queue client version
  let cmHeader = SMP.PubHeader (maxVersion SMP.smpClientVRange) e2ePubKey
  pure $ smpEncode SMP.ClientMsgEnvelope {cmHeader, cmNonce, cmEncBody}

-- add encoding as AgentInvitation'?
agentCbEncryptOnce :: AgentMonad m => C.PublicKeyX25519 -> ByteString -> m ByteString
agentCbEncryptOnce dhRcvPubKey msg = do
  (dhSndPubKey, dhSndPrivKey) <- liftIO C.generateKeyPair'
  let e2eDhSecret = C.dh' dhRcvPubKey dhSndPrivKey
  cmNonce <- liftIO C.randomCbNonce
  cmEncBody <-
    liftEither . first cryptoError $
      C.cbEncrypt e2eDhSecret cmNonce msg SMP.e2eEncConfirmationLength
  -- TODO per-queue client version
  let cmHeader = SMP.PubHeader (maxVersion SMP.smpClientVRange) (Just dhSndPubKey)
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
endAgentOperation c@AgentClient {agentEnv = Env {agentOperations}} op = do
  TM.alter (Just . maybe 0 (\n -> min 0 $ n - 1)) op agentOperations
  notifyAgentPhaseChanged c

beginAgentOperation :: AgentClient -> AgentOperation -> STM ()
beginAgentOperation AgentClient {agentEnv = Env {agentPhase, agentOperations}} op = do
  (p, _) <- readTVar agentPhase
  when (op `elem` disallowedOperations p) retry
  TM.alter (Just . maybe 1 (+ 1)) op agentOperations

notifyAgentPhaseChanged :: AgentClient -> STM ()
notifyAgentPhaseChanged AgentClient {subQ, agentEnv = Env {agentPhase, agentOperations}} = do
  (p, notified) <- readTVar agentPhase
  unless notified $ do
    ops <- readTVar agentOperations
    let opsPaused = all (maybe True (== 0) . (`M.lookup` ops)) $ disallowedOperations p
    when opsPaused $ do
      writeTBQueue subQ ("", "", PHASE p)
      writeTVar agentPhase (p, True)

withStore' :: AgentMonad m => AgentClient -> (DB.Connection -> IO a) -> m a
withStore' c action = withStore c $ fmap Right . action

withStore :: AgentMonad m => AgentClient -> (DB.Connection -> IO (Either StoreError a)) -> m a
withStore c action = do
  st <- asks store
  atomically $ beginAgentOperation c AODatabase
  r <- liftIO $ withTransaction st action `E.catch` handleInternal
  atomically $ endAgentOperation c AODatabase
  liftEither $ first storeError r
  where
    handleInternal :: SQLError -> IO (Either StoreError a)
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
