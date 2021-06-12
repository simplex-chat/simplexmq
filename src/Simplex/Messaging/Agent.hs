{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
  ( runSMPAgent,
    runSMPAgentBlocking,
    getSMPAgentClient,
    runSMPAgentClient,
  )
where

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple (logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
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
import UnliftIO.Async (race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- | Runs an SMP agent as a TCP service using passed configuration.
--
-- See a full agent executable here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-agent/Main.hs
runSMPAgent :: (MonadFail m, MonadRandom m, MonadUnliftIO m) => ATransport -> AgentConfig -> m ()
runSMPAgent t cfg = do
  started <- newEmptyTMVarIO
  runSMPAgentBlocking t started cfg

-- | Runs an SMP agent as a TCP service using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPAgentBlocking :: (MonadFail m, MonadRandom m, MonadUnliftIO m) => ATransport -> TMVar Bool -> AgentConfig -> m ()
runSMPAgentBlocking (ATransport t) started cfg@AgentConfig {tcpPort} = runReaderT (smpAgent t) =<< newSMPAgentEnv cfg
  where
    smpAgent :: forall c m'. (Transport c, MonadFail m', MonadUnliftIO m', MonadReader Env m') => TProxy c -> m' ()
    smpAgent _ = runTransportServer started tcpPort $ \(h :: c) -> do
      liftIO $ putLn h "Welcome to SMP v0.3.2 agent"
      c <- getSMPAgentClient
      logConnection c True
      race_ (connectClient h c) (runSMPAgentClient c)
        `E.finally` (closeSMPServerClients c >> logConnection c False)

-- | Creates an SMP agent instance that receives commands and sends responses via 'TBQueue's.
getSMPAgentClient :: (MonadUnliftIO m, MonadReader Env m) => m AgentClient
getSMPAgentClient = do
  n <- asks clientCounter
  cfg <- asks config
  atomically $ newAgentClient n cfg

connectClient :: Transport c => MonadUnliftIO m => c -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runSMPAgentClient :: (MonadFail m, MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runSMPAgentClient c = do
  db <- asks $ dbFile . config
  s1 <- liftIO $ connectSQLiteStore db
  s2 <- liftIO $ connectSQLiteStore db
  race_ (subscriber c s1) (client c s2)

receive :: forall c m. (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
receive h c@AgentClient {rcvQ, sndQ} = forever loop
  where
    loop :: m ()
    loop = do
      (corrId, connId, cmdOrErr) <- tGet SClient h
      case cmdOrErr of
        Right cmd -> write rcvQ (corrId, connId, cmd)
        Left e -> write sndQ (corrId, connId, ERR e)
    write :: TBQueue (ATransmission p) -> ATransmission p -> m ()
    write q t = do
      logClient c "-->" t
      atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => c -> AgentClient -> m ()
send h c@AgentClient {sndQ} = forever $ do
  t <- atomically $ readTBQueue sndQ
  tPut h t
  logClient c "<--" t

logClient :: MonadUnliftIO m => AgentClient -> ByteString -> ATransmission a -> m ()
logClient AgentClient {clientId} dir (corrId, connId, cmd) = do
  logInfo . decodeUtf8 $ B.unwords [bshow clientId, dir, "A :", corrId, connId, B.takeWhile (/= ' ') $ serializeCommand cmd]

client :: forall m. (MonadFail m, MonadUnliftIO m, MonadReader Env m) => AgentClient -> SQLiteStore -> m ()
client c@AgentClient {rcvQ, sndQ} st = forever loop
  where
    loop :: m ()
    loop = do
      t@(corrId, connId, _) <- atomically $ readTBQueue rcvQ
      runExceptT (processCommand c st t) >>= \case
        Left e -> atomically $ writeTBQueue sndQ (corrId, connId, ERR e)
        Right _ -> pure ()

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

processCommand :: forall m. AgentMonad m => AgentClient -> SQLiteStore -> ATransmission 'Client -> m ()
processCommand c@AgentClient {sndQ} st (corrId, connId, cmd) = case cmd of
  NEW -> createNewConnection Nothing 0 >>= uncurry respond
  JOIN smpQueueInfo replyMode -> joinConnection smpQueueInfo replyMode Nothing 0 >> pure () -- >>= (`respond` OK)
  INTRO reConnId reInfo -> makeIntroduction reConnId reInfo
  ACPT invId connInfo -> acceptInvitation invId connInfo
  SUB -> subscribeConnection connId
  SUBALL -> subscribeAll
  SEND msgBody -> sendMessage msgBody
  OFF -> suspendConnection
  DEL -> deleteConnection
  where
    createNewConnection :: Maybe InvitationId -> Int -> m (ConnId, ACommand 'Agent)
    createNewConnection viaInv connLevel = do
      -- TODO create connection alias if not passed
      -- make connId Maybe?
      srv <- getSMPServer
      (rq, qInfo) <- newReceiveQueue c srv
      g <- asks idsDrg
      let cData = ConnData {connId, viaInv, connLevel}
      connId' <- withStore $ createRcvConn st g cData rq
      addSubscription c rq connId'
      pure (connId', INV qInfo)

    getSMPServer :: m SMPServer
    getSMPServer =
      asks (smpServers . config) >>= \case
        srv :| [] -> pure srv
        servers -> do
          gen <- asks randomServer
          i <- atomically . stateTVar gen $ randomR (0, L.length servers - 1)
          pure $ servers L.!! i

    joinConnection :: SMPQueueInfo -> ReplyMode -> Maybe InvitationId -> Int -> m ConnId
    joinConnection qInfo (ReplyMode replyMode) viaInv connLevel = do
      (sq, senderKey, verifyKey) <- newSendQueue qInfo
      g <- asks idsDrg
      let cData = ConnData {connId, viaInv, connLevel}
      connId' <- withStore $ createSndConn st g cData sq
      connectToSendQueue c st sq senderKey verifyKey
      when (replyMode == On) $ createReplyQueue connId' sq
      pure connId'

    makeIntroduction :: IntroId -> ConnInfo -> m ()
    makeIntroduction reConn reInfo =
      withStore ((,) <$> getConn st connId <*> getConn st reConn) >>= \case
        (SomeConn _ (DuplexConnection _ _ sq), SomeConn _ DuplexConnection {}) -> do
          g <- asks idsDrg
          introId <- withStore $ createIntro st g NewIntroduction {toConn = connId, reConn, reInfo}
          sendControlMessage c sq $ A_INTRO introId reInfo
          respond connId OK
        _ -> throwError $ CONN SIMPLEX

    acceptInvitation :: InvitationId -> ConnInfo -> m ()
    acceptInvitation invId connInfo =
      withStore (getInvitation st invId) >>= \case
        Invitation {viaConn, qInfo, externalIntroId, status = InvNew} ->
          withStore (getConn st viaConn) >>= \case
            SomeConn _ (DuplexConnection ConnData {connLevel} _ sq) -> case qInfo of
              Nothing -> do
                (connId', INV qInfo') <- createNewConnection (Just invId) (connLevel + 1)
                withStore $ addInvitationConn st invId connId'
                sendControlMessage c sq $ A_INV externalIntroId qInfo' connInfo
                respond connId' OK
              Just qInfo' -> do
                connId' <- joinConnection qInfo' (ReplyMode On) (Just invId) (connLevel + 1)
                withStore $ addInvitationConn st invId connId'
                respond connId' OK
            _ -> throwError $ CONN SIMPLEX
        _ -> throwError $ CMD PROHIBITED

    subscribeConnection :: ConnId -> m ()
    subscribeConnection cId =
      withStore (getConn st cId) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> subscribe rq
        SomeConn _ (RcvConnection _ rq) -> subscribe rq
        _ -> throwError $ CONN SIMPLEX
      where
        subscribe rq = subscribeQueue c rq cId >> respond cId OK

    -- TODO remove - hack for subscribing to all; respond' and parameterization of subscribeConnection are byproduct
    subscribeAll :: m ()
    subscribeAll = withStore (getAllConnIds st) >>= mapM_ subscribeConnection

    sendMessage :: MsgBody -> m ()
    sendMessage msgBody =
      withStore (getConn st connId) >>= \case
        SomeConn _ (DuplexConnection _ _ sq) -> sendMsg sq
        SomeConn _ (SndConnection _ sq) -> sendMsg sq
        _ -> throwError $ CONN SIMPLEX
      where
        sendMsg :: SndQueue -> m ()
        sendMsg sq = do
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
          atomically $ writeTBQueue sndQ (corrId, connId, SENT $ unId internalId)

    suspendConnection :: m ()
    suspendConnection =
      withStore (getConn st connId) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> suspend rq
        SomeConn _ (RcvConnection _ rq) -> suspend rq
        _ -> throwError $ CONN SIMPLEX
      where
        suspend rq = suspendQueue c rq >> respond connId OK

    deleteConnection :: m ()
    deleteConnection =
      withStore (getConn st connId) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> delete rq
        SomeConn _ (RcvConnection _ rq) -> delete rq
        _ -> delConn
      where
        delConn = withStore (deleteConn st connId) >> respond connId OK
        delete rq = do
          deleteQueue c rq
          removeSubscription c connId
          delConn

    createReplyQueue :: ConnId -> SndQueue -> m ()
    createReplyQueue cId sq = do
      srv <- getSMPServer
      (rq, qInfo) <- newReceiveQueue c srv
      addSubscription c rq cId
      withStore $ upgradeSndConnToDuplex st cId rq
      sendControlMessage c sq $ REPLY qInfo

    respond :: ConnId -> ACommand 'Agent -> m ()
    respond cId resp = atomically . writeTBQueue sndQ $ (corrId, cId, resp)

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

subscriber :: (MonadFail m, MonadUnliftIO m, MonadReader Env m) => AgentClient -> SQLiteStore -> m ()
subscriber c@AgentClient {msgQ} st = forever $ do
  -- TODO this will only process messages and notifications
  t <- atomically $ readTBQueue msgQ
  runExceptT (processSMPTransmission c st t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> SQLiteStore -> SMPServerTransmission -> m ()
processSMPTransmission c@AgentClient {sndQ} st (srv, rId, cmd) = do
  withStore (getRcvConn st srv rId) >>= \case
    SomeConn SCDuplex (DuplexConnection cData rq _) -> processSMP SCDuplex cData rq
    SomeConn SCRcv (RcvConnection cData rq) -> processSMP SCRcv cData rq
    _ -> atomically $ writeTBQueue sndQ ("", "", ERR $ CONN NOT_FOUND)
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
            Right (SMPConfirmation senderKey) -> smpConfirmation senderKey
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
        notify msg = atomically $ writeTBQueue sndQ ("", connId, msg)

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        smpConfirmation :: SenderPublicKey -> m ()
        smpConfirmation senderKey = do
          logServer "<--" c srv rId "MSG <KEY>"
          case status of
            New -> do
              -- TODO currently it automatically allows whoever sends the confirmation
              -- Commands CONF and LET are not supported in v0.2
              withStore $ setRcvQueueStatus st rq Confirmed
              -- TODO update sender key in the store?
              secureQueue c rq senderKey
              withStore $ setRcvQueueStatus st rq Secured
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
              (sq, senderKey, verifyKey) <- newSendQueue qInfo
              withStore $ upgradeRcvConnToDuplex st connId sq
              connectToSendQueue c st sq senderKey verifyKey
              connected
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
            sendConMsg toConn reConn = atomically $ writeTBQueue sndQ ("", toConn, ICON reConn)

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

connectToSendQueue :: AgentMonad m => AgentClient -> SQLiteStore -> SndQueue -> SenderPublicKey -> VerificationKey -> m ()
connectToSendQueue c st sq senderKey verifyKey = do
  sendConfirmation c sq senderKey
  withStore $ setSndQueueStatus st sq Confirmed
  sendHello c sq verifyKey
  withStore $ setSndQueueStatus st sq Active

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
