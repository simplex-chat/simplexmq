{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
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
  ( -- * queue-based SMP agent
    getAgentClient,
    runAgentClient,

    -- * SMP agent functional API
    AgentClient (..),
    AgentMonad,
    AgentErrorMonad,
    getSMPAgentClient,
    disconnectAgentClient,
    resumeAgentClient,
    withAgentLock,
    createConnection,
    joinConnection,
    allowConnection,
    acceptContact,
    rejectContact,
    subscribeConnection,
    resubscribeConnection,
    sendMessage,
    ackMessage,
    suspendConnection,
    deleteConnection,
    setSMPServers,
    setNtfServers,
    registerNtfToken,
    verifyNtfToken,
    enableNtfCron,
    checkNtfToken,
    deleteNtfToken,
    logConnection,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple (logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Char8 (ByteString)
import Data.Composition ((.:), (.:.))
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.System (systemToUTCTime)
import Data.Word (Word16)
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Monad (AgentMonad)
import Simplex.Messaging.Agent.NtfSubSupervisor
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Client (ProtocolClient (..), ServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Client
import Simplex.Messaging.Notifications.Protocol (DeviceToken, NtfRegCode (NtfRegCode), NtfTknStatus (..))
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol (BrokerMsg, ErrorType (AUTH), MsgBody, MsgFlags, ProtocolServer)
import qualified Simplex.Messaging.Protocol as SMP
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (bshow, liftError, tryError, unlessM, ($>>=))
import Simplex.Messaging.Version
import System.Random (randomR)
import UnliftIO.Async (async, race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> InitialAgentServers -> m AgentClient
getSMPAgentClient cfg initServers = newSMPAgentEnv cfg >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient initServers
      action <- async $ subscriber c `E.finally` disconnectAgentClient c
      pure c {smpSubscriber = action}

disconnectAgentClient :: MonadUnliftIO m => AgentClient -> m ()
disconnectAgentClient c = closeAgentClient c >> logConnection c False

resumeAgentClient :: MonadIO m => AgentClient -> m ()
resumeAgentClient c = atomically $ writeTVar (active c) True

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

resubscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection c = withAgentEnv c . resubscribeConnection' c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage c = withAgentEnv c .:. sendMessage' c

ackMessage :: AgentErrorMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage c = withAgentEnv c .: ackMessage' c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
suspendConnection c = withAgentEnv c . suspendConnection' c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c = withAgentEnv c . deleteConnection' c

-- | Change servers to be used for creating new queues
setSMPServers :: AgentErrorMonad m => AgentClient -> NonEmpty SMPServer -> m ()
setSMPServers c = withAgentEnv c . setSMPServers' c

setNtfServers :: AgentErrorMonad m => AgentClient -> [NtfServer] -> m ()
setNtfServers c = withAgentEnv c . setNtfServers' c

-- | Register device notifications token
registerNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
registerNtfToken c = withAgentEnv c . registerNtfToken' c

-- | Verify device notifications token
verifyNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> ByteString -> C.CbNonce -> m ()
verifyNtfToken c = withAgentEnv c .:. verifyNtfToken' c

-- | Enable/disable periodic notifications
enableNtfCron :: AgentErrorMonad m => AgentClient -> DeviceToken -> Word16 -> m ()
enableNtfCron c = withAgentEnv c .: enableNtfCron' c

checkNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken c = withAgentEnv c . checkNtfToken' c

deleteNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken c = withAgentEnv c . deleteNtfToken' c

withAgentEnv :: AgentClient -> ReaderT Env m a -> m a
withAgentEnv c = (`runReaderT` agentEnv c)

-- withAgentClient :: AgentErrorMonad m => AgentClient -> ReaderT Env m a -> m a
-- withAgentClient c = withAgentLock c . withAgentEnv c

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
getAgentClient :: (MonadUnliftIO m, MonadReader Env m) => InitialAgentServers -> m AgentClient
getAgentClient initServers = ask >>= atomically . newAgentClient initServers

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runAgentClient c = race_ (subscriber c) (client c)

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
  NEW (ACM cMode) -> second (INV . ACR cMode) <$> newConn c connId cMode
  JOIN (ACR _ cReq) connInfo -> (,OK) <$> joinConn c connId cReq connInfo
  LET confId ownCInfo -> allowConnection' c connId confId ownCInfo $> (connId, OK)
  ACPT invId ownCInfo -> (,OK) <$> acceptContact' c connId invId ownCInfo
  RJCT invId -> rejectContact' c connId invId $> (connId, OK)
  SUB -> subscribeConnection' c connId $> (connId, OK)
  SEND msgFlags msgBody -> (connId,) . MID <$> sendMessage' c connId msgFlags msgBody
  ACK msgId -> ackMessage' c connId msgId $> (connId, OK)
  OFF -> suspendConnection' c connId $> (connId, OK)
  DEL -> deleteConnection' c connId $> (connId, OK)

newConn :: AgentMonad m => AgentClient -> ConnId -> SConnectionMode c -> m (ConnId, ConnectionRequestUri c)
newConn c connId cMode = do
  srv <- getSMPServer c
  (rq, qUri) <- newRcvQueue c srv
  g <- asks idsDrg
  let cData = ConnData {connId}
  connId' <- withStore $ \st -> createRcvConn st g cData rq cMode
  addSubscription c rq connId'
  -- atomically $ addRcvQueueToNtfSubQueue ns rq
  let crData = ConnReqUriData simplexChat smpAgentVRange [qUri]
  case cMode of
    SCMContact -> pure (connId', CRContactUri crData)
    SCMInvitation -> do
      (pk1, pk2, e2eRcvParams) <- liftIO $ CR.generateE2EParams CR.e2eEncryptVersion
      withStore $ \st -> createRatchetX3dhKeys st connId' pk1 pk2
      pure (connId', CRInvitationUri crData $ toVersionRangeT e2eRcvParams CR.e2eEncryptVRange)

joinConn :: AgentMonad m => AgentClient -> ConnId -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConn c connId (CRInvitationUri (ConnReqUriData _ agentVRange (qUri :| _)) e2eRcvParamsUri) cInfo =
  case ( qUri `compatibleVersion` SMP.smpClientVRange,
         e2eRcvParamsUri `compatibleVersion` CR.e2eEncryptVRange,
         agentVRange `compatibleVersion` smpAgentVRange
       ) of
    (Just qInfo, Just (Compatible e2eRcvParams@(CR.E2ERatchetParams _ _ rcDHRr)), Just _) -> do
      -- TODO in agent v2 - use found compatible version rather than current
      (pk1, pk2, e2eSndParams) <- liftIO . CR.generateE2EParams $ version e2eRcvParams
      (_, rcDHRs) <- liftIO C.generateKeyPair'
      let rc = CR.initSndRatchet rcDHRr rcDHRs $ CR.x3dhSnd pk1 pk2 e2eRcvParams
      sq <- newSndQueue qInfo
      g <- asks idsDrg
      let cData = ConnData {connId}
      connId' <- withStore $ \st -> do
        connId' <- createSndConn st g cData sq
        createRatchet st connId' rc
        pure connId'
      tryError (confirmQueue c connId' sq cInfo $ Just e2eSndParams) >>= \case
        Right _ -> do
          void $ enqueueMessage c connId' sq SMP.noMsgFlags HELLO
          pure connId'
        Left e -> do
          -- TODO recovery for failure on network timeout, see rfcs/2022-04-20-smp-conf-timeout-recovery.md
          withStore (`deleteConn` connId')
          throwError e
    _ -> throwError $ AGENT A_VERSION
joinConn c connId (CRContactUri (ConnReqUriData _ agentVRange (qUri :| _))) cInfo =
  case ( qUri `compatibleVersion` SMP.smpClientVRange,
         agentVRange `compatibleVersion` smpAgentVRange
       ) of
    (Just qInfo, Just _) -> do
      -- TODO in agent v2 - use found compatible version rather than current
      (connId', cReq) <- newConn c connId SCMInvitation
      sendInvitation c qInfo cReq cInfo
      pure connId'
    _ -> throwError $ AGENT A_VERSION

createReplyQueue :: AgentMonad m => AgentClient -> ConnId -> SndQueue -> m ()
createReplyQueue c connId sq = do
  srv <- getSMPServer c
  (rq, qUri) <- newRcvQueue c srv
  -- TODO reply queue version should be the same as send queue, ignoring it in v1
  let qInfo = toVersionT qUri SMP.smpClientVersion
  addSubscription c rq connId
  withStore $ \st -> upgradeSndConnToDuplex st connId rq
  void . enqueueMessage c connId sq SMP.noMsgFlags $ REPLY [qInfo]

-- | Approve confirmation (LET command) in Reader monad
allowConnection' :: AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection' c connId confId ownConnInfo = do
  withStore (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection _ rq) -> do
      AcceptedConfirmation {senderConf, ratchetState} <- withStore $ \st -> acceptConfirmation st confId ownConnInfo
      withStore $ \st -> createRatchet st connId ratchetState
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
    SomeConn _ (SndConnection _ sq) -> do
      resumeMsgDelivery c connId sq
      case status (sq :: SndQueue) of
        Confirmed -> pure ()
        Active -> throwError $ CONN SIMPLEX
        _ -> throwError $ INTERNAL "unexpected queue status"
    SomeConn _ (RcvConnection _ rq) -> subscribeQueue c rq connId
    SomeConn _ (ContactConnection _ rq) -> subscribeQueue c rq connId

resubscribeConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection' c connId =
  unlessM
    (atomically $ hasActiveSubscription c connId)
    (subscribeConnection' c connId)

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage' c connId msgFlags msg =
  withStore (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ _ sq) -> enqueueMsg sq
    SomeConn _ (SndConnection _ sq) -> enqueueMsg sq
    _ -> throwError $ CONN SIMPLEX
  where
    enqueueMsg :: SndQueue -> m AgentMsgId
    enqueueMsg sq = enqueueMessage c connId sq msgFlags $ A_MSG msg

enqueueMessage :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> MsgFlags -> AMessage -> m AgentMsgId
enqueueMessage c connId sq msgFlags aMessage = do
  resumeMsgDelivery c connId sq
  msgId <- storeSentMsg
  queuePendingMsgs c connId sq [msgId]
  pure $ unId msgId
  where
    storeSentMsg :: m InternalId
    storeSentMsg = do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- withStore (`updateSndIds` connId)
      let privHeader = APrivHeader (unSndId internalSndId) prevMsgHash
          agentMsg = AgentMessage privHeader aMessage
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encAgentMessage <- agentRatchetEncrypt connId agentMsgStr e2eEncUserMsgLength
      let msgBody = smpEncode $ AgentMsgEnvelope {agentVersion = smpAgentVersion, encAgentMessage}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgFlags, msgBody, internalHash, prevMsgHash}
      withStore $ \st -> createSndMsg st connId msgData
      pure internalId

resumeMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> m ()
resumeMsgDelivery c connId sq@SndQueue {server, sndId} = do
  let qKey = (connId, server, sndId)
  unlessM (queueDelivering qKey) $
    async (runSmpQueueMsgDelivery c connId sq)
      >>= \a -> atomically (TM.insert qKey a $ smpQueueMsgDeliveries c)
  unlessM connQueued $
    withStore (`getPendingMsgs` connId)
      >>= queuePendingMsgs c connId sq
  where
    queueDelivering qKey = atomically $ TM.member qKey (smpQueueMsgDeliveries c)
    connQueued = atomically $ isJust <$> TM.lookupInsert connId True (connMsgsQueued c)

queuePendingMsgs :: AgentMonad m => AgentClient -> ConnId -> SndQueue -> [InternalId] -> m ()
queuePendingMsgs c connId sq msgIds = atomically $ do
  q <- getPendingMsgQ c connId sq
  mapM_ (writeTQueue q) msgIds

getPendingMsgQ :: AgentClient -> ConnId -> SndQueue -> STM (TQueue InternalId)
getPendingMsgQ c connId SndQueue {server, sndId} = do
  let qKey = (connId, server, sndId)
  maybe (newMsgQueue qKey) pure =<< TM.lookup qKey (smpQueueMsgQueues c)
  where
    newMsgQueue qKey = do
      mq <- newTQueue
      TM.insert qKey mq $ smpQueueMsgQueues c
      pure mq

runSmpQueueMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> m ()
runSmpQueueMsgDelivery c@AgentClient {subQ} connId sq = do
  mq <- atomically $ getPendingMsgQ c connId sq
  ri <- asks $ reconnectInterval . config
  forever $ do
    msgId <- atomically $ readTQueue mq
    let mId = unId msgId
    withStore (\st -> E.try $ getPendingMsgData st connId msgId) >>= \case
      Left (e :: E.SomeException) ->
        notify $ MERR mId (INTERNAL $ show e)
      Right (rq_, PendingMsgData {msgType, msgBody, msgFlags, internalTs}) ->
        withRetryInterval ri $ \loop -> do
          resp <- tryError $ case msgType of
            AM_CONN_INFO -> sendConfirmation c sq msgBody
            _ -> sendAgentMessage c sq msgFlags msgBody
          case resp of
            Left e -> do
              let err = if msgType == AM_CONN_INFO then ERR e else MERR mId e
              case e of
                SMP SMP.QUOTA -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  _ -> loop
                SMP SMP.AUTH -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_HELLO_ -> do
                    helloTimeout <- asks $ helloTimeout . config
                    currentTime <- liftIO getCurrentTime
                    if diffUTCTime currentTime internalTs > helloTimeout
                      then case rq_ of
                        -- party initiating connection
                        Just _ -> connError msgId NOT_AVAILABLE
                        -- party joining connection
                        _ -> connError msgId NOT_ACCEPTED
                      else loop
                  AM_REPLY_ -> notifyDel msgId $ ERR e
                  AM_A_MSG_ -> notifyDel msgId $ MERR mId e
                SMP (SMP.CMD _) -> notifyDel msgId err
                SMP SMP.LARGE_MSG -> notifyDel msgId err
                SMP {} -> notify err >> loop
                _ -> loop
            Right () -> do
              case msgType of
                AM_CONN_INFO -> do
                  withStore $ \st -> setSndQueueStatus st sq Confirmed
                  when (isJust rq_) $ withStore (`removeConfirmations` connId)
                  -- TODO possibly notification flag should be ON for one of the parties, to result in contact connected notification
                  void $ enqueueMessage c connId sq SMP.noMsgFlags HELLO
                AM_HELLO_ -> do
                  withStore $ \st -> setSndQueueStatus st sq Active
                  case rq_ of
                    -- party initiating connection
                    Just rq -> do
                      subscribeQueue c rq connId
                      notify CON
                    -- party joining connection
                    _ -> createReplyQueue c connId sq
                AM_A_MSG_ -> notify $ SENT mId
                _ -> pure ()
              delMsg msgId
  where
    delMsg :: InternalId -> m ()
    delMsg msgId = withStore $ \st -> deleteMsg st connId msgId
    notify :: ACommand 'Agent -> m ()
    notify cmd = atomically $ writeTBQueue subQ ("", connId, cmd)
    notifyDel :: InternalId -> ACommand 'Agent -> m ()
    notifyDel msgId cmd = notify cmd >> delMsg msgId
    connError msgId = notifyDel msgId . ERR . CONN

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
      srvMsgId <- withStore $ \st -> checkRcvMsg st connId mId
      sendAck c rq srvMsgId
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
      atomically $ removeSubscription c connId
      withStore (`deleteConn` connId)

-- | Change servers to be used for creating new queues, in Reader monad
setSMPServers' :: AgentMonad m => AgentClient -> NonEmpty SMPServer -> m ()
setSMPServers' c servers = do
  atomically $ writeTVar (smpServers c) servers

registerNtfToken' :: forall m. AgentMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
registerNtfToken' c@AgentClient {ntfSubSupervisor = ns} deviceToken =
  withStore (`getDeviceNtfToken` deviceToken) >>= \case
    (Just tkn@NtfToken {ntfTokenId, ntfTknStatus, ntfTknAction}, prevTokens) -> do
      mapM_ (deleteToken_ c) prevTokens
      case (ntfTokenId, ntfTknAction) of
        (Nothing, Just NTARegister) -> registerToken tkn $> NTRegistered
        -- TODO minimal time before repeat registration
        (Just _, Nothing) -> when (ntfTknStatus == NTRegistered) (registerToken tkn) $> NTRegistered
        (Just tknId, Just (NTAVerify code)) ->
          t tkn (NTActive, Just NTACheck) $ agentNtfVerifyToken c tknId tkn code
        (Just tknId, Just (NTACron interval)) ->
          t tkn (cronSuccess interval) $ agentNtfEnableCron c tknId tkn interval
        (Just _tknId, Just NTACheck) -> do
          when (ntfTknStatus == NTActive) $
            runNotificationSubSupervisor c tkn
          pure ntfTknStatus -- TODO
          -- agentNtfCheckToken c tknId tkn >>= \case
        (Just tknId, Just NTADelete) -> do
          agentNtfDeleteToken c tknId tkn
          withStore $ \st -> removeNtfToken st tkn
          nsRemoveNtfToken ns
          pure NTExpired
        _ -> pure ntfTknStatus
    _ ->
      getNtfServer c >>= \case
        Just ntfServer ->
          asks (cmdSignAlg . config) >>= \case
            C.SignAlg a -> do
              tknKeys <- liftIO $ C.generateSignatureKeyPair a
              dhKeys <- liftIO C.generateKeyPair'
              let tkn = newNtfToken deviceToken ntfServer tknKeys dhKeys
              withStore $ \st -> createNtfToken st tkn
              registerToken tkn
              pure NTRegistered
        _ -> throwError $ CMD PROHIBITED
  where
    t tkn = withToken c tkn Nothing
    registerToken :: NtfToken -> m ()
    registerToken tkn@NtfToken {ntfPubKey, ntfDhKeys = (pubDhKey, privDhKey)} = do
      (tknId, srvPubDhKey) <- agentNtfRegisterToken c tkn ntfPubKey pubDhKey
      let dhSecret = C.dh' srvPubDhKey privDhKey
      withStore $ \st -> updateNtfTokenRegistration st tkn tknId dhSecret
      nsUpdateNtfToken ns tkn

-- TODO decrypt verification code
verifyNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> ByteString -> C.CbNonce -> m ()
verifyNtfToken' c deviceToken code nonce =
  withStore (`getDeviceNtfToken` deviceToken) >>= \case
    (Just tkn@NtfToken {ntfTokenId = Just tknId, ntfDhSecret = Just dhSecret}, _) -> do
      code' <- liftEither . bimap cryptoError NtfRegCode $ C.cbDecrypt dhSecret nonce code
      void . withToken c tkn (Just (NTConfirmed, NTAVerify code')) (NTActive, Just NTACheck) $ do
        agentNtfVerifyToken c tknId tkn code'
        runNotificationSubSupervisor c tkn
    _ -> throwError $ CMD PROHIBITED

enableNtfCron' :: AgentMonad m => AgentClient -> DeviceToken -> Word16 -> m ()
enableNtfCron' c deviceToken interval = do
  when (interval < 20) . throwError $ CMD PROHIBITED
  withStore (`getDeviceNtfToken` deviceToken) >>= \case
    (Just tkn@NtfToken {ntfTokenId = Just tknId, ntfTknStatus = NTActive}, _) ->
      void . withToken c tkn (Just (NTActive, NTACron interval)) (cronSuccess interval) $
        agentNtfEnableCron c tknId tkn interval
    _ -> throwError $ CMD PROHIBITED

cronSuccess :: Word16 -> (NtfTknStatus, Maybe NtfTknAction)
cronSuccess interval
  | interval == 0 = (NTActive, Just NTACheck)
  | otherwise = (NTActive, Just $ NTACron interval)

checkNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken' c deviceToken =
  withStore (`getDeviceNtfToken` deviceToken) >>= \case
    (Just tkn@NtfToken {ntfTokenId = Just tknId}, _) -> agentNtfCheckToken c tknId tkn
    _ -> throwError $ CMD PROHIBITED

deleteNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken' c deviceToken =
  withStore (`getDeviceNtfToken` deviceToken) >>= \case
    (Just tkn, _) -> deleteToken_ c tkn
    _ -> throwError $ CMD PROHIBITED

deleteToken_ :: AgentMonad m => AgentClient -> NtfToken -> m ()
deleteToken_ c@AgentClient {ntfSubSupervisor = ns} tkn@NtfToken {ntfTokenId, ntfTknStatus} = do
  forM_ ntfTokenId $ \tknId -> do
    let ntfTknAction = Just NTADelete
    withStore $ \st -> updateNtfToken st tkn ntfTknStatus ntfTknAction
    nsUpdateNtfToken ns tkn {ntfTknStatus, ntfTknAction = ntfTknAction}
    agentNtfDeleteToken c tknId tkn `catchError` \case
      NTF AUTH -> pure ()
      e -> throwError e
  withStore $ \st -> removeNtfToken st tkn
  nsRemoveNtfToken ns

withToken :: AgentMonad m => AgentClient -> NtfToken -> Maybe (NtfTknStatus, NtfTknAction) -> (NtfTknStatus, Maybe NtfTknAction) -> m a -> m NtfTknStatus
withToken c@AgentClient {ntfSubSupervisor = ns} tkn@NtfToken {deviceToken} from_ (toStatus, toAction_) f = do
  forM_ from_ $ \(status, action) -> do
    withStore $ \st -> updateNtfToken st tkn status (Just action)
    nsUpdateNtfToken ns tkn {ntfTknStatus = status, ntfTknAction = Just action}
  tryError f >>= \case
    Right _ -> do
      withStore $ \st -> updateNtfToken st tkn toStatus toAction_
      nsUpdateNtfToken ns tkn {ntfTknStatus = toStatus, ntfTknAction = toAction_}
      pure toStatus
    Left e@(NTF AUTH) -> do
      withStore $ \st -> removeNtfToken st tkn
      nsRemoveNtfToken ns
      void $ registerNtfToken' c deviceToken
      throwError e
    Left e -> throwError e

setNtfServers' :: AgentMonad m => AgentClient -> [NtfServer] -> m ()
setNtfServers' c servers = do
  atomically $ writeTVar (ntfServers c) servers

getSMPServer :: AgentMonad m => AgentClient -> m SMPServer
getSMPServer c = do
  smpServers <- readTVarIO $ smpServers c
  case smpServers of
    srv :| [] -> pure srv
    servers -> do
      gen <- asks randomServer
      atomically . stateTVar gen $
        first (servers L.!!) . randomR (0, L.length servers - 1)

getNtfServer :: AgentMonad m => AgentClient -> m (Maybe NtfServer)
getNtfServer c = do
  ntfServers <- readTVarIO $ ntfServers c
  case ntfServers of
    [] -> pure Nothing
    [srv] -> pure $ Just srv
    servers -> do
      gen <- asks randomServer
      atomically . stateTVar gen $
        first (Just . (servers !!)) . randomR (0, length servers - 1)

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  t <- atomically $ readTBQueue msgQ
  withAgentLock c (runExceptT $ processSMPTransmission c t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

runNotificationSubSupervisor :: AgentMonad m => AgentClient -> NtfToken -> m ()
runNotificationSubSupervisor c@AgentClient {ntfSubSupervisor = ns} tkn = do
  addNtfSubSupervisor ns $ notificationSubSupervisor c tkn `E.finally` pure () -- TODO
  -- race condition? - notificationSubSupervisor may still be initializing workers when queue is already being written to
  -- initialize workers here before populating queue?
  -- check ntfSubLoopStarted in loop?
  -- TODO ! check by Maybe Async instead of flag
  -- TODO ! start in getSMPAgentClient in race, instead of on token verification / check
  -- TODO ! use subscriptions in Client (memory) to get subscriptions on ntf_register
  -- TODO ! when writing to queue on subscribe/create check by active token (token should live in Client)
  rcvQueues <- withStore $ \st -> getRcvQueuesWithoutNtfSub st
  forM_ rcvQueues $ \rq -> do
    atomically $ writeTBQueue (ntfSubQ ns) rq

-- TODO what to do on token change; should ntfToken be read from client env?
notificationSubSupervisor :: AgentMonad m => AgentClient -> NtfToken -> m ()
notificationSubSupervisor c@AgentClient {ntfSubSupervisor = ns@NtfSubSupervisor {ntfSubLoopStarted, ntfSubQ}} ntfToken = do
  -- get unique servers from ntf_subscriptions, add workers to ntfSubWorkers
  srvs <- withStore $ \st -> getNtfSubscriptionServers st
  forM_ srvs $ \srv -> addWorker srv
  atomically $ writeTVar ntfSubLoopStarted True
  forever $ do
    rcvQueue@RcvQueue {server = smpServer, rcvId} <- atomically $ readTBQueue ntfSubQ
    -- get/create subscription record in ntf_subscriptions
    sub_ <- withStore $ \st -> getNtfSubscription st rcvQueue
    -- TODO what if ntf server is not configured on start (ignore for now)
    ntfServer_ <- getNtfServer c
    case (sub_, ntfServer_) of
      (Nothing, Just ntfServer) -> do
        currentTime <- liftIO getCurrentTime
        let newSub = newNtfSubscription ntfServer ntfToken smpServer rcvId currentTime
        withStore $ \st -> createNtfSubscription st newSub
        -- lookup workers in ntfSubWorkers; create if it doesn't exist
        addWorker smpServer
        addWorker ntfServer
      (Just _, Just ntfServer) -> do
        atomically $ do
          setNtfSubWorkerSemaphore ns smpServer
          setNtfSubWorkerSemaphore ns ntfServer
      _ -> pure ()
    -- throttle
    liftIO $ threadDelay 1000000
  where
    addWorker srv = addNtfSubWorker ns srv $ \ws -> notificationSubWorker c srv ws `E.finally` pure () -- TODO

notificationSubWorker :: AgentMonad m => AgentClient -> ProtocolServer -> TMVar () -> m ()
notificationSubWorker _c srv workerSemaphore = forever $ do
  _ <- atomically $ readTMVar workerSemaphore
  -- get next action from ntf_subscriptions filtering by srv
  withStore $ \st ->
    getNextNtfSubscription st srv >>= \case
      Nothing -> void . atomically $ tryTakeTMVar workerSemaphore
      Just NtfSubscription {ntfSubAction} ->
        -- process action, updateNtfSubscription (new status, action, can be nId, subId)
        forM_ ntfSubAction $ \case
          NSAKey -> pure ()
          NSANew _nKey -> pure ()
          NSACheck -> pure ()
          NSADelete -> pure ()
  -- throttle
  liftIO $ threadDelay 2000000

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> ServerTransmission BrokerMsg -> m ()
processSMPTransmission c@AgentClient {smpClients, subQ} (srv, sessId, rId, cmd) = do
  withStore (\st -> getRcvConn st srv rId) >>= \case
    SomeConn SCDuplex (DuplexConnection cData rq _) -> processSMP SCDuplex cData rq
    SomeConn SCRcv (RcvConnection cData rq) -> processSMP SCRcv cData rq
    SomeConn SCContact (ContactConnection cData rq) -> processSMP SCContact cData rq
    _ -> atomically $ writeTBQueue subQ ("", "", ERR $ CONN NOT_FOUND)
  where
    processSMP :: SConnType c -> ConnData -> RcvQueue -> m ()
    processSMP cType ConnData {connId} rq@RcvQueue {rcvDhSecret, e2ePrivKey, e2eDhSecret, status} =
      case cmd of
        SMP.MSG srvMsgId srvTs msgFlags msgBody' -> handleNotifyAck $ do
          -- TODO deduplicate with previously received
          msgBody <- agentCbDecrypt rcvDhSecret (C.cbNonce srvMsgId) msgBody'
          clientMsg@SMP.ClientMsgEnvelope {cmHeader = SMP.PubHeader phVer e2ePubKey_} <-
            parseMessage msgBody
          unless (phVer `isCompatible` SMP.smpClientVRange) . throwError $ AGENT A_VERSION
          case (e2eDhSecret, e2ePubKey_) of
            (Nothing, Just e2ePubKey) -> do
              let e2eDh = C.dh' e2ePubKey e2ePrivKey
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHConfirmation senderKey, AgentConfirmation {e2eEncryption, encConnInfo}) ->
                  smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo >> ack
                (SMP.PHEmpty, AgentInvitation {connReq, connInfo}) ->
                  smpInvitation connReq connInfo >> ack
                _ -> prohibited >> ack
            (Just e2eDh, Nothing) -> do
              decryptClientMessage e2eDh clientMsg >>= \case
                (SMP.PHEmpty, AgentMsgEnvelope _ encAgentMsg) -> do
                  agentMsgBody <- agentRatchetDecrypt connId encAgentMsg
                  parseMessage agentMsgBody >>= \case
                    agentMsg@(AgentMessage APrivHeader {sndMsgId, prevMsgHash} aMessage) -> do
                      let msgType = agentMessageType agentMsg
                      (msgId, msgMeta) <- agentClientMsg prevMsgHash sndMsgId (srvMsgId, systemToUTCTime srvTs) msgFlags agentMsgBody msgType
                      case aMessage of
                        HELLO -> helloMsg >> ack >> withStore (\st -> deleteMsg st connId msgId)
                        REPLY cReq -> replyMsg cReq >> ack >> withStore (\st -> deleteMsg st connId msgId)
                        -- note that there is no ACK sent here, it is sent with agent's user ACK command
                        A_MSG body -> notify $ MSG msgMeta msgFlags body
                    _ -> prohibited >> ack
                _ -> prohibited >> ack
            _ -> prohibited >> ack
          where
            ack :: m ()
            ack = sendAck c rq srvMsgId
            handleNotifyAck :: m () -> m ()
            handleNotifyAck m = m `catchError` \e -> notify (ERR e) >> ack
        SMP.END ->
          atomically (TM.lookup srv smpClients $>>= tryReadTMVar >>= processEND)
            >>= logServer "<--" c srv rId
          where
            processEND = \case
              Just (Right clnt)
                | sessId == sessionId clnt -> do
                  removeSubscription c connId
                  writeTBQueue subQ ("", connId, END)
                  pure "END"
                | otherwise -> ignored
              _ -> ignored
            ignored = pure "END from disconnected client - ignored"
        _ -> do
          logServer "<--" c srv rId $ "unexpected: " <> bshow cmd
          notify . ERR $ BROKER UNEXPECTED
      where
        notify :: ACommand 'Agent -> m ()
        notify msg = atomically $ writeTBQueue subQ ("", connId, msg)

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        decryptClientMessage :: C.DhSecretX25519 -> SMP.ClientMsgEnvelope -> m (SMP.PrivHeader, AgentMsgEnvelope)
        decryptClientMessage e2eDh SMP.ClientMsgEnvelope {cmNonce, cmEncBody} = do
          clientMsg <- agentCbDecrypt e2eDh cmNonce cmEncBody
          SMP.ClientMessage privHeader clientBody <- parseMessage clientMsg
          agentEnvelope <- parseMessage clientBody
          if agentVersion agentEnvelope `isCompatible` smpAgentVRange
            then pure (privHeader, agentEnvelope)
            else throwError $ AGENT A_VERSION

        parseMessage :: Encoding a => ByteString -> m a
        parseMessage = liftEither . parse smpP (AGENT A_MESSAGE)

        smpConfirmation :: C.APublicVerifyKey -> C.PublicKeyX25519 -> Maybe (CR.E2ERatchetParams 'C.X448) -> ByteString -> m ()
        smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo = do
          logServer "<--" c srv rId "MSG <CONF>"
          case status of
            New -> case (cType, e2eEncryption) of
              (SCRcv, Just e2eSndParams) -> do
                (pk1, rcDHRs) <- withStore $ \st -> getRatchetX3dhKeys st connId
                let rc = CR.initRcvRatchet rcDHRs $ CR.x3dhRcv pk1 rcDHRs e2eSndParams
                (agentMsgBody_, rc', skipped) <- liftError cryptoError $ CR.rcDecrypt rc M.empty encConnInfo
                case (agentMsgBody_, skipped) of
                  (Right agentMsgBody, CR.SMDNoChange) ->
                    parseMessage agentMsgBody >>= \case
                      AgentConnInfo connInfo -> do
                        g <- asks idsDrg
                        let senderConf = SMPConfirmation {senderKey, e2ePubKey, connInfo}
                            newConfirmation = NewConfirmation {connId, senderConf, ratchetState = rc'}
                        confId <- withStore $ \st -> createConfirmation st g newConfirmation
                        notify $ CONF confId connInfo
                      _ -> prohibited
                  _ -> prohibited
              (SCDuplex, Nothing) -> do
                agentRatchetDecrypt connId encConnInfo >>= parseMessage >>= \case
                  AgentConnInfo connInfo -> do
                    notify $ INFO connInfo
                    processConfirmation c rq $ SMPConfirmation {senderKey, e2ePubKey, connInfo}
                  _ -> prohibited
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
              case qInfo `proveCompatible` SMP.smpClientVRange of
                Nothing -> notify . ERR $ AGENT A_VERSION
                Just qInfo' -> do
                  sq <- newSndQueue qInfo'
                  withStore $ \st -> upgradeRcvConnToDuplex st connId sq
                  enqueueConfirmation c connId sq ownConnInfo Nothing
            _ -> prohibited

        agentClientMsg :: PrevRcvMsgHash -> ExternalSndId -> (BrokerId, BrokerTs) -> MsgFlags -> MsgBody -> AgentMessageType -> m (InternalId, MsgMeta)
        agentClientMsg externalPrevSndHash sndMsgId broker msgFlags msgBody msgType = do
          logServer "<--" c srv rId "MSG <MSG>"
          let internalHash = C.sha256Hash msgBody
          internalTs <- liftIO getCurrentTime
          (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- withStore (`updateRcvIds` connId)
          let integrity = checkMsgIntegrity prevExtSndId sndMsgId prevRcvMsgHash externalPrevSndHash
              recipient = (unId internalId, internalTs)
              msgMeta = MsgMeta {integrity, recipient, broker, sndMsgId}
              rcvMsg = RcvMsgData {msgMeta, msgType, msgFlags, msgBody, internalRcvId, internalHash, externalPrevSndHash}
          withStore $ \st -> createRcvMsg st connId rcvMsg
          pure (internalId, msgMeta)

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

confirmQueue :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
confirmQueue c connId sq connInfo e2eEncryption = do
  _ <- withStore (`updateSndIds` connId)
  msg <- mkConfirmation
  sendConfirmation c sq msg
  withStore $ \st -> setSndQueueStatus st sq Confirmed
  where
    mkConfirmation :: m MsgBody
    mkConfirmation = do
      encConnInfo <- agentRatchetEncrypt connId (smpEncode $ AgentConnInfo connInfo) e2eEncConnInfoLength
      pure . smpEncode $ AgentConfirmation {agentVersion = smpAgentVersion, e2eEncryption, encConnInfo}

enqueueConfirmation :: forall m. AgentMonad m => AgentClient -> ConnId -> SndQueue -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
enqueueConfirmation c connId sq connInfo e2eEncryption = do
  resumeMsgDelivery c connId sq
  msgId <- storeConfirmation
  queuePendingMsgs c connId sq [msgId]
  where
    storeConfirmation :: m InternalId
    storeConfirmation = do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- withStore (`updateSndIds` connId)
      let agentMsg = AgentConnInfo connInfo
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encConnInfo <- agentRatchetEncrypt connId agentMsgStr e2eEncConnInfoLength
      let msgBody = smpEncode $ AgentConfirmation {agentVersion = smpAgentVersion, e2eEncryption, encConnInfo}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, msgFlags = SMP.noMsgFlags, internalHash, prevMsgHash}
      withStore $ \st -> createSndMsg st connId msgData
      pure internalId

-- encoded AgentMessage -> encoded EncAgentMessage
agentRatchetEncrypt :: AgentMonad m => ConnId -> ByteString -> Int -> m ByteString
agentRatchetEncrypt connId msg paddedLen = do
  rc <- withStore $ \st -> getRatchet st connId
  (encMsg, rc') <- liftError cryptoError $ CR.rcEncrypt rc paddedLen msg
  withStore $ \st -> updateRatchet st connId rc' CR.SMDNoChange
  pure encMsg

-- encoded EncAgentMessage -> encoded AgentMessage
agentRatchetDecrypt :: AgentMonad m => ConnId -> ByteString -> m ByteString
agentRatchetDecrypt connId encAgentMsg = do
  (rc, skipped) <- withStore $ \st ->
    (,) <$> getRatchet st connId <*> getSkippedMsgKeys st connId
  (agentMsgBody_, rc', skippedDiff) <- liftError cryptoError $ CR.rcDecrypt rc skipped encAgentMsg
  withStore $ \st -> updateRatchet st connId rc' skippedDiff
  liftEither $ first cryptoError agentMsgBody_

notifyConnected :: AgentMonad m => AgentClient -> ConnId -> m ()
notifyConnected c connId = atomically $ writeTBQueue (subQ c) ("", connId, CON)

newSndQueue :: (MonadUnliftIO m, MonadReader Env m) => Compatible SMPQueueInfo -> m SndQueue
newSndQueue qInfo =
  asks (cmdSignAlg . config) >>= \case
    C.SignAlg a -> newSndQueue_ a qInfo

newSndQueue_ ::
  (C.SignatureAlgorithm a, C.AlgorithmI a, MonadUnliftIO m) =>
  C.SAlgorithm a ->
  Compatible SMPQueueInfo ->
  m SndQueue
newSndQueue_ a (Compatible (SMPQueueInfo _clientVersion smpServer senderId rcvE2ePubDhKey)) = do
  -- this function assumes clientVersion is compatible - it was tested before
  (sndPublicKey, sndPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (e2ePubKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  pure
    SndQueue
      { server = smpServer,
        sndId = senderId,
        sndPublicKey = Just sndPublicKey,
        sndPrivateKey,
        e2eDhSecret = C.dh' rcvE2ePubDhKey e2ePrivKey,
        e2ePubKey = Just e2ePubKey,
        status = New
      }
