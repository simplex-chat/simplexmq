{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent
  ( runSMPAgent,
    runSMPAgentBlocking,
    getSMPAgentClient,
    runSMPAgentClient,
  )
where

import Control.Logger.Simple (logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore, connectSQLiteStore)
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (CorrId (..), MsgBody, SenderPublicKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (putLn, runTCPServer)
import Simplex.Messaging.Util (bshow)
import System.IO (Handle)
import UnliftIO.Async (race_)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m ()
runSMPAgent cfg = newEmptyTMVarIO >>= (`runSMPAgentBlocking` cfg)

runSMPAgentBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> AgentConfig -> m ()
runSMPAgentBlocking started cfg@AgentConfig {tcpPort} = runReaderT smpAgent =<< newSMPAgentEnv cfg
  where
    smpAgent :: (MonadUnliftIO m', MonadReader Env m') => m' ()
    smpAgent = runTCPServer started tcpPort $ \h -> do
      liftIO $ putLn h "Welcome to SMP v0.2.0 agent"
      c <- getSMPAgentClient
      logConnection c True
      race_ (connectClient h c) (runSMPAgentClient c)
        `E.finally` (closeSMPServerClients c >> logConnection c False)

getSMPAgentClient :: (MonadUnliftIO m, MonadReader Env m) => m AgentClient
getSMPAgentClient = do
  n <- asks clientCounter
  cfg <- asks config
  atomically $ newAgentClient n cfg

connectClient :: MonadUnliftIO m => Handle -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

runSMPAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runSMPAgentClient c = do
  db <- asks $ dbFile . config
  s1 <- connectSQLiteStore db
  s2 <- connectSQLiteStore db
  race_ (subscriber c s1) (client c s2)

receive :: forall m. MonadUnliftIO m => Handle -> AgentClient -> m ()
receive h c@AgentClient {rcvQ, sndQ} = forever $ do
  (corrId, cAlias, cmdOrErr) <- tGet SClient h
  case cmdOrErr of
    Right cmd -> write rcvQ (corrId, cAlias, cmd)
    Left e -> write sndQ (corrId, cAlias, ERR e)
  where
    write :: TBQueue (ATransmission p) -> ATransmission p -> m ()
    write q t = do
      logClient c "-->" t
      atomically $ writeTBQueue q t

send :: MonadUnliftIO m => Handle -> AgentClient -> m ()
send h c@AgentClient {sndQ} = forever $ do
  t <- atomically $ readTBQueue sndQ
  tPut h t
  logClient c "<--" t

logClient :: MonadUnliftIO m => AgentClient -> ByteString -> ATransmission a -> m ()
logClient AgentClient {clientId} dir (CorrId corrId, cAlias, cmd) = do
  logInfo . decodeUtf8 $ B.unwords [bshow clientId, dir, "A :", corrId, cAlias, B.takeWhile (/= ' ') $ serializeCommand cmd]

client :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> SQLiteStore -> m ()
client c@AgentClient {rcvQ, sndQ} st = forever $ do
  t@(corrId, cAlias, _) <- atomically $ readTBQueue rcvQ
  runExceptT (processCommand c st t) >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()

withStore ::
  AgentMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => m' a) ->
  m a
withStore action = do
  runExceptT (action `E.catch` handleInternal) >>= \case
    Right c -> return c
    Left e -> throwError $ storeError e
  where
    handleInternal :: (MonadError StoreError m') => SQLError -> m' a
    handleInternal e = throwError . SEInternal $ bshow e
    storeError :: StoreError -> AgentErrorType
    storeError = \case
      SEConnNotFound -> CONN UNKNOWN
      SEConnDuplicate -> CONN DUPLICATE
      e -> INTERNAL $ show e

processCommand :: forall m. AgentMonad m => AgentClient -> SQLiteStore -> ATransmission 'Client -> m ()
processCommand c@AgentClient {sndQ} st (corrId, connAlias, cmd) =
  case cmd of
    NEW smpServer -> createNewConnection smpServer
    JOIN smpQueueInfo replyMode -> joinConnection smpQueueInfo replyMode
    SUB -> subscribeConnection connAlias
    SUBALL -> subscribeAll
    SEND msgBody -> sendMessage msgBody
    OFF -> suspendConnection
    DEL -> deleteConnection
  where
    createNewConnection :: SMPServer -> m ()
    createNewConnection server = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (rq, qInfo) <- newReceiveQueue c server connAlias
      withStore $ createRcvConn st rq
      respond $ INV qInfo

    joinConnection :: SMPQueueInfo -> ReplyMode -> m ()
    joinConnection qInfo@(SMPQueueInfo srv _ _) replyMode = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (sq, senderKey, verifyKey) <- newSendQueue qInfo connAlias
      withStore $ createSndConn st sq
      connectToSendQueue c st sq senderKey verifyKey
      case replyMode of
        ReplyOn -> sendReplyQInfo srv sq
        ReplyVia srv' -> sendReplyQInfo srv' sq
        ReplyOff -> return ()
      respond CON

    subscribeConnection :: ConnAlias -> m ()
    subscribeConnection cAlias =
      withStore (getConn st cAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> subscribe rq
        SomeConn _ (RcvConnection _ rq) -> subscribe rq
        _ -> throwError $ CONN SIMPLEX
      where
        subscribe rq = subscribeQueue c rq cAlias >> respond' cAlias OK

    -- TODO remove - hack for subscribing to all; respond' and parameterization of subscribeConnection are byproduct
    subscribeAll :: m ()
    subscribeAll = withStore (getAllConnAliases st) >>= mapM_ subscribeConnection

    sendMessage :: MsgBody -> m ()
    sendMessage msgBody =
      withStore (getConn st connAlias) >>= \case
        SomeConn _ (DuplexConnection _ _ sq) -> sendMsg sq
        SomeConn _ (SndConnection _ sq) -> sendMsg sq
        _ -> throwError $ CONN SIMPLEX
      where
        sendMsg sq = do
          senderTimestamp <- liftIO getCurrentTime
          (senderId, SndMsgData {msgStr}) <- withStore $ createSndMsg st connAlias $ mkMsgData senderTimestamp
          sendAgentMessage c sq msgStr
          respond $ SENT (unId senderId)
        mkMsgData :: InternalTs -> InternalId -> PrevSndMsgHash -> SndMsgData
        mkMsgData senderTimestamp internalId previousMsgHash =
          let msgStr =
                serializeSMPMessage
                  SMPMessage
                    { senderMsgId = unId internalId,
                      senderTimestamp,
                      previousMsgHash,
                      agentMessage = A_MSG msgBody
                    }
           in SndMsgData
                { internalTs = senderTimestamp,
                  msgBody,
                  msgHash = C.sha256Hash msgStr,
                  msgStr
                }

    suspendConnection :: m ()
    suspendConnection =
      withStore (getConn st connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> suspend rq
        SomeConn _ (RcvConnection _ rq) -> suspend rq
        _ -> throwError $ CONN SIMPLEX
      where
        suspend rq = suspendQueue c rq >> respond OK

    deleteConnection :: m ()
    deleteConnection =
      withStore (getConn st connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> delete rq
        SomeConn _ (RcvConnection _ rq) -> delete rq
        _ -> delConn
      where
        delConn = withStore (deleteConn st connAlias) >> respond OK
        delete rq = do
          deleteQueue c rq
          removeSubscription c connAlias
          delConn

    sendReplyQInfo :: SMPServer -> SndQueue -> m ()
    sendReplyQInfo srv sq = do
      (rq, qInfo) <- newReceiveQueue c srv connAlias
      withStore $ upgradeSndConnToDuplex st connAlias rq
      senderTimestamp <- liftIO getCurrentTime
      sendAgentMessage c sq . serializeSMPMessage $
        SMPMessage
          { senderMsgId = 0,
            senderTimestamp,
            previousMsgHash = "",
            agentMessage = REPLY qInfo
          }

    respond :: ACommand 'Agent -> m ()
    respond = respond' connAlias

    respond' :: ConnAlias -> ACommand 'Agent -> m ()
    respond' cAlias resp = atomically $ writeTBQueue sndQ (corrId, cAlias, resp)

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> SQLiteStore -> m ()
subscriber c@AgentClient {msgQ} st = forever $ do
  -- TODO this will only process messages and notifications
  t <- atomically $ readTBQueue msgQ
  runExceptT (processSMPTransmission c st t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> SQLiteStore -> SMPServerTransmission -> m ()
processSMPTransmission c@AgentClient {sndQ} st (srv, rId, cmd) = do
  rq@RcvQueue {connAlias, status} <- withStore $ getRcvQueue st srv rId
  case cmd of
    SMP.MSG srvMsgId srvTs msgBody -> do
      -- TODO deduplicate with previously received
      msg <- decryptAndVerify rq msgBody
      let msgHash = C.sha256Hash msg
      agentMsg <- liftEither $ parseSMPMessage msg
      case agentMsg of
        SMPConfirmation senderKey -> do
          logServer "<--" c srv rId "MSG <KEY>"
          case status of
            New -> do
              -- TODO currently it automatically allows whoever sends the confirmation
              -- Commands CONF and LET are not supported in v0.2
              withStore $ setRcvQueueStatus st rq Confirmed
              -- TODO update sender key in the store?
              secureQueue c rq senderKey
              withStore $ setRcvQueueStatus st rq Secured
            _ -> notify connAlias . ERR $ AGENT A_PROHIBITED
        SMPMessage {agentMessage, senderMsgId, senderTimestamp} ->
          case agentMessage of
            HELLO verifyKey _ -> do
              logServer "<--" c srv rId "MSG <HELLO>"
              case status of
                Active -> notify connAlias . ERR $ AGENT A_PROHIBITED
                _ -> do
                  void $ verifyMessage (Just verifyKey) msgBody
                  withStore $ setRcvQueueActive st rq verifyKey
            REPLY qInfo -> do
              logServer "<--" c srv rId "MSG <REPLY>"
              (sq, senderKey, verifyKey) <- newSendQueue qInfo connAlias
              withStore $ upgradeRcvConnToDuplex st connAlias sq
              connectToSendQueue c st sq senderKey verifyKey
              notify connAlias CON
            A_MSG body -> agentClientMsg rq (senderMsgId, senderTimestamp) (srvMsgId, srvTs) body msgHash
      sendAck c rq
      return ()
    SMP.END -> do
      removeSubscription c connAlias
      logServer "<--" c srv rId "END"
      notify connAlias END
    _ -> do
      logServer "<--" c srv rId $ "unexpected: " <> bshow cmd
      notify connAlias . ERR $ BROKER UNEXPECTED
  where
    notify :: ConnAlias -> ACommand 'Agent -> m ()
    notify connAlias msg = atomically $ writeTBQueue sndQ ("", connAlias, msg)
    agentClientMsg :: RcvQueue -> (ExternalSndId, ExternalSndTs) -> (BrokerId, BrokerTs) -> MsgBody -> MsgHash -> m ()
    agentClientMsg RcvQueue {connAlias, status} m_sender m_broker body msgHash = do
      -- TODO check message status
      logServer "<--" c srv rId "MSG <MSG>"
      case status of
        Active -> do
          internalTs <- liftIO getCurrentTime
          (recipientId, RcvMsgData {}) <- withStore $ createRcvMsg st connAlias $ mkMsgData internalTs
          notify connAlias $
            MSG
              { m_integrity = MsgOk,
                m_recipient = (unId recipientId, internalTs),
                m_sender,
                m_broker,
                m_body = body
              }
        _ -> notify connAlias . ERR $ AGENT A_PROHIBITED
      where
        mkMsgData :: InternalTs -> InternalId -> PrevExternalSndId -> PrevRcvMsgHash -> RcvMsgData
        mkMsgData internalTs internalId prevExtSndId prevMsgHash =
          RcvMsgData
            { internalTs,
              msgHash,
              m_sender,
              m_broker,
              m_body = body,
              m_integrity = MsgOk
            }

connectToSendQueue :: AgentMonad m => AgentClient -> SQLiteStore -> SndQueue -> SenderPublicKey -> VerificationKey -> m ()
connectToSendQueue c st sq senderKey verifyKey = do
  sendConfirmation c sq senderKey
  withStore $ setSndQueueStatus st sq Confirmed
  sendHello c sq verifyKey
  withStore $ setSndQueueStatus st sq Active

newSendQueue ::
  (MonadUnliftIO m, MonadReader Env m) => SMPQueueInfo -> ConnAlias -> m (SndQueue, SenderPublicKey, VerificationKey)
newSendQueue (SMPQueueInfo smpServer senderId encryptKey) connAlias = do
  size <- asks $ rsaKeySize . config
  (senderKey, sndPrivateKey) <- liftIO $ C.generateKeyPair size
  (verifyKey, signKey) <- liftIO $ C.generateKeyPair size
  let sndQueue =
        SndQueue
          { server = smpServer,
            sndId = senderId,
            connAlias,
            sndPrivateKey,
            encryptKey,
            signKey,
            status = New
          }
  return (sndQueue, senderKey, verifyKey)
