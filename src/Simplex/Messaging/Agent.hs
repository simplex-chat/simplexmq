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
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (CorrId (..), MsgBody, SenderPublicKey)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (putLn, runTCPServer)
import Simplex.Messaging.Util (liftError)
import System.IO (Handle)
import UnliftIO.Async (race_)
import UnliftIO.Exception (SomeException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m ()
runSMPAgent cfg@AgentConfig {tcpPort} = runReaderT smpAgent =<< newSMPAgentEnv cfg
  where
    smpAgent :: (MonadUnliftIO m', MonadReader Env m') => m' ()
    smpAgent = runTCPServer tcpPort $ \h -> do
      liftIO $ putLn h "Welcome to SMP v0.2.0 agent"
      c <- getSMPAgentClient
      logConnection c True
      race_ (connectClient h c) (runSMPAgentClient c)
        `E.finally` (closeSMPServerClients c >> logConnection c False)

getSMPAgentClient :: (MonadUnliftIO m, MonadReader Env m) => m AgentClient
getSMPAgentClient = do
  q <- asks $ tbqSize . config
  n <- asks clientCounter
  atomically $ newAgentClient n q

connectClient :: MonadUnliftIO m => Handle -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

runSMPAgentClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runSMPAgentClient c = race_ (subscriber c) (client c)

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
  logInfo . decodeUtf8 $ B.unwords [B.pack $ show clientId, dir, "A :", corrId, cAlias, B.takeWhile (/= ' ') $ serializeCommand cmd]

client :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
client c@AgentClient {rcvQ, sndQ} = forever $ do
  t@(corrId, cAlias, _) <- atomically $ readTBQueue rcvQ
  runExceptT (processCommand c t) >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()

withStore ::
  AgentMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => SQLiteStore -> m' a) ->
  m a
withStore action = do
  store <- asks db
  runExceptT (action store `E.catch` handleInternal) >>= \case
    Right c -> return c
    Left _ -> throwError STORE
  where
    handleInternal :: (MonadError StoreError m') => SomeException -> m' a
    handleInternal _ = throwError SEInternal

processCommand :: forall m. AgentMonad m => AgentClient -> ATransmission 'Client -> m ()
processCommand c@AgentClient {sndQ} (corrId, connAlias, cmd) =
  case cmd of
    NEW smpServer -> createNewConnection smpServer
    JOIN smpQueueInfo replyMode -> joinConnection smpQueueInfo replyMode
    SUB -> subscribeConnection
    SEND msgBody -> sendMessage msgBody
    OFF -> suspendConnection
    DEL -> deleteConnection
  where
    createNewConnection :: SMPServer -> m ()
    createNewConnection server = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (rq, qInfo) <- newReceiveQueue c server connAlias
      withStore $ \st -> createRcvConn st rq
      respond $ INV qInfo

    joinConnection :: SMPQueueInfo -> ReplyMode -> m ()
    joinConnection qInfo@(SMPQueueInfo srv _ _) replyMode = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (sq, senderKey, verifyKey) <- newSendQueue qInfo connAlias
      withStore $ \st -> createSndConn st sq
      connectToSendQueue c sq senderKey verifyKey
      case replyMode of
        ReplyOn -> sendReplyQInfo srv sq
        ReplyVia srv' -> sendReplyQInfo srv' sq
        ReplyOff -> return ()
      respond CON

    subscribeConnection :: m ()
    subscribeConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> subscribe rq
        SomeConn _ (RcvConnection _ rq) -> subscribe rq
        -- TODO possibly there should be a separate error type trying
        -- TODO to send the message to the connection without RcvQueue
        _ -> throwError PROHIBITED
      where
        subscribe rq = subscribeQueue c rq connAlias >> respond OK

    sendMessage :: MsgBody -> m ()
    sendMessage msgBody =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ _ sq) -> sendMsg sq
        SomeConn _ (SndConnection _ sq) -> sendMsg sq
        -- TODO possibly there should be a separate error type trying
        -- TODO to send the message to the connection without SndQueue
        _ -> throwError PROHIBITED -- NOT_READY ?
      where
        sendMsg sq = do
          senderTs <- liftIO getCurrentTime
          senderId <- withStore $ \st -> createSndMsg st connAlias msgBody senderTs
          sendAgentMessage c sq senderTs $ A_MSG msgBody
          respond $ SENT senderId

    suspendConnection :: m ()
    suspendConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> suspend rq
        SomeConn _ (RcvConnection _ rq) -> suspend rq
        _ -> throwError PROHIBITED
      where
        suspend rq = suspendQueue c rq >> respond OK

    deleteConnection :: m ()
    deleteConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> delete rq
        SomeConn _ (RcvConnection _ rq) -> delete rq
        _ -> throwError PROHIBITED
      where
        delete rq = do
          deleteQueue c rq
          removeSubscription c connAlias
          withStore (`deleteConn` connAlias)
          respond OK

    sendReplyQInfo :: SMPServer -> SndQueue -> m ()
    sendReplyQInfo srv sq = do
      (rq, qInfo) <- newReceiveQueue c srv connAlias
      withStore $ \st -> upgradeSndConnToDuplex st connAlias rq
      senderTs <- liftIO getCurrentTime
      sendAgentMessage c sq senderTs $ REPLY qInfo

    respond :: ACommand 'Agent -> m ()
    respond resp = atomically $ writeTBQueue sndQ (corrId, connAlias, resp)

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  -- TODO this will only process messages and notifications
  t <- atomically $ readTBQueue msgQ
  runExceptT (processSMPTransmission c t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission :: forall m. AgentMonad m => AgentClient -> SMPServerTransmission -> m ()
processSMPTransmission c@AgentClient {sndQ} (srv, rId, cmd) = do
  rq@RcvQueue {connAlias, decryptKey, status} <- withStore $ \st -> getRcvQueue st srv rId
  case cmd of
    SMP.MSG srvMsgId srvTs msgBody -> do
      -- TODO deduplicate with previously received
      agentMsg <- liftEither . parseSMPMessage =<< decryptMessage decryptKey msgBody
      case agentMsg of
        SMPConfirmation senderKey -> do
          logServer "<--" c srv rId "MSG <KEY>"
          case status of
            New -> do
              -- TODO currently it automatically allows whoever sends the confirmation
              -- Commands CONF and LET are not implemented yet
              -- They are probably not needed in v0.2?
              -- TODO notification that connection confirmed?
              withStore $ \st -> setRcvQueueStatus st rq Confirmed
              -- TODO update sender key in the store
              secureQueue c rq senderKey
              withStore $ \st -> setRcvQueueStatus st rq Secured
              sendAck c rq
            s ->
              -- TODO maybe send notification to the user
              liftIO . putStrLn $ "unexpected SMP confirmation, queue status " <> show s
        SMPMessage {agentMessage, senderMsgId, senderTimestamp} ->
          case agentMessage of
            HELLO _verifyKey _ -> do
              logServer "<--" c srv rId "MSG <HELLO>"
              -- TODO send status update to the user?
              withStore $ \st -> setRcvQueueStatus st rq Active
              sendAck c rq
            REPLY qInfo -> do
              logServer "<--" c srv rId "MSG <REPLY>"
              -- TODO move senderKey inside SndQueue
              (sq, senderKey, verifyKey) <- newSendQueue qInfo connAlias
              withStore $ \st -> upgradeRcvConnToDuplex st connAlias sq
              connectToSendQueue c sq senderKey verifyKey
              notify connAlias CON
              sendAck c rq
            A_MSG body -> do
              logServer "<--" c srv rId "MSG <MSG>"
              -- TODO check message status
              recipientTs <- liftIO getCurrentTime
              recipientId <- withStore $ \st -> createRcvMsg st connAlias body recipientTs senderMsgId senderTimestamp srvMsgId srvTs
              notify connAlias $
                MSG
                  { m_status = MsgOk,
                    m_recipient = (recipientId, recipientTs),
                    m_sender = (senderMsgId, senderTimestamp),
                    m_broker = (srvMsgId, srvTs),
                    m_body = body
                  }
              sendAck c rq
      return ()
    SMP.END -> do
      removeSubscription c connAlias
      logServer "<--" c srv rId "END"
      notify connAlias END
    _ -> logServer "<--" c srv rId $ "unexpected:" <> (B.pack . show) cmd
  where
    notify :: ConnAlias -> ACommand 'Agent -> m ()
    notify connAlias msg = atomically $ writeTBQueue sndQ ("", connAlias, msg)

connectToSendQueue :: AgentMonad m => AgentClient -> SndQueue -> SenderPublicKey -> VerificationKey -> m ()
connectToSendQueue c sq senderKey verifyKey = do
  sendConfirmation c sq senderKey
  withStore $ \st -> setSndQueueStatus st sq Confirmed
  sendHello c sq verifyKey
  withStore $ \st -> setSndQueueStatus st sq Active

decryptMessage :: (MonadUnliftIO m, MonadError AgentErrorType m) => DecryptionKey -> ByteString -> m ByteString
decryptMessage decryptKey msg = liftError CRYPTO $ C.decrypt decryptKey msg

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
