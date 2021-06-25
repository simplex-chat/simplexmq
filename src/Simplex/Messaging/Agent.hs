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
    AgentMonad,
    AgentErrorMonad,
    getSMPAgentClient,
    createConnection,
    joinConnection,
    sendIntroduction,
    acceptInvitation,
    subscribeConnection,
    sendMessage,
    suspendConnection,
    deleteConnection,
    createConnection',
    joinConnection',
    sendIntroduction',
    acceptInvitation',
    subscribeConnection',
    sendMessage',
    suspendConnection',
    deleteConnection',
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
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore, connectSQLiteStore)
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (MsgBody, SenderPublicKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..), runTransportServer)
import Simplex.Messaging.Util (bshow)
import System.Random (randomR)
import UnliftIO.Async (Async, async, race_)
import UnliftIO.Concurrent (forkIO)
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
        `E.finally` disconnectServers c

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m (Async (), AgentClient)
getSMPAgentClient cfg = newSMPAgentEnv cfg >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient
      st <- agentDB
      action <- async $ subscriber c st `E.finally` disconnectServers c
      pure (action, c)

disconnectServers :: MonadUnliftIO m => AgentClient -> m ()
disconnectServers c = closeSMPServerClients c >> logConnection c False

-- |
type AgentErrorMonad m = (MonadUnliftIO m, MonadError AgentErrorType m)

-- | Create SMP agent connection (NEW command) in Reader monad
createConnection' :: AgentMonad m => AgentClient -> m (ConnId, SMPQueueInfo)
createConnection' c = newConn c "" Nothing 0

-- | Create SMP agent connection (NEW command)
createConnection :: AgentErrorMonad m => AgentClient -> m (ConnId, SMPQueueInfo)
createConnection c = createConnection' c `runReaderT` agentEnv c

-- | Join SMP agent connection (JOIN command) in Reader monad
joinConnection' :: AgentMonad m => AgentClient -> SMPQueueInfo -> ConnInfo -> m ConnId
joinConnection' c qInfo cInfo = joinConn c "" qInfo cInfo Nothing 0

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> SMPQueueInfo -> ConnInfo -> m ConnId
joinConnection c qInfo cInfo = joinConnection' c qInfo cInfo `runReaderT` agentEnv c

-- | Accept invitation (ACPT command) in Reader monad
acceptInvitation' :: AgentMonad m => AgentClient -> InvitationId -> ConnInfo -> m ConnId
acceptInvitation' c = acceptInv c ""

-- | Accept invitation (ACPT command)
acceptInvitation :: AgentErrorMonad m => AgentClient -> InvitationId -> ConnInfo -> m ConnId
acceptInvitation c invId cInfo = acceptInvitation c invId cInfo `runReaderT` agentEnv c

-- | Send introduction of the second connection the first (INTRO command)
sendIntroduction :: AgentErrorMonad m => AgentClient -> ConnId -> ConnId -> ConnInfo -> m ()
sendIntroduction c toConn reConn reInfo = sendIntroduction' c toConn reConn reInfo `runReaderT` agentEnv c

-- | Subscribe to receive connection messages (SUB command)
subscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
subscribeConnection c connId = subscribeConnection' c connId `runReaderT` agentEnv c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgBody -> m InternalId
sendMessage c connId msgBody = sendMessage' c connId msgBody `runReaderT` agentEnv c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
suspendConnection c connId = suspendConnection' c connId `runReaderT` agentEnv c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c connId = deleteConnection' c connId `runReaderT` agentEnv c

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
getAgentClient :: (MonadUnliftIO m, MonadReader Env m) => m AgentClient
getAgentClient = do
  store <- agentDB
  env <- ask
  atomically $ newAgentClient store env

connectClient :: Transport c => MonadUnliftIO m => c -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runAgentClient c = do
  st <- agentDB
  race_ (subscriber c st) (client c)

agentDB :: (MonadUnliftIO m, MonadReader Env m) => m SQLiteStore
agentDB = do
  db <- asks $ dbFile . config
  liftIO $ connectSQLiteStore db

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
  runExceptT (processCommand c (connId, cmd))
    >>= atomically . writeTBQueue subQ . \case
      Left e -> (corrId, connId, ERR e)
      Right (connId', resp) -> (corrId, connId', resp)

withStore ::
  AgentMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => m' a) ->
  m a
withStore action = do
  runExceptT (action `E.catch` handleInternal) >>= \case
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
  NEW -> second INV <$> newConn c connId Nothing 0
  JOIN smpQueueInfo connInfo -> (,OK) <$> joinConn c connId smpQueueInfo connInfo Nothing 0
  LET confirmationId ownConnInfo -> (,OK) <$> letConfirmation c connId confirmationId ownConnInfo
  INTRO reConnId reInfo -> sendIntroduction' c connId reConnId reInfo $> (connId, OK)
  ACPT invId connInfo -> (,OK) <$> acceptInv c connId invId connInfo
  SUB -> subscribeConnection' c connId $> (connId, OK)
  SEND msgBody -> (connId,) . SENT . unId <$> sendMessage' c connId msgBody
  OFF -> suspendConnection' c connId $> (connId, OK)
  DEL -> deleteConnection' c connId $> (connId, OK)

newConn :: AgentMonad m => AgentClient -> ConnId -> Maybe InvitationId -> Int -> m (ConnId, SMPQueueInfo)
newConn c connId viaInv connLevel = do
  srv <- getSMPServer
  (rq, qInfo) <- newReceiveQueue c srv
  g <- asks idsDrg
  let cData = ConnData {connId, viaInv, connLevel}
  connId' <- withStore $ createRcvConn st g cData rq
  addSubscription c rq connId'
  pure (connId', qInfo)
  where
    st = store c

joinConn :: forall m. AgentMonad m => AgentClient -> ConnId -> SMPQueueInfo -> ConnInfo -> Maybe InvitationId -> Int -> m ConnId
joinConn c connId qInfo cInfo viaInv connLevel = do
  (sq, senderKey, verifyKey) <- newSendQueue qInfo
  g <- asks idsDrg
  let cData = ConnData {connId, viaInv, connLevel}
  connId' <- withStore $ createSndConn st g cData sq
  connectToSendQueue c sq senderKey verifyKey cInfo
  createReplyQueue connId' sq
  pure connId'
  where
    st = store c
    createReplyQueue :: ConnId -> SndQueue -> m ()
    createReplyQueue cId sq = do
      srv <- getSMPServer
      (rq, qInfo') <- newReceiveQueue c srv
      addSubscription c rq cId
      withStore $ upgradeSndConnToDuplex st cId rq
      sendControlMessage c sq $ REPLY qInfo'

letConfirmation :: forall m. AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ConnId
letConfirmation c connId confirmationId ownConnInfo =
  withStore (getConn st connId) >>= \case
    SomeConn SCDuplex (DuplexConnection _ rq _) -> processConfirmation' rq
    SomeConn SCRcv (RcvConnection _ rq) -> processConfirmation' rq
    _ -> throwError $ CONN SIMPLEX
  where
    st = store c
    processConfirmation' :: RcvQueue -> m ConnId
    processConfirmation' rq = do
      withStore $ approveConfirmation st confirmationId ownConnInfo
      confirmation <- withStore $ getConfirmation st confirmationId
      let sndKey = senderKey (confirmation :: Confirmation)
      processConfirmation c rq sndKey
      pure connId

processConfirmation :: AgentMonad m => AgentClient -> RcvQueue -> SenderPublicKey -> m ()
processConfirmation c rq sndKey = do
  withStore $ setRcvQueueStatus st rq Confirmed
  secureQueue c rq sndKey
  withStore $ setRcvQueueStatus st rq Secured
  where
    st = store c

-- | Send introduction of the second connection the first (INTRO command) in Reader monad
sendIntroduction' :: AgentMonad m => AgentClient -> ConnId -> ConnId -> ConnInfo -> m ()
sendIntroduction' c toConn reConn reInfo =
  withStore ((,) <$> getConn st toConn <*> getConn st reConn) >>= \case
    (SomeConn _ (DuplexConnection _ _ sq), SomeConn _ DuplexConnection {}) -> do
      g <- asks idsDrg
      introId <- withStore $ createIntro st g NewIntroduction {toConn, reConn, reInfo}
      sendControlMessage c sq $ A_INTRO introId reInfo
    _ -> throwError $ CONN SIMPLEX
  where
    st = store c

acceptInv :: AgentMonad m => AgentClient -> ConnId -> InvitationId -> ConnInfo -> m ConnId
acceptInv c connId invId connInfo =
  withStore (getInvitation st invId) >>= \case
    Invitation {viaConn, qInfo, externalIntroId, status = InvNew} ->
      withStore (getConn st viaConn) >>= \case
        SomeConn _ (DuplexConnection ConnData {connLevel} _ sq) -> case qInfo of
          Nothing -> do
            (connId', qInfo') <- newConn c connId (Just invId) (connLevel + 1)
            withStore $ addInvitationConn st invId connId'
            sendControlMessage c sq $ A_INV externalIntroId qInfo' connInfo
            pure connId'
          Just qInfo' -> do
            -- TODO remove invitations from protocol
            connId' <- joinConn c connId qInfo' "dummyConnInfo" (Just invId) (connLevel + 1)
            withStore $ addInvitationConn st invId connId'
            pure connId'
        _ -> throwError $ CONN SIMPLEX
    _ -> throwError $ CMD PROHIBITED
  where
    st = store c

-- | Subscribe to receive connection messages (SUB command) in Reader monad
subscribeConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
subscribeConnection' c connId =
  withStore (getConn (store c) connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> subscribeQueue c rq connId
    SomeConn _ (RcvConnection _ rq) -> subscribeQueue c rq connId
    _ -> throwError $ CONN SIMPLEX

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgBody -> m InternalId
sendMessage' c connId msgBody =
  withStore (getConn st connId) >>= \case
    SomeConn _ (DuplexConnection _ _ sq) -> sendMsg_ sq
    SomeConn _ (SndConnection _ sq) -> sendMsg_ sq
    _ -> throwError $ CONN SIMPLEX
  where
    st = store c
    sendMsg_ :: SndQueue -> m InternalId
    sendMsg_ sq = do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, previousMsgHash) <- withStore $ updateSndIds st connId
      let msgStr =
            serializeSMPMessage
              SMPMessage
                { senderMsgId = unSndId internalSndId,
                  senderTimestamp = internalTs,
                  previousMsgHash,
                  agentMessage = A_MSG msgBody
                }
          msgHash = C.sha256Hash msgStr
      withStore $
        createSndMsg st connId $
          SndMsgData {internalId, internalSndId, internalTs, msgBody, internalHash = msgHash}
      sendAgentMessage c sq msgStr
      pure internalId

-- | Suspend SMP agent connection (OFF command) in Reader monad
suspendConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
suspendConnection' c connId =
  withStore (getConn (store c) connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> suspendQueue c rq
    SomeConn _ (RcvConnection _ rq) -> suspendQueue c rq
    _ -> throwError $ CONN SIMPLEX

-- | Delete SMP agent connection (DEL command) in Reader monad
deleteConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
deleteConnection' c connId =
  withStore (getConn st connId) >>= \case
    SomeConn _ (DuplexConnection _ rq _) -> delete rq
    SomeConn _ (RcvConnection _ rq) -> delete rq
    _ -> withStore (deleteConn st connId)
  where
    st = store c
    delete :: RcvQueue -> m ()
    delete rq = do
      deleteQueue c rq
      removeSubscription c connId
      withStore (deleteConn st connId)

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

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> SQLiteStore -> m ()
subscriber c@AgentClient {msgQ} st = forever $ do
  t <- atomically $ readTBQueue msgQ
  runExceptT (processSMPTransmission c st t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> SQLiteStore -> SMPServerTransmission -> m ()
processSMPTransmission c@AgentClient {subQ} st (srv, rId, cmd) = do
  withStore (getRcvConn st srv rId) >>= \case
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
                A_INTRO introId cInfo -> introMsg introId cInfo
                A_INV introId qInfo cInfo -> invMsg introId qInfo cInfo
                A_REQ introId qInfo cInfo -> reqMsg introId qInfo cInfo
                A_CON introId -> conMsg introId
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
                confirmationId <- withStore $ createConfirmation st g newConfirmation
                notify $ CNFRM confirmationId cInfo
              SCDuplex -> processConfirmation c rq senderKey
              _ -> prohibited
            _ -> prohibited

        helloMsg :: SenderPublicKey -> ByteString -> m ()
        helloMsg verifyKey msgBody = do
          logServer "<--" c srv rId "MSG <HELLO>"
          case status of
            Active -> prohibited
            _ -> do
              void $ verifyMessage (Just verifyKey) msgBody
              withStore $ setRcvQueueActive st rq verifyKey
              case cType of
                SCDuplex -> connected
                _ -> pure ()

        replyMsg :: SMPQueueInfo -> m ()
        replyMsg qInfo = do
          logServer "<--" c srv rId "MSG <REPLY>"
          case cType of
            SCRcv -> do
              confirmation <- withStore $ getApprovedConfirmation st connId
              case ownConnInfo (confirmation :: Confirmation) of
                Just ownCInfo -> do
                  (sq, senderKey, verifyKey) <- newSendQueue qInfo
                  withStore $ upgradeRcvConnToDuplex st connId sq
                  connectToSendQueue c sq senderKey verifyKey ownCInfo
                  withStore $ removeApprovedConfirmation st connId
                  connected
                _ -> prohibited -- TODO separate error type?
            _ -> prohibited

        connected :: m ()
        connected = do
          withStore (getConnInvitation st connId) >>= \case
            Just (Invitation {invId, externalIntroId}, DuplexConnection _ _ sq) -> do
              withStore $ setInvitationStatus st invId InvCon
              sendControlMessage c sq $ A_CON externalIntroId
            _ -> pure ()
          notify CON

        introMsg :: IntroId -> ConnInfo -> m ()
        introMsg introId reInfo = do
          logServer "<--" c srv rId "MSG <INTRO>"
          case cType of
            SCDuplex -> createInv introId Nothing reInfo
            _ -> prohibited

        invMsg :: IntroId -> SMPQueueInfo -> ConnInfo -> m ()
        invMsg introId qInfo toInfo = do
          logServer "<--" c srv rId "MSG <INV>"
          case cType of
            SCDuplex ->
              withStore (getIntro st introId) >>= \case
                Introduction {toConn, toStatus = IntroNew, reConn, reStatus = IntroNew}
                  | toConn /= connId -> prohibited
                  | otherwise ->
                    withStore (addIntroInvitation st introId toInfo qInfo >> getConn st reConn) >>= \case
                      SomeConn _ (DuplexConnection _ _ sq) -> do
                        sendControlMessage c sq $ A_REQ introId qInfo toInfo
                        withStore $ setIntroReStatus st introId IntroInv
                      _ -> prohibited
                _ -> prohibited
            _ -> prohibited

        reqMsg :: IntroId -> SMPQueueInfo -> ConnInfo -> m ()
        reqMsg introId qInfo connInfo = do
          logServer "<--" c srv rId "MSG <REQ>"
          case cType of
            SCDuplex -> createInv introId (Just qInfo) connInfo
            _ -> prohibited

        createInv :: IntroId -> Maybe SMPQueueInfo -> ConnInfo -> m ()
        createInv externalIntroId qInfo connInfo = do
          g <- asks idsDrg
          let newInv = NewInvitation {viaConn = connId, externalIntroId, connInfo, qInfo}
          invId <- withStore $ createInvitation st g newInv
          notify $ REQ invId connInfo

        conMsg :: IntroId -> m ()
        conMsg introId = do
          logServer "<--" c srv rId "MSG <CON>"
          withStore (getIntro st introId) >>= \case
            Introduction {toConn, toStatus, reConn, reStatus}
              | toConn == connId && toStatus == IntroInv -> do
                withStore $ setIntroToStatus st introId IntroCon
                when (reStatus == IntroCon) $ sendConMsg toConn reConn
              | reConn == connId && reStatus == IntroInv -> do
                withStore $ setIntroReStatus st introId IntroCon
                when (toStatus == IntroCon) $ sendConMsg toConn reConn
              | otherwise -> prohibited
          where
            sendConMsg :: ConnId -> ConnId -> m ()
            sendConMsg toConn reConn = atomically $ writeTBQueue subQ ("", toConn, ICON reConn)

        agentClientMsg :: PrevRcvMsgHash -> (ExternalSndId, ExternalSndTs) -> (BrokerId, BrokerTs) -> MsgBody -> MsgHash -> m ()
        agentClientMsg receivedPrevMsgHash senderMeta brokerMeta msgBody msgHash = do
          logServer "<--" c srv rId "MSG <MSG>"
          case status of
            Active -> do
              internalTs <- liftIO getCurrentTime
              (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- withStore $ updateRcvIds st connId
              let msgIntegrity = checkMsgIntegrity prevExtSndId (fst senderMeta) prevRcvMsgHash receivedPrevMsgHash
              withStore $
                createRcvMsg st connId $
                  RcvMsgData
                    { internalId,
                      internalRcvId,
                      internalTs,
                      senderMeta,
                      brokerMeta,
                      msgBody,
                      internalHash = msgHash,
                      externalPrevSndHash = receivedPrevMsgHash,
                      msgIntegrity
                    }
              notify
                MSG
                  { recipientMeta = (unId internalId, internalTs),
                    senderMeta,
                    brokerMeta,
                    msgBody,
                    msgIntegrity
                  }
            _ -> prohibited

        checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
        checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
          | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
          | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
          | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
          | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
          | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
          | otherwise = MsgError MsgDuplicate -- this case is not possible

connectToSendQueue :: AgentMonad m => AgentClient -> SndQueue -> SenderPublicKey -> VerificationKey -> ConnInfo -> m ()
connectToSendQueue c sq senderKey verifyKey cInfo = do
  sendConfirmation c sq senderKey cInfo
  withStore $ setSndQueueStatus st sq Confirmed
  -- TODO return thread id to kill on client stop
  _t <- forkIO $ activateQueue c sq verifyKey
  pure ()
  where
    st = store c

activateQueue :: AgentMonad m => AgentClient -> SndQueue -> VerificationKey -> m ()
activateQueue c@AgentClient {store} sq verifyKey = do
  sendHello c sq verifyKey 100_000
  withStore $ setSndQueueStatus store sq Active

newSendQueue ::
  (MonadUnliftIO m, MonadReader Env m) => SMPQueueInfo -> m (SndQueue, SenderPublicKey, VerificationKey)
newSendQueue (SMPQueueInfo smpServer senderId encryptKey) = do
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
