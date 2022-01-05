{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      : Simplex.Messaging.Agent
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol agent with SQLite persistence.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md
module Simplex.Messaging.Agent
  ( -- * SMP agent over TCP
    runSMPAgent,
    runSMPAgentBlocking,

    -- * queue-based SMP agent
    getAgentClient,
    runAgentClient,

    -- * SMP agent functional API
    AgentClient (..),
    AgentMonad,
    AgentErrorMonad,
    getSMPAgentClient,
    disconnectAgentClient, -- used in tests
    withAgentLock,
    createConnection,
    joinConnection,
    allowConnection,
    acceptContact,
    rejectContact,
    subscribeConnection,
    sendMessage,
    ackMessage,
    suspendConnection,
    deleteConnection,
  )
where

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple (logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.Bifunctor (second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:), (.:.))
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock
import Data.Time.Clock.System (systemToUTCTime)
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol (MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..), loadTLSServerParams, runTransportServer, simplexMQVersion)
import Simplex.Messaging.Util (bshow, tryError, unlessM)
import Simplex.Messaging.Version
import System.Random (randomR)
import UnliftIO.Async (async, race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Runs an SMP agent as a TCP service using passed configuration.
--
-- See a full agent executable here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-agent/Main.hs
runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => ATransport -> AgentConfig -> m ()
runSMPAgent t cfg = do
  started <- newEmptyTMVarIO
  runSMPAgentBlocking t started cfg

-- | Runs an SMP agent as a TCP service using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPAgentBlocking :: (MonadRandom m, MonadUnliftIO m) => ATransport -> TMVar Bool -> AgentConfig -> m ()
runSMPAgentBlocking (ATransport t) started cfg@AgentConfig {tcpPort, caCertificateFile, certificateFile, privateKeyFile} = do
  runReaderT (smpAgent t) =<< newSMPAgentEnv cfg
  where
    smpAgent :: forall c m'. (Transport c, MonadUnliftIO m', MonadReader Env m') => TProxy c -> m' ()
    smpAgent _ = do
      -- tlsServerParams is not in Env to avoid breaking functional API w/t key and certificate generation
      tlsServerParams <- liftIO $ loadTLSServerParams caCertificateFile certificateFile privateKeyFile
      runTransportServer started tcpPort tlsServerParams $ \(h :: c) -> do
        liftIO . putLn h $ "Welcome to SMP agent v" <> B.pack simplexMQVersion
        c <- getAgentClient
        logConnection c True
        race_ (connectClient h c) (runAgentClient c)
          `E.finally` disconnectAgentClient c

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m AgentClient
getSMPAgentClient cfg = newSMPAgentEnv cfg >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient
      action <- async $ subscriber c `E.finally` disconnectAgentClient c
      pure c {smpSubscriber = action}

disconnectAgentClient :: MonadUnliftIO m => AgentClient -> m ()
disconnectAgentClient c = closeAgentClient c >> logConnection c False

-- |
type AgentErrorMonad m = (MonadUnliftIO m, MonadError AgentErrorType m)

-- | Create SMP agent connection (NEW command)
createConnection :: AgentErrorMonad m => AgentClient -> SConnectionMode c -> m (ConnId, ConnectionRequestUri c)
createConnection c cMode = withAgentEnv c $ newConn c "" cMode

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConnection c = withAgentEnv c .: joinConn c ""

-- | Allow connection to continue after CONF notification (LET command)
allowConnection :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection c = withAgentEnv c .:. allowConnection' c

-- | Accept contact after REQ notification (ACPT command)
acceptContact :: AgentErrorMonad m => AgentClient -> ConfirmationId -> ConnInfo -> m ConnId
acceptContact c = withAgentEnv c .: acceptContact' c ""

-- | Reject contact (RJCT command)
rejectContact :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> m ()
rejectContact c = withAgentEnv c .: rejectContact' c

-- | Subscribe to receive connection messages (SUB command)
subscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
subscribeConnection c = withAgentEnv c . subscribeConnection' c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgBody -> m AgentMsgId
sendMessage c = withAgentEnv c .: sendMessage' c

ackMessage :: AgentErrorMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage c = withAgentEnv c .: ackMessage' c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
suspendConnection c = withAgentEnv c . suspendConnection' c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c = withAgentEnv c . deleteConnection' c

withAgentEnv :: AgentClient -> ReaderT Env m a -> m a
withAgentEnv c = (`runReaderT` agentEnv c)

-- withAgentClient :: AgentErrorMonad m => AgentClient -> ReaderT Env m a -> m a
-- withAgentClient c = withAgentLock c . withAgentEnv c

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
getAgentClient :: (MonadUnliftIO m, MonadReader Env m) => m AgentClient
getAgentClient = ask >>= atomically . newAgentClient

connectClient :: Transport c => MonadUnliftIO m => c -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runAgentClient c = race_ (subscriber c) (client c)

receive :: forall c m. (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
receive h c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, connId, cmdOrErr) <- tGet SClient h
  case cmdOrErr of
    Right cmd -> write rcvQ (corrId, connId, cmd)
    Left e -> write subQ (corrId, connId, ERR e)
  where
    write :: TBQueue (ATransmission p) -> ATransmission p -> m ()
    write q t = do
      logClient c "-->" t
      atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
send h c@AgentClient {subQ} = forever $ do
  t <- atomically $ readTBQueue subQ
  tPut h t
  logClient c "<--" t

logClient :: MonadUnliftIO m => AgentClient -> ByteString -> ATransmission a -> m ()
logClient AgentClient {clientId} dir (corrId, connId, cmd) = do
  logInfo . decodeUtf8 $ B.unwords [bshow clientId, dir, "A :", corrId, connId, B.takeWhile (/= ' ') $ serializeCommand cmd]

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
client c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, connId, cmd) <- atomically $ readTBQueue rcvQ
  withAgentLock c (runExceptT $ processCommand c (connId, cmd))
    >>= atomically . writeTBQueue subQ . \case
      Left e -> (corrId, connId, ERR e)
      Right (connId', resp) -> (corrId, connId', resp)

withStore ::
  AgentMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => SQLiteStore -> m' a) ->
  m a
withStore action = do
  st <- asks store
  runExceptT (action st `E.catch` handleInternal) >>= \case
    Right c -> return c
    Left e -> throwError $ storeError e
  where
    -- TODO when parsing exception happens in store, the agent hangs;
    -- changing SQLError to SomeException does not help
    handleInternal :: (MonadError StoreError m') => SQLError -> m' a
    handleInternal e = throwError . SEInternal $ bshow e
    storeError :: StoreError -> AgentErrorType
    storeError = \case
      SEConnNotFound -> CONN NOT_FOUND
      SEConnDuplicate -> CONN DUPLICATE
      SEBadConnType CRcv -> CONN SIMPLEX
      SEBadConnType CSnd -> CONN SIMPLEX
      SEInvitationNotFound -> CMD PROHIBITED
      e -> INTERNAL $ show e

-- | execute any SMP agent command
processCommand :: forall m. AgentMonad m => AgentClient -> (ConnId, ACommand 'Client) -> m (ConnId, ACommand 'Agent)
processCommand c (connId, cmd) = case cmd of
  NEW (ACM cMode) -> second (INV . ACRU cMode) <$> newConn c connId cMode
  JOIN (ACRU _ cReq) connInfo -> (,OK) <$> joinConn c connId cReq connInfo
  LET confId ownCInfo -> allowConnection' c connId confId ownCInfo $> (connId, OK)
  ACPT invId ownCInfo -> (,OK) <$> acceptContact' c connId invId ownCInfo
  RJCT invId -> rejectContact' c connId invId $> (connId, OK)
  SUB -> subscribeConnection' c connId $> (connId, OK)
  SEND msgBody -> (connId,) . MID <$> sendMessage' c connId msgBody
  ACK msgId -> ackMessage' c connId msgId $> (connId, OK)
  OFF -> suspendConnection' c connId $> (connId, OK)
  DEL -> deleteConnection' c connId $> (connId, OK)

newConn :: AgentMonad m => AgentClient -> ConnId -> SConnectionMode c -> m (ConnId, ConnectionRequestUri c)
newConn c connId cMode = do
  srv <- getSMPServer
  (rq, qUri) <- newRcvQueue c srv
  g <- asks idsDrg
  let cData = ConnData {connId}
  connId' <- withStore $ \st -> createRcvConn st g cData rq cMode
  addSubscription c rq connId'
  let crData = ConnReqUriData simplexChat smpAgentVRange [qUri]
  pure . (connId',) $ case cMode of
    SCMInvitation -> CRInvitationUri crData connEncStubUri
    SCMContact -> CRContactUri crData

joinConn :: AgentMonad m => AgentClient -> ConnId -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConn c connId (CRInvitationUri (ConnReqUriData _ _ (qUri :| _)) _e2eEnc) cInfo = do
  -- TODO check all versions in connection request are compatible with supported
  -- (add agent and e2e)
  case qUri `compatibleVersion` SMP.smpClientVersion of
    Nothing -> throwError $ AGENT A_VERSION
    Just qInfo -> do
      (sq, smpConf) <- newSndQueue qInfo cInfo
      g <- asks idsDrg
      let cData = ConnData {connId}
      connId' <- withStore $ \st -> createSndConn st g cData sq
      confirmQueue c sq smpConf
      void $ enqueueMessage c connId' sq HELLO
      pure connId'
joinConn c connId (CRContactUri (ConnReqUriData _ _ (qUri :| _))) cInfo = do
  (connId', cReq) <- newConn c connId SCMInvitation
  sendInvitation c qUri cReq cInfo
  pure connId'

createReplyQueue :: AgentMonad m => AgentClient -> ConnId -> SndQueue -> m ()
createReplyQueue c connId sq = do
  srv <- getSMPServer
  (rq, qUri) <- newRcvQueue c srv
  -- TODO reply queue version should be the same as send queue, ignoring it in v1
  let qInfo = toVersionT qUri (maxVersion SMP.smpClientVersion)
  addSubscription c rq connId
  withStore $ \st -> upgradeSndConnToDuplex st connId rq
  void . enqueueMessage c connId sq $ REPLY [qInfo]

-- | Approve confirmation (LET command) in Reader monad
allowConnection' :: AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection' c connId confId ownConnInfo = do
  withStore (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection _ rq) -> do
      AcceptedConfirmation {senderConf} <- withStore $ \st -> acceptConfirmation st confId ownConnInfo
      processConfirmation c rq senderConf
    _ -> throwError $ CMD PROHIBITED

-- | Accept contact (ACPT command) in Reader monad
acceptContact' :: AgentMonad m => AgentClient -> ConnId -> InvitationId -> ConnInfo -> m ConnId
acceptContact' c connId invId ownConnInfo = do
  Invitation {contactConnId, connReq} <- withStore (`getInvitation` invId)
  withStore (`getConn` contactConnId) >>= \case
    SomeConn _ ContactConnection {} -> do
      withStore $ \st -> acceptInvitation st invId ownConnInfo
      joinConn c connId connReq ownConnInfo
    _ -> throwError $ CMD PROHIBITED

-- | Reject contact (RJCT command) in Reader monad
rejectContact' :: AgentMonad m => AgentClient -> ConnId -> InvitationId -> m ()
rejectContact' _ contactConnId invId =
  withStore $ \st -> deleteInvitation st contactConnId invId

processConfirmation :: AgentMonad m => AgentClient -> RcvQueue -> SMPConfirmation -> m ()
processConfirmation c rq@RcvQueue {e2ePrivKey} SMPConfirmation {senderKey, e2ePubKey} = do
  let dhSecret = C.dh' e2ePubKey e2ePrivKey
  withStore $ \st -> setRcvQueueConfirmedE2E st rq dhSecret
  secureQueue c rq senderKey
  withStore $ \st -> setRcvQueueStatus st rq Secured

-- | Subscribe to receive connection messages (SUB command) in Reader monad
subscribeConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
subscribeConnection' c connId =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq sq) -> do
      resumeMsgDelivery c connId sq
      subscribeQueue c rq connId
      case status (sq :: SndQueue) of
        Confirmed -> do
          -- TODO if there is no confirmation saved, just update the status without securing the queue
          AcceptedConfirmation {senderConf = SMPConfirmation {senderKey}} <-
            withStore (`getAcceptedConfirmation` connId)
          secureQueue c rq senderKey
          withStore $ \st -> setRcvQueueStatus st rq Secured
        Secured -> pure ()
        Active -> pure ()
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (SndConnection _ sq) -> do
      resumeMsgDelivery c connId sq
      case status (sq :: SndQueue) of
        Confirmed -> pure ()
        Active -> throwError $ CONN SIMPLEX
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (RcvConnection _ rq) -> subscribeQueue c rq connId
    SomeConn _ (ContactConnection _ rq) -> subscribeQueue c rq connId

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgBody -> m AgentMsgId
sendMessage' c connId msg =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ _ sq) -> enqueueMsg sq
    SomeConn _ (SndConnection _ sq) -> enqueueMsg sq
    _ -> throwError $ CONN SIMPLEX
  where
    enqueueMsg :: SndQueue -> m AgentMsgId
    enqueueMsg sq = enqueueMessage c connId sq $ A_MSG msg

enqueueMessage :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> AMessage -> m AgentMsgId
enqueueMessage c connId sq@SndQueue {server} aMessage = do
  resumeMsgDelivery c connId sq
  msgId <- storeSentMsg
  queuePendingMsgs c connId server [msgId]
  pure $ unId msgId
  where
    storeSentMsg :: m InternalId
    storeSentMsg = do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- withStore (`updateSndIds` connId)
      let privHeader = APrivHeader (unSndId internalSndId) prevMsgHash
          agentMessage = smpEncode $ AgentMessage' privHeader aMessage
          internalHash = C.sha256Hash agentMessage

      encAgentMessage <- agentRatchetEncrypt agentMessage
      let agentEnvelope = AgentMsgEnvelope {agentVersion = smpAgentVersion, encAgentMessage}
          clientMsg = SMP.ClientMessage SMP.PHEmpty $ smpEncode agentEnvelope
      msgBody <- agentCbEncrypt sq Nothing $ smpEncode clientMsg

      let msgType = aMessageType aMessage
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, internalHash, prevMsgHash}
      withStore $ \st -> createSndMsg st connId msgData
      pure internalId

resumeMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> m ()
resumeMsgDelivery c connId SndQueue {server} = do
  unlessM srvDelivering $
    async (runSrvMsgDelivery c server)
      >>= atomically . modifyTVar (srvMsgDeliveries c) . M.insert server
  unlessM connQueued $
    withStore (`getPendingMsgs` connId)
      >>= queuePendingMsgs c connId server
  where
    srvDelivering = isJust . M.lookup server <$> readTVarIO (srvMsgDeliveries c)
    connQueued =
      atomically $
        isJust
          <$> stateTVar
            (connMsgsQueued c)
            (\m -> (M.lookup connId m, M.insert connId True m))

queuePendingMsgs :: AgentMonad m => AgentClient -> ConnId -> SMPServer -> [InternalId] -> m ()
queuePendingMsgs c connId server msgIds = atomically $ do
  q <- getPendingMsgQ c server
  mapM_ (writeTQueue q . PendingMsg connId) msgIds

getPendingMsgQ :: AgentClient -> SMPServer -> STM (TQueue PendingMsg)
getPendingMsgQ c srv = do
  maybe newMsgQueue pure . M.lookup srv =<< readTVar (srvMsgQueues c)
  where
    newMsgQueue :: STM (TQueue PendingMsg)
    newMsgQueue = do
      mq <- newTQueue
      modifyTVar (srvMsgQueues c) $ M.insert srv mq
      pure mq

runSrvMsgDelivery :: forall m. AgentMonad m => AgentClient -> SMPServer -> m ()
runSrvMsgDelivery c@AgentClient {subQ} srv = do
  mq <- atomically $ getPendingMsgQ c srv
  ri <- asks $ reconnectInterval . config
  forever $ do
    PendingMsg {connId, msgId} <- atomically $ readTQueue mq
    let mId = unId msgId
    withStore (\st -> E.try $ getPendingMsgData st connId msgId) >>= \case
      Left (e :: E.SomeException) ->
        notify connId $ MERR mId (INTERNAL $ show e)
      Right (sq, rq_, (msgType, msgBody)) -> do
        withRetryInterval ri $ \loop -> do
          tryError (sendAgentMessage c sq msgBody) >>= \case
            Left e -> case e of
              SMP SMP.QUOTA -> loop
              SMP SMP.AUTH -> case msgType of
                HELLO_ -> loop
                REPLY_ -> notify connId $ ERR e
                A_MSG_ -> notify connId $ MERR mId e
              SMP {} -> notify connId $ MERR mId e
              CMD {} -> notify connId $ MERR mId e
              _ -> loop
            Right () -> do
              case msgType of
                HELLO_ -> do
                  withStore $ \st -> setSndQueueStatus st sq Active
                  case rq_ of
                    -- party initiating connection
                    Just rq -> do
                      subscribeQueue c rq connId
                      notify connId CON
                    -- party joining connection
                    _ -> createReplyQueue c connId sq
                A_MSG_ -> notify connId $ SENT mId
                _ -> pure ()
              withStore $ \st -> updateSndMsgStatus st connId msgId SndMsgSent
  where
    notify :: ConnId -> ACommand 'Agent -> m ()
    notify connId cmd = atomically $ writeTBQueue subQ ("", connId, cmd)

ackMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage' c connId msgId = do
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> ack rq
    SomeConn _ (RcvConnection _ rq) -> ack rq
    _ -> throwError $ CONN SIMPLEX
  where
    ack :: RcvQueue -> m ()
    ack rq = do
      let mId = InternalId msgId
      withStore $ \st -> checkRcvMsg st connId mId
      sendAck c rq
      withStore $ \st -> deleteMsg st connId mId

-- | Suspend SMP agent connection (OFF command) in Reader monad
suspendConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
suspendConnection' c connId =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> suspendQueue c rq
    SomeConn _ (RcvConnection _ rq) -> suspendQueue c rq
    _ -> throwError $ CONN SIMPLEX

-- | Delete SMP agent connection (DEL command) in Reader monad
deleteConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
deleteConnection' c connId =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> delete rq
    SomeConn _ (RcvConnection _ rq) -> delete rq
    SomeConn _ (ContactConnection _ rq) -> delete rq
    SomeConn _ (SndConnection _ _) -> withStore (`deleteConn` connId)
  where
    delete :: RcvQueue -> m ()
    delete rq = do
      deleteQueue c rq
      removeSubscription c connId
      withStore (`deleteConn` connId)

getSMPServer :: AgentMonad m => m SMPServer
getSMPServer =
  asks (smpServers . config) >>= \case
    srv :| [] -> pure srv
    servers -> do
      gen <- asks randomServer
      i <- atomically . stateTVar gen $ randomR (0, L.length servers - 1)
      pure $ servers L.!! i

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  t <- atomically $ readTBQueue msgQ
  withAgentLock c (runExceptT $ processSMPTransmission c t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> SMPServerTransmission -> m ()
processSMPTransmission c@AgentClient {subQ} (srv, rId, cmd) = do
  withStore (\st -> getRcvConn st srv rId) >>= \case
    SomeConn SCDuplex (DuplexConnection cData rq _) -> processSMP SCDuplex cData rq
    SomeConn SCRcv (RcvConnection cData rq) -> processSMP SCRcv cData rq
    SomeConn SCContact (ContactConnection cData rq) -> processSMP SCContact cData rq
    _ -> atomically $ writeTBQueue subQ ("", "", ERR $ CONN NOT_FOUND)
  where
    processSMP :: SConnType c -> ConnData -> RcvQueue -> m ()
    processSMP cType ConnData {connId} rq@RcvQueue {rcvDhSecret, e2ePrivKey, e2eDhSecret, status} =
      case cmd of
        SMP.MSG srvMsgId srvTs msgBody' -> handleNotifyAck $ do
          -- TODO deduplicate with previously received
          msgBody <- agentCbDecrypt rcvDhSecret (C.cbNonce srvMsgId) msgBody'
          clientMsg@SMP.ClientMsgEnvelope {cmHeader = SMP.PubHeader v e2ePubKey_} <-
            parseMessage msgBody
          case (e2eDhSecret, e2ePubKey_) of
            (Nothing, Just e2ePubKey) -> do
              let e2eDh = C.dh' e2ePubKey e2ePrivKey
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHConfirmation senderKey, AgentConfirmation {agentVersion = _v, e2eEncryption, encConnInfo}) -> do
                  agentMsgBody <- agentRatchetDecrypt encConnInfo
                  agentMessage <- parseMessage agentMsgBody
                  case agentMessage of
                    AgentConnInfo connInfo -> do
                      smpConfirmation SMPConfirmation {senderKey, e2ePubKey, connInfo}
                      ack
                    _ -> prohibited >> ack
                (SMP.PHEmpty, AgentInvitation' {agentVersion = _v, connReq, connInfo}) ->
                  smpInvitation connReq connInfo >> ack
                _ -> prohibited >> ack
            (Just e2eDh, Nothing) -> do
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHEmpty, AgentMsgEnvelope _v encAgentMsg) -> do
                  agentMsgBody <- agentRatchetDecrypt encAgentMsg
                  agentMessage <- parseMessage agentMsgBody
                  case agentMessage of
                    AgentMessage' APrivHeader {sndMsgId, prevMsgHash} aMessage -> do
                      msgMeta <- agentClientMsg' prevMsgHash sndMsgId (srvMsgId, systemToUTCTime srvTs) agentMsgBody aMessage
                      case aMessage of
                        HELLO -> helloMsg >> ack
                        REPLY cReq -> replyMsg cReq >> ack
                        -- note that there is no ACK sent here, it is sent with agent's user ACK command
                        A_MSG body -> notify $ MSG msgMeta body
                    _ -> prohibited >> ack
                _ -> prohibited >> ack
            _ -> prohibited >> ack
        SMP.END -> do
          removeSubscription c connId
          logServer "<--" c srv rId "END"
          notify END
        _ -> do
          logServer "<--" c srv rId $ "unexpected: " <> bshow cmd
          notify . ERR $ BROKER UNEXPECTED
      where
        notify :: ACommand 'Agent -> m ()
        notify msg = atomically $ writeTBQueue subQ ("", connId, msg)

        handleNotifyAck :: m () -> m ()
        handleNotifyAck m = m `catchError` \e -> notify (ERR e) >> ack

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        ack :: m ()
        ack = sendAck c rq

        decryptClientMessage :: C.DhSecretX25519 -> SMP.ClientMsgEnvelope -> m (SMP.PrivHeader, AgentMsgEnvelope)
        decryptClientMessage e2eDh SMP.ClientMsgEnvelope {cmNonce, cmEncBody} = do
          clientMsg <- agentCbDecrypt e2eDh cmNonce cmEncBody
          SMP.ClientMessage privHeader clientBody <- parseMessage clientMsg
          agentEnvelope <- parseMessage clientBody
          pure (privHeader, agentEnvelope)

        parseMessage :: Encoding a => ByteString -> m a
        parseMessage = liftEither . parse smpP (AGENT A_MESSAGE)

        smpConfirmation :: SMPConfirmation -> m ()
        smpConfirmation senderConf@SMPConfirmation {connInfo} = do
          logServer "<--" c srv rId "MSG <KEY>"
          case status of
            New -> case cType of
              SCRcv -> do
                g <- asks idsDrg
                let newConfirmation = NewConfirmation {connId, senderConf}
                confId <- withStore $ \st -> createConfirmation st g newConfirmation
                notify $ CONF confId connInfo
              SCDuplex -> do
                notify $ INFO connInfo
                processConfirmation c rq senderConf
              _ -> prohibited
            _ -> prohibited

        helloMsg :: m ()
        helloMsg = do
          logServer "<--" c srv rId "MSG <HELLO>"
          case status of
            Active -> prohibited
            _ -> do
              withStore $ \st -> setRcvQueueStatus st rq Active
              case cType of
                SCDuplex -> notifyConnected c connId
                _ -> pure ()

        replyMsg :: L.NonEmpty SMPQueueInfo -> m ()
        replyMsg (qInfo :| _) = do
          logServer "<--" c srv rId "MSG <REPLY>"
          case cType of
            SCRcv -> do
              AcceptedConfirmation {ownConnInfo} <- withStore (`getAcceptedConfirmation` connId)
              case qInfo `proveCompatible` SMP.smpClientVersion of
                Nothing -> notify (ERR $ AGENT A_VERSION) >> ack
                Just qInfo' -> do
                  (sq, smpConf) <- newSndQueue qInfo' ownConnInfo
                  withStore $ \st -> upgradeRcvConnToDuplex st connId sq
                  confirmQueue c sq smpConf
                  withStore (`removeConfirmations` connId)
                  void $ enqueueMessage c connId sq HELLO
            _ -> prohibited

        agentClientMsg' :: PrevRcvMsgHash -> ExternalSndId -> (BrokerId, BrokerTs) -> MsgBody -> AMessage -> m MsgMeta
        agentClientMsg' externalPrevSndHash sndMsgId broker msgBody aMessage = do
          logServer "<--" c srv rId "MSG <MSG>"
          let internalHash = C.sha256Hash msgBody
          internalTs <- liftIO getCurrentTime
          (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- withStore (`updateRcvIds` connId)
          let integrity = checkMsgIntegrity prevExtSndId sndMsgId prevRcvMsgHash externalPrevSndHash
              recipient = (unId internalId, internalTs)
              msgMeta = MsgMeta {integrity, recipient, broker, sndMsgId}
              msgType = aMessageType aMessage
              rcvMsg = RcvMsgData {msgMeta, msgType, msgBody, internalRcvId, internalHash, externalPrevSndHash}
          withStore $ \st -> createRcvMsg st connId rcvMsg
          pure msgMeta

        smpInvitation :: ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
        smpInvitation connReq cInfo = do
          logServer "<--" c srv rId "MSG <KEY>"
          case cType of
            SCContact -> do
              g <- asks idsDrg
              let newInv = NewInvitation {contactConnId = connId, connReq, recipientConnInfo = cInfo}
              invId <- withStore $ \st -> createInvitation st g newInv
              notify $ REQ invId cInfo
            _ -> prohibited

        checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
        checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
          | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
          | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
          | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
          | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
          | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
          | otherwise = MsgError MsgDuplicate -- this case is not possible

confirmQueue :: AgentMonad m => AgentClient -> SndQueue -> SMPConfirmation -> m ()
confirmQueue c sq smpConf = do
  sendConfirmation c sq smpConf connEncStub
  withStore $ \st -> setSndQueueStatus st sq Confirmed

notifyConnected :: AgentMonad m => AgentClient -> ConnId -> m ()
notifyConnected c connId = atomically $ writeTBQueue (subQ c) ("", connId, CON)

newSndQueue :: (MonadUnliftIO m, MonadReader Env m) => Compatible SMPQueueInfo -> ConnInfo -> m (SndQueue, SMPConfirmation)
newSndQueue qInfo cInfo =
  asks (cmdSignAlg . config) >>= \case
    C.SignAlg a -> newSndQueue_ a qInfo cInfo

newSndQueue_ ::
  (C.SignatureAlgorithm a, C.AlgorithmI a, MonadUnliftIO m) =>
  C.SAlgorithm a ->
  Compatible SMPQueueInfo ->
  ConnInfo ->
  m (SndQueue, SMPConfirmation)
newSndQueue_ a (Compatible (SMPQueueInfo _clientVersion smpServer senderId rcvE2ePubDhKey)) cInfo = do
  -- this function assumes clientVersion is compatible - it was tested before
  (senderKey, sndPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (e2ePubKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  let sndQueue =
        SndQueue
          { server = smpServer,
            sndId = senderId,
            sndPrivateKey,
            e2eDhSecret = C.dh' rcvE2ePubDhKey e2ePrivKey,
            status = New
          }
  pure (sndQueue, SMPConfirmation senderKey e2ePubKey cInfo)
