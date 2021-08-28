{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
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
    createConnection,
    joinConnection,
    acceptConnection,
    subscribeConnection,
    sendMessage,
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
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (MsgBody, SenderPublicKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..), runTransportServer)
import Simplex.Messaging.Util (bshow)
import System.Random (randomR)
import UnliftIO.Async (Async, async, race_)
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
runSMPAgentBlocking (ATransport t) started cfg@AgentConfig {tcpPort} = runReaderT (smpAgent t) =<< newSMPAgentEnv cfg
  where
    smpAgent :: forall c m'. (Transport c, MonadUnliftIO m', MonadReader Env m') => TProxy c -> m' ()
    smpAgent _ = runTransportServer started tcpPort $ \(h :: c) -> do
      liftIO $ putLn h "Welcome to SMP v0.3.2 agent"
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
createConnection :: AgentErrorMonad m => AgentClient -> m (ConnId, SMPQueueInfo)
createConnection c = withAgentClient c $ newConn c ""

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> SMPQueueInfo -> ConnInfo -> m ConnId
joinConnection c = withAgentClient c .: joinConn c ""

-- | Approve confirmation (LET command)
acceptConnection :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
acceptConnection c = withAgentClient c .:. acceptConnection' c

-- | Subscribe to receive connection messages (SUB command)
subscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
subscribeConnection c = withAgentClient c . subscribeConnection' c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgBody -> m AgentMsgId
sendMessage c = withAgentClient c .: sendMessage' c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
suspendConnection c = withAgentClient c . suspendConnection' c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c = withAgentClient c . deleteConnection' c

withAgentClient :: AgentErrorMonad m => AgentClient -> ReaderT Env m a -> m a
withAgentClient c = withAgentLock c . (`runReaderT` agentEnv c)

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
      e -> INTERNAL $ show e

-- | execute any SMP agent command
processCommand :: forall m. AgentMonad m => AgentClient -> (ConnId, ACommand 'Client) -> m (ConnId, ACommand 'Agent)
processCommand c (connId, cmd) = case cmd of
  NEW -> second INV <$> newConn c connId
  JOIN smpQueueInfo connInfo -> (,OK) <$> joinConn c connId smpQueueInfo connInfo
  ACPT confId ownConnInfo -> acceptConnection' c connId confId ownConnInfo $> (connId, OK)
  SUB -> subscribeConnection' c connId $> (connId, OK)
  SEND msgBody -> (connId,) . MID <$> sendMessage' c connId msgBody
  OFF -> suspendConnection' c connId $> (connId, OK)
  DEL -> deleteConnection' c connId $> (connId, OK)

newConn :: AgentMonad m => AgentClient -> ConnId -> m (ConnId, SMPQueueInfo)
newConn c connId = do
  srv <- getSMPServer
  (rq, qInfo) <- newRcvQueue c srv
  g <- asks idsDrg
  let cData = ConnData {connId}
  connId' <- withStore $ \st -> createRcvConn st g cData rq
  addSubscription c rq connId'
  pure (connId', qInfo)

joinConn :: AgentMonad m => AgentClient -> ConnId -> SMPQueueInfo -> ConnInfo -> m ConnId
joinConn c connId qInfo cInfo = do
  (sq, senderKey, verifyKey) <- newSndQueue qInfo
  g <- asks idsDrg
  cfg <- asks config
  let cData = ConnData {connId}
  connId' <- withStore $ \st -> createSndConn st g cData sq
  confirmQueue c sq senderKey cInfo
  activateQueueJoining c connId' sq verifyKey $ retryInterval cfg
  pure connId'

activateQueueJoining :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> VerificationKey -> RetryInterval -> m ()
activateQueueJoining c connId sq verifyKey retryInterval =
  activateQueue c connId sq verifyKey retryInterval createReplyQueue
  where
    createReplyQueue :: m ()
    createReplyQueue = do
      srv <- getSMPServer
      (rq, qInfo') <- newRcvQueue c srv
      addSubscription c rq connId
      withStore $ \st -> upgradeSndConnToDuplex st connId rq
      sendControlMessage c sq $ REPLY qInfo'

-- | Approve confirmation (LET command) in Reader monad
acceptConnection' :: AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
acceptConnection' c connId confId ownConnInfo =
  withStore (`getConn` connId) >>= \case
    SomeConn SCRcv (RcvConnection _ rq) -> do
      AcceptedConfirmation {senderKey} <- withStore $ \st -> acceptConfirmation st confId ownConnInfo
      processConfirmation c rq senderKey
    _ -> throwError $ CMD PROHIBITED

processConfirmation :: AgentMonad m => AgentClient -> RcvQueue -> SenderPublicKey -> m ()
processConfirmation c rq sndKey = do
  withStore $ \st -> setRcvQueueStatus st rq Confirmed
  secureQueue c rq sndKey
  withStore $ \st -> setRcvQueueStatus st rq Secured

-- | Subscribe to receive connection messages (SUB command) in Reader monad
subscribeConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
subscribeConnection' c connId =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rq sq) -> do
      resumeDelivery sq
      case status (sq :: SndQueue) of
        Confirmed -> withVerifyKey sq $ \verifyKey -> do
          conf <- withStore (`getAcceptedConfirmation` connId)
          secureQueue c rq $ senderKey (conf :: AcceptedConfirmation)
          withStore $ \st -> setRcvQueueStatus st rq Secured
          activateSecuredQueue rq sq verifyKey
        Secured -> withVerifyKey sq $ activateSecuredQueue rq sq
        Active -> subscribeQueue c rq connId
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (SndConnection _ sq) -> do
      resumeDelivery sq
      case status (sq :: SndQueue) of
        Confirmed -> withVerifyKey sq $ \verifyKey ->
          activateQueueJoining c connId sq verifyKey =<< resumeInterval
        Active -> throwError $ CONN SIMPLEX
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (RcvConnection _ rq) -> subscribeQueue c rq connId
  where
    resumeDelivery :: SndQueue -> m ()
    resumeDelivery SndQueue {server} = do
      wasDelivering <- resumeMsgDelivery c connId server
      unless wasDelivering $ do
        pending <- withStore (`getPendingMsgs` connId)
        queuePendingMsgs c connId pending
    withVerifyKey :: SndQueue -> (C.PublicKey -> m ()) -> m ()
    withVerifyKey sq action =
      let err = throwError $ INTERNAL "missing signing key public counterpart"
       in maybe err action . C.publicKey $ signKey sq
    activateSecuredQueue :: RcvQueue -> SndQueue -> C.PublicKey -> m ()
    activateSecuredQueue rq sq verifyKey = do
      activateQueueInitiating c connId sq verifyKey =<< resumeInterval
      subscribeQueue c rq connId
    resumeInterval :: m RetryInterval
    resumeInterval = do
      r <- asks $ retryInterval . config
      pure r {initialInterval = 5_000_000}

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgBody -> m AgentMsgId
sendMessage' c connId msg =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ _ sq) -> enqueueMessage sq
    SomeConn _ (SndConnection _ sq) -> enqueueMessage sq
    _ -> throwError $ CONN SIMPLEX
  where
    enqueueMessage :: SndQueue -> m AgentMsgId
    enqueueMessage SndQueue {server} = do
      msgId <- storeSentMsg
      wasDelivering <- resumeMsgDelivery c connId server
      pending <-
        if wasDelivering
          then pure [PendingMsg {connId, msgId}]
          else withStore (`getPendingMsgs` connId)
      queuePendingMsgs c connId pending
      pure $ unId msgId
      where
        storeSentMsg :: m InternalId
        storeSentMsg = do
          internalTs <- liftIO getCurrentTime
          withStore $ \st -> do
            (internalId, internalSndId, previousMsgHash) <- updateSndIds st connId
            let msgBody =
                  serializeSMPMessage
                    SMPMessage
                      { senderMsgId = unSndId internalSndId,
                        senderTimestamp = internalTs,
                        previousMsgHash,
                        agentMessage = A_MSG msg
                      }
                internalHash = C.sha256Hash msgBody
                msgData = SndMsgData {..}
            createSndMsg st connId msgData
            pure internalId

resumeMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnId -> SMPServer -> m Bool
resumeMsgDelivery c connId srv = do
  void $ resume srv (srvMsgDeliveries c) $ runSrvMsgDelivery c srv
  resume connId (connMsgDeliveries c) $ runMsgDelivery c connId srv
  where
    resume :: Ord a => a -> TVar (Map a (Async ())) -> m () -> m Bool
    resume key actionMap actionProcess = do
      isDelivering <- isJust . M.lookup key <$> readTVarIO actionMap
      unless isDelivering $
        async actionProcess
          >>= atomically . modifyTVar actionMap . M.insert key
      pure isDelivering

queuePendingMsgs :: AgentMonad m => AgentClient -> ConnId -> [PendingMsg] -> m ()
queuePendingMsgs c connId pending =
  atomically $ getPendingMsgQ connId (connMsgQueues c) >>= forM_ pending . writeTQueue

getPendingMsgQ :: Ord a => a -> TVar (Map a (TQueue PendingMsg)) -> STM (TQueue PendingMsg)
getPendingMsgQ key queueMap = do
  maybe newMsgQueue pure . M.lookup key =<< readTVar queueMap
  where
    newMsgQueue :: STM (TQueue PendingMsg)
    newMsgQueue = do
      mq <- newTQueue
      modifyTVar queueMap $ M.insert key mq
      pure mq

runMsgDelivery :: AgentMonad m => AgentClient -> ConnId -> SMPServer -> m ()
runMsgDelivery c connId srv = do
  mq <- atomically . getPendingMsgQ connId $ connMsgQueues c
  smq <- atomically . getPendingMsgQ srv $ srvMsgQueues c
  forever . atomically $ readTQueue mq >>= writeTQueue smq

runSrvMsgDelivery :: forall m. AgentMonad m => AgentClient -> SMPServer -> m ()
runSrvMsgDelivery c@AgentClient {subQ} srv = do
  mq <- atomically . getPendingMsgQ srv $ srvMsgQueues c
  ri <- asks $ reconnectInterval . config
  forever $ do
    PendingMsg {connId, msgId} <- atomically $ readTQueue mq
    let mId = unId msgId
    withStore (\st -> E.try $ getPendingMsgData st connId msgId) >>= \case
      Left (e :: E.SomeException) ->
        notify connId $ MERR mId (INTERNAL $ show e)
      Right (sq, msgBody) -> do
        withRetryInterval ri $ \loop -> do
          tryAction (sendAgentMessage c sq msgBody) >>= \case
            Left e -> case e of
              SMP SMP.QUOTA -> loop
              SMP {} -> notify connId $ MERR mId e
              CMD {} -> notify connId $ MERR mId e
              _ -> loop
            Right () -> do
              notify connId $ SENT mId
              withStore $ \st -> updateSndMsgStatus st connId msgId SndMsgSent
  where
    tryAction action = (Right <$> action) `catchError` (pure . Left)
    notify :: ConnId -> ACommand 'Agent -> m ()
    notify connId cmd = atomically $ writeTBQueue subQ ("", connId, cmd)

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
    _ -> withStore (`deleteConn` connId)
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

sendControlMessage :: AgentMonad m => AgentClient -> SndQueue -> AMessage -> m ()
sendControlMessage c sq agentMessage = do
  senderTimestamp <- liftIO getCurrentTime
  sendAgentMessage c sq . serializeSMPMessage $
    SMPMessage
      { senderMsgId = 0,
        senderTimestamp,
        previousMsgHash = "",
        agentMessage
      }

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
    _ -> atomically $ writeTBQueue subQ ("", "", ERR $ CONN NOT_FOUND)
  where
    processSMP :: SConnType c -> ConnData -> RcvQueue -> m ()
    processSMP cType ConnData {connId} rq@RcvQueue {status} =
      case cmd of
        SMP.MSG srvMsgId srvTs msgBody -> do
          -- TODO deduplicate with previously received
          msg <- decryptAndVerify rq msgBody
          let msgHash = C.sha256Hash msg
          case parseSMPMessage msg of
            Left e -> notify $ ERR e
            Right (SMPConfirmation senderKey cInfo) -> smpConfirmation senderKey cInfo
            Right SMPMessage {agentMessage, senderMsgId, senderTimestamp, previousMsgHash} ->
              case agentMessage of
                HELLO verifyKey _ -> helloMsg verifyKey msgBody
                REPLY qInfo -> replyMsg qInfo
                A_MSG body -> agentClientMsg previousMsgHash (senderMsgId, senderTimestamp) (srvMsgId, srvTs) body msgHash
          sendAck c rq
          return ()
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

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        smpConfirmation :: SenderPublicKey -> ConnInfo -> m ()
        smpConfirmation senderKey cInfo = do
          logServer "<--" c srv rId "MSG <KEY>"
          case status of
            New -> case cType of
              SCRcv -> do
                g <- asks idsDrg
                let newConfirmation = NewConfirmation {connId, senderKey, senderConnInfo = cInfo}
                confId <- withStore $ \st -> createConfirmation st g newConfirmation
                notify $ REQ confId cInfo
              SCDuplex -> do
                notify $ INFO cInfo
                processConfirmation c rq senderKey
              _ -> prohibited
            _ -> prohibited

        helloMsg :: SenderPublicKey -> ByteString -> m ()
        helloMsg verifyKey msgBody = do
          logServer "<--" c srv rId "MSG <HELLO>"
          case status of
            Active -> prohibited
            _ -> do
              void $ verifyMessage (Just verifyKey) msgBody
              withStore $ \st -> setRcvQueueActive st rq verifyKey
              case cType of
                SCDuplex -> notifyConnected c connId
                _ -> pure ()

        replyMsg :: SMPQueueInfo -> m ()
        replyMsg qInfo = do
          logServer "<--" c srv rId "MSG <REPLY>"
          case cType of
            SCRcv -> do
              AcceptedConfirmation {ownConnInfo} <- withStore (`getAcceptedConfirmation` connId)
              (sq, senderKey, verifyKey) <- newSndQueue qInfo
              withStore $ \st -> upgradeRcvConnToDuplex st connId sq
              confirmQueue c sq senderKey ownConnInfo
              withStore (`removeConfirmations` connId)
              cfg <- asks config
              activateQueueInitiating c connId sq verifyKey $ retryInterval cfg
            _ -> prohibited

        agentClientMsg :: PrevRcvMsgHash -> (ExternalSndId, ExternalSndTs) -> (BrokerId, BrokerTs) -> MsgBody -> MsgHash -> m ()
        agentClientMsg externalPrevSndHash sender broker msgBody internalHash = do
          logServer "<--" c srv rId "MSG <MSG>"
          internalTs <- liftIO getCurrentTime
          (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- withStore (`updateRcvIds` connId)
          let integrity = checkMsgIntegrity prevExtSndId (fst sender) prevRcvMsgHash externalPrevSndHash
              recipient = (unId internalId, internalTs)
              msgMeta = MsgMeta {integrity, recipient, sender, broker}
              rcvMsg = RcvMsgData {..}
          withStore $ \st -> createRcvMsg st connId rcvMsg
          notify $ MSG msgMeta msgBody

        checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
        checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
          | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
          | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
          | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
          | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
          | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
          | otherwise = MsgError MsgDuplicate -- this case is not possible

confirmQueue :: AgentMonad m => AgentClient -> SndQueue -> SenderPublicKey -> ConnInfo -> m ()
confirmQueue c sq senderKey cInfo = do
  sendConfirmation c sq senderKey cInfo
  withStore $ \st -> setSndQueueStatus st sq Confirmed

activateQueueInitiating :: AgentMonad m => AgentClient -> ConnId -> SndQueue -> VerificationKey -> RetryInterval -> m ()
activateQueueInitiating c connId sq verifyKey retryInterval =
  activateQueue c connId sq verifyKey retryInterval $ notifyConnected c connId

activateQueue :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> VerificationKey -> RetryInterval -> m () -> m ()
activateQueue c connId sq verifyKey retryInterval afterActivation =
  getActivation c connId >>= \case
    Nothing -> async runActivation >>= addActivation c connId
    Just _ -> pure ()
  where
    runActivation :: m ()
    runActivation = do
      sendHello c sq verifyKey retryInterval
      withStore $ \st -> setSndQueueStatus st sq Active
      removeActivation c connId
      removeVerificationKey
      afterActivation
    removeVerificationKey :: m ()
    removeVerificationKey =
      let safeSignKey = C.removePublicKey $ signKey sq
       in withStore $ \st -> updateSignKey st sq safeSignKey

notifyConnected :: AgentMonad m => AgentClient -> ConnId -> m ()
notifyConnected c connId = atomically $ writeTBQueue (subQ c) ("", connId, CON)

newSndQueue ::
  (MonadUnliftIO m, MonadReader Env m) => SMPQueueInfo -> m (SndQueue, SenderPublicKey, VerificationKey)
newSndQueue (SMPQueueInfo smpServer senderId encryptKey) = do
  size <- asks $ rsaKeySize . config
  (senderKey, sndPrivateKey) <- liftIO $ C.generateKeyPair size
  (verifyKey, signKey) <- liftIO $ C.generateKeyPair size
  let sndQueue =
        SndQueue
          { server = smpServer,
            sndId = senderId,
            sndPrivateKey,
            encryptKey,
            signKey,
            status = New
          }
  return (sndQueue, senderKey, verifyKey)
