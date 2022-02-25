{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    newAgentClient,
    AgentMonad,
    withAgentLock,
    closeAgentClient,
    newRcvQueue,
    subscribeQueue,
    addSubscription,
    sendConfirmation,
    sendInvitation,
    RetryInterval (..),
    secureQueue,
    sendAgentMessage,
    agentCbEncrypt,
    agentCbDecrypt,
    cryptoError,
    sendAck,
    suspendQueue,
    deleteQueue,
    logServer,
    removeSubscription,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (Async, uninterruptibleCancel)
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol (QueueId, QueueIdsKeys (..), SndPublicVerifyKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (bshow, liftEitherError, liftError, tryError)
import Simplex.Messaging.Version
import System.Timeout (timeout)
import UnliftIO (async)
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

type SMPClientVar = TMVar (Either AgentErrorType SMPClient)

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ATransmission 'Client),
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue SMPServerTransmission,
    smpClients :: TVar (Map SMPServer SMPClientVar),
    subscrSrvrs :: TVar (Map SMPServer (Map ConnId RcvQueue)),
    pendingSubscrSrvrs :: TVar (Map SMPServer (Map ConnId RcvQueue)),
    subscrConns :: TVar (Map ConnId SMPServer),
    connMsgsQueued :: TVar (Map ConnId Bool),
    smpQueueMsgQueues :: TVar (Map (ConnId, SMPServer, SMP.SenderId) (TQueue InternalId)),
    smpQueueMsgDeliveries :: TVar (Map (ConnId, SMPServer, SMP.SenderId) (Async ())),
    reconnections :: TVar [Async ()],
    asyncClients :: TVar [Async ()],
    clientId :: Int,
    agentEnv :: Env,
    smpSubscriber :: Async (),
    lock :: TMVar ()
  }

newAgentClient :: Env -> STM AgentClient
newAgentClient agentEnv = do
  let qSize = tbqSize $ config agentEnv
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpClients <- newTVar M.empty
  subscrSrvrs <- newTVar M.empty
  pendingSubscrSrvrs <- newTVar M.empty
  subscrConns <- newTVar M.empty
  connMsgsQueued <- newTVar M.empty
  smpQueueMsgQueues <- newTVar M.empty
  smpQueueMsgDeliveries <- newTVar M.empty
  reconnections <- newTVar []
  asyncClients <- newTVar []
  clientId <- stateTVar (clientCounter agentEnv) $ \i -> (i + 1, i + 1)
  lock <- newTMVar ()
  return AgentClient {rcvQ, subQ, msgQ, smpClients, subscrSrvrs, pendingSubscrSrvrs, subscrConns, connMsgsQueued, smpQueueMsgQueues, smpQueueMsgDeliveries, reconnections, asyncClients, clientId, agentEnv, smpSubscriber = undefined, lock}

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

newtype InternalException e = InternalException {unInternalException :: e}
  deriving (Eq, Show)

instance Exception e => Exception (InternalException e)

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO :: ((forall a. ExceptT e m a -> IO a) -> IO b) -> ExceptT e m b
  withRunInIO exceptToIO =
    withExceptT unInternalException . ExceptT . E.try $
      withRunInIO $ \run ->
        exceptToIO $ run . (either (E.throwIO . InternalException) return <=< runExceptT)

getSMPServerClient :: forall m. AgentMonad m => AgentClient -> SMPServer -> m SMPClient
getSMPServerClient c@AgentClient {smpClients, msgQ} srv =
  atomically getClientVar >>= either newSMPClient waitForSMPClient
  where
    getClientVar :: STM (Either SMPClientVar SMPClientVar)
    getClientVar = maybe (Left <$> newClientVar) (pure . Right) . M.lookup srv =<< readTVar smpClients

    newClientVar :: STM SMPClientVar
    newClientVar = do
      smpVar <- newEmptyTMVar
      modifyTVar smpClients $ M.insert srv smpVar
      pure smpVar

    waitForSMPClient :: TMVar (Either AgentErrorType SMPClient) -> m SMPClient
    waitForSMPClient smpVar = do
      SMPClientConfig {tcpTimeout} <- asks $ smpCfg . config
      smpClient_ <- liftIO $ tcpTimeout `timeout` atomically (readTMVar smpVar)
      liftEither $ case smpClient_ of
        Just (Right smpClient) -> Right smpClient
        Just (Left e) -> Left e
        Nothing -> Left $ BROKER TIMEOUT

    newSMPClient :: TMVar (Either AgentErrorType SMPClient) -> m SMPClient
    newSMPClient smpVar = tryConnectClient pure tryConnectAsync
      where
        tryConnectClient :: (SMPClient -> m a) -> m () -> m a
        tryConnectClient successAction retryAction =
          tryError connectClient >>= \r -> case r of
            Right smp -> do
              logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
              atomically $ putTMVar smpVar r
              successAction smp
            Left e -> do
              if e == BROKER NETWORK || e == BROKER TIMEOUT
                then retryAction
                else atomically $ do
                  putTMVar smpVar (Left e)
                  modifyTVar smpClients $ M.delete srv
              throwError e
        tryConnectAsync :: m ()
        tryConnectAsync = do
          a <- async connectAsync
          atomically $ modifyTVar (asyncClients c) (a :)
        connectAsync :: m ()
        connectAsync = do
          ri <- asks $ reconnectInterval . config
          withRetryInterval ri $ \loop -> void $ tryConnectClient (const reconnectClient) loop

    connectClient :: m SMPClient
    connectClient = do
      cfg <- asks $ smpCfg . config
      u <- askUnliftIO
      liftEitherError smpClientError (getSMPClient srv cfg msgQ $ clientDisconnected u)
        `E.catch` internalError
      where
        internalError :: IOException -> m SMPClient
        internalError = throwError . INTERNAL . show

    clientDisconnected :: UnliftIO m -> IO ()
    clientDisconnected u = do
      removeClientSubs >>= (`forM_` serverDown u)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeClientSubs :: IO (Maybe (Map ConnId RcvQueue))
    removeClientSubs = atomically $ do
      modifyTVar smpClients $ M.delete srv
      cs <- M.lookup srv <$> readTVar (subscrSrvrs c)
      modifyTVar (subscrSrvrs c) $ M.delete srv
      modifyTVar (subscrConns c) $ maybe id (deleteKeys . M.keysSet) cs
      mapM_ (modifyTVar (pendingSubscrSrvrs c) . addPendingSubs) cs
      return cs
      where
        addPendingSubs :: Map ConnId RcvQueue -> Map SMPServer (Map ConnId RcvQueue) -> Map SMPServer (Map ConnId RcvQueue)
        addPendingSubs cs = M.alter (Just . addSubs cs) srv
        addSubs cs = maybe cs (M.union cs)
        deleteKeys :: Ord k => Set k -> Map k a -> Map k a
        deleteKeys ks m = S.foldr' M.delete m ks

    serverDown :: UnliftIO m -> Map ConnId RcvQueue -> IO ()
    serverDown u cs = unless (M.null cs) $ do
      mapM_ (notifySub DOWN) $ M.keysSet cs
      unliftIO u reconnectServer

    reconnectServer :: m ()
    reconnectServer = do
      a <- async tryReconnectClient
      atomically $ modifyTVar (reconnections c) (a :)

    tryReconnectClient :: m ()
    tryReconnectClient = do
      ri <- asks $ reconnectInterval . config
      withRetryInterval ri $ \loop ->
        reconnectClient `catchError` const loop

    reconnectClient :: m ()
    reconnectClient = do
      withAgentLock c . withSMP c srv $ \smp -> do
        subs <- readTVarIO $ subscrConns c
        cs <- M.lookup srv <$> readTVarIO (pendingSubscrSrvrs c)
        forM_ (maybe [] M.toList cs) $ \(connId, rq@RcvQueue {rcvPrivateKey, rcvId}) ->
          when (isNothing $ M.lookup connId subs) $ do
            subscribeSMPQueue smp rcvPrivateKey rcvId
              `catchError` \case
                e@SMPResponseTimeout -> throwError e
                e@SMPNetworkError -> throwError e
                e -> liftIO $ notifySub (ERR $ smpClientError e) connId
            addSubscription c rq connId
            liftIO $ notifySub UP connId

    notifySub :: ACommand 'Agent -> ConnId -> IO ()
    notifySub cmd connId = atomically $ writeTBQueue (subQ c) ("", connId, cmd)

closeAgentClient :: MonadUnliftIO m => AgentClient -> m ()
closeAgentClient c = liftIO $ do
  closeSMPServerClients c
  cancelActions $ reconnections c
  cancelActions $ asyncClients c
  cancelActions $ smpQueueMsgDeliveries c

closeSMPServerClients :: AgentClient -> IO ()
closeSMPServerClients c = readTVarIO (smpClients c) >>= mapM_ (forkIO . closeClient)
  where
    closeClient smpVar =
      atomically (readTMVar smpVar) >>= \case
        Right smp -> closeSMPClient smp `E.catch` \(_ :: E.SomeException) -> pure ()
        _ -> pure ()

cancelActions :: Foldable f => TVar (f (Async ())) -> IO ()
cancelActions as = readTVarIO as >>= mapM_ uninterruptibleCancel

withAgentLock :: MonadUnliftIO m => AgentClient -> m a -> m a
withAgentLock AgentClient {lock} =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

withSMP_ :: forall a m. AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> m a) -> m a
withSMP_ c srv action =
  (getSMPServerClient c srv >>= action) `catchError` logServerError
  where
    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ bshow e
      throwError e

withLogSMP_ :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> m a) -> m a
withLogSMP_ c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withSMP_ c srv action
  logServer "<--" c srv qId "OK"
  return res

withSMP :: AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withSMP c srv action = withSMP_ c srv $ liftSMP . action

withLogSMP :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withLogSMP c srv qId cmdStr action = withLogSMP_ c srv qId cmdStr $ liftSMP . action

liftSMP :: AgentMonad m => ExceptT SMPClientError IO a -> m a
liftSMP = liftError smpClientError

smpClientError :: SMPClientError -> AgentErrorType
smpClientError = \case
  SMPServerError e -> SMP e
  SMPResponseError e -> BROKER $ RESPONSE e
  SMPUnexpectedResponse -> BROKER UNEXPECTED
  SMPResponseTimeout -> BROKER TIMEOUT
  SMPNetworkError -> BROKER NETWORK
  SMPTransportError e -> BROKER $ TRANSPORT e
  e -> INTERNAL $ show e

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
    withSMP c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey dhKey
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
            status = New
          }
  pure (rq, SMPQueueUri srv sndId SMP.smpClientVRange e2eDhKey)

subscribeQueue :: AgentMonad m => AgentClient -> RcvQueue -> ConnId -> m ()
subscribeQueue c rq@RcvQueue {server, rcvPrivateKey, rcvId} connId = do
  addPendingSubscription c rq connId
  withLogSMP c server rcvId "SUB" $ \smp -> do
    liftIO (runExceptT $ subscribeSMPQueue smp rcvPrivateKey rcvId) >>= \case
      Left e -> do
        atomically . when (e /= SMPNetworkError && e /= SMPResponseTimeout) $
          removePendingSubscription c server connId
        throwError e
      Right _ -> addSubscription c rq connId

addSubscription :: MonadUnliftIO m => AgentClient -> RcvQueue -> ConnId -> m ()
addSubscription c rq@RcvQueue {server} connId = atomically $ do
  modifyTVar (subscrConns c) $ M.insert connId server
  addSubs_ (subscrSrvrs c) rq connId
  removePendingSubscription c server connId

addPendingSubscription :: MonadUnliftIO m => AgentClient -> RcvQueue -> ConnId -> m ()
addPendingSubscription c rq connId =
  atomically $ addSubs_ (pendingSubscrSrvrs c) rq connId

addSubs_ :: TVar (Map SMPServer (Map ConnId RcvQueue)) -> RcvQueue -> ConnId -> STM ()
addSubs_ ss rq@RcvQueue {server} connId = modifyTVar ss $ M.alter (Just . addSub) server
  where
    addSub = maybe (M.singleton connId rq) (M.insert connId rq)

removeSubscription :: MonadUnliftIO m => AgentClient -> ConnId -> m ()
removeSubscription c@AgentClient {subscrConns} connId = atomically $ do
  server_ <- stateTVar subscrConns $ \cs -> (M.lookup connId cs, M.delete connId cs)
  mapM_ (\server -> removeSubs_ (subscrSrvrs c) server connId) server_

removePendingSubscription :: AgentClient -> SMPServer -> ConnId -> STM ()
removePendingSubscription c = removeSubs_ (pendingSubscrSrvrs c)

removeSubs_ :: TVar (Map SMPServer (Map ConnId RcvQueue)) -> SMPServer -> ConnId -> STM ()
removeSubs_ ss server connId = modifyTVar ss $ M.update delSub server
  where
    delSub :: Map ConnId RcvQueue -> Maybe (Map ConnId RcvQueue)
    delSub cs =
      let cs' = M.delete connId cs
       in if M.null cs' then Nothing else Just cs'

logServer :: AgentMonad m => ByteString -> AgentClient -> SMPServer -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: SMPServer -> ByteString
showServer SMPServer {host, port} =
  B.pack $ host <> if null port then "" else ':' : port

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

-- TODO maybe package E2ERatchetParams into SMPConfirmation
sendConfirmation :: forall m. AgentMonad m => AgentClient -> SndQueue -> ByteString -> m ()
sendConfirmation c SndQueue {server, sndId} encConfirmation =
  withLogSMP_ c server sndId "SEND <CONF>" $ \smp ->
    liftSMP $ sendSMPMessage smp Nothing sndId encConfirmation

sendInvitation :: forall m. AgentMonad m => AgentClient -> Compatible SMPQueueInfo -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
sendInvitation c (Compatible SMPQueueInfo {smpServer, senderId, dhPublicKey}) connReq connInfo =
  withLogSMP_ c smpServer senderId "SEND <INV>" $ \smp -> do
    msg <- mkInvitation
    liftSMP $ sendSMPMessage smp Nothing senderId msg
  where
    mkInvitation :: m ByteString
    -- this is only encrypted with per-queue E2E, not with double ratchet
    mkInvitation = do
      let agentEnvelope = AgentInvitation {agentVersion = smpAgentVersion, connReq, connInfo}
      agentCbEncryptOnce dhPublicKey . smpEncode $
        SMP.ClientMessage SMP.PHEmpty $ smpEncode agentEnvelope

secureQueue :: AgentMonad m => AgentClient -> RcvQueue -> SndPublicVerifyKey -> m ()
secureQueue c RcvQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogSMP c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

sendAck :: AgentMonad m => AgentClient -> RcvQueue -> m ()
sendAck c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId

suspendQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
suspendQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
deleteQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

sendAgentMessage :: forall m. AgentMonad m => AgentClient -> SndQueue -> ByteString -> m ()
sendAgentMessage c sq@SndQueue {server, sndId, sndPrivateKey} agentMsg =
  withLogSMP_ c server sndId "SEND <MSG>" $ \smp -> do
    let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
    msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
    liftSMP $ sendSMPMessage smp (Just sndPrivateKey) sndId msg

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
  e -> INTERNAL $ show e
