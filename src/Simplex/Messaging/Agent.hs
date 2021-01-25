{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent (runSMPAgent) where

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite.Util (SQLiteStore)
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (SMPServerTransmission)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Transport
import Simplex.Messaging.Types (CorrId (..), MsgBody, PrivateKey, SenderKey)
import UnliftIO.Async
import UnliftIO.Exception (SomeException)
import qualified UnliftIO.Exception as E
import UnliftIO.IO
import UnliftIO.STM

runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m ()
runSMPAgent cfg@AgentConfig {tcpPort} = do
  env <- newEnv cfg
  runReaderT smpAgent env
  where
    smpAgent :: (MonadUnliftIO m', MonadReader Env m') => m' ()
    smpAgent = runTCPServer tcpPort $ \h -> do
      liftIO $ putLn h "Welcome to SMP v0.2.0 agent"
      q <- asks $ tbqSize . config
      n <- asks clientCounter
      c <- atomically $ newAgentClient n q
      logInfo $ "client " <> showText (clientId c) <> " connected to Agent"
      race_ (connectClient h c) (runClient c)

connectClient :: MonadUnliftIO m => Handle -> AgentClient -> m ()
connectClient h c = do
  race_ (send h c) (receive h c)
  logInfo $ "client " <> showText (clientId c) <> " disconnected from Agent"

runClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runClient c = race_ (subscriber c) (client c)

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
    Left e -> throwError $ STORE e
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
    ACK aMsgId -> ackMessage aMsgId
    OFF -> suspendConnection
    DEL -> deleteConnection
  where
    createNewConnection :: SMPServer -> m ()
    createNewConnection server = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (rq, qInfo) <- newReceiveQueue c server connAlias
      withStore $ \st -> createRcvConn st connAlias rq
      respond $ INV qInfo

    joinConnection :: SMPQueueInfo -> ReplyMode -> m ()
    joinConnection qInfo@(SMPQueueInfo srv _ _) replyMode = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (sq, senderKey) <- newSendQueue qInfo
      withStore $ \st -> createSndConn st connAlias sq
      connectToSendQueue c sq senderKey
      case replyMode of
        ReplyOn -> sendReplyQInfo srv sq
        ReplyVia srv' -> sendReplyQInfo srv' sq
        ReplyOff -> return ()
      respond CON

    subscribeConnection :: m ()
    subscribeConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> subscribe rq
        SomeConn _ (ReceiveConnection _ rq) -> subscribe rq
        -- TODO possibly there should be a separate error type trying to send the message to the connection without ReceiveQueue
        _ -> throwError PROHIBITED
      where
        subscribe rq = subscribeQueue c rq connAlias >> respond OK

    sendMessage :: MsgBody -> m ()
    sendMessage msgBody =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ _ sq) -> sendMsg sq
        SomeConn _ (SendConnection _ sq) -> sendMsg sq
        -- TODO possibly there should be a separate error type trying to send the message to the connection without SendQueue
        _ -> throwError PROHIBITED -- NOT_READY ?
      where
        sendMsg sq = do
          sendAgentMessage c sq $ A_MSG msgBody
          -- TODO respond $ SENT aMsgId
          respond OK

    ackMessage :: AgentMsgId -> m ()
    ackMessage _aMsgId =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> ackMsg rq
        SomeConn _ (ReceiveConnection _ rq) -> ackMsg rq
        -- TODO possibly there should be a separate error type trying to send the message to the connection without ReceiveQueue
        -- NOT_READY ?
        _ -> throwError PROHIBITED
      where
        ackMsg rq = sendAck c rq >> respond OK

    suspendConnection :: m ()
    suspendConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> suspend rq
        SomeConn _ (ReceiveConnection _ rq) -> suspend rq
        _ -> throwError PROHIBITED
      where
        suspend rq = suspendQueue c rq >> respond OK

    deleteConnection :: m ()
    deleteConnection =
      withStore (`getConn` connAlias) >>= \case
        SomeConn _ (DuplexConnection _ rq _) -> delete rq
        SomeConn _ (ReceiveConnection _ rq) -> delete rq
        _ -> throwError PROHIBITED
      where
        delete rq = do
          deleteQueue c rq
          withStore (`deleteConn` connAlias)
          respond OK

    sendReplyQInfo :: SMPServer -> SendQueue -> m ()
    sendReplyQInfo srv sq = do
      (rq, qInfo) <- newReceiveQueue c srv connAlias
      withStore $ \st -> addRcvQueue st connAlias rq
      sendAgentMessage c sq $ REPLY qInfo

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
  (connAlias, rq@ReceiveQueue {decryptKey, status}) <- withStore $ \st -> getReceiveQueue st srv rId
  case cmd of
    SMP.MSG _ srvTs msgBody -> do
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
              withStore $ \st -> updateRcvQueueStatus st rq Confirmed
              -- TODO update sender key in the store
              secureQueue c rq senderKey
              withStore $ \st -> updateRcvQueueStatus st rq Secured
              sendAck c rq
            s ->
              -- TODO maybe send notification to the user
              liftIO . putStrLn $ "unexpected SMP confirmation, queue status " <> show s
        SMPMessage {agentMessage, agentMsgId, agentTimestamp} ->
          case agentMessage of
            HELLO _verifyKey _ -> do
              logServer "<--" c srv rId "MSG <HELLO>"
              -- TODO send status update to the user?
              withStore $ \st -> updateRcvQueueStatus st rq Active
              sendAck c rq
            REPLY qInfo -> do
              logServer "<--" c srv rId "MSG <REPLY>"
              -- TODO move senderKey inside SendQueue
              (sq, senderKey) <- newSendQueue qInfo
              withStore $ \st -> addSndQueue st connAlias sq
              connectToSendQueue c sq senderKey
              notify connAlias CON
              sendAck c rq
            A_MSG body -> do
              logServer "<--" c srv rId "MSG <MSG>"
              -- TODO check message status
              notify connAlias $ MSG agentMsgId agentTimestamp srvTs MsgOk body
      return ()
    SMP.END -> do
      removeSubscription c connAlias
      logServer "<--" c srv rId "END"
      notify connAlias END
    _ -> logServer "<--" c srv rId $ "unexpected:" <> (B.pack . show) cmd
  where
    notify :: ConnAlias -> ACommand 'Agent -> m ()
    notify connAlias msg = atomically $ writeTBQueue sndQ ("", connAlias, msg)

connectToSendQueue :: AgentMonad m => AgentClient -> SendQueue -> SenderKey -> m ()
connectToSendQueue c sq senderKey = do
  sendConfirmation c sq senderKey
  withStore $ \st -> updateSndQueueStatus st sq Confirmed
  sendHello c sq
  withStore $ \st -> updateSndQueueStatus st sq Active

decryptMessage :: MonadUnliftIO m => PrivateKey -> ByteString -> m ByteString
decryptMessage _decryptKey = return

newSendQueue ::
  (MonadUnliftIO m, MonadReader Env m) => SMPQueueInfo -> m (SendQueue, SenderKey)
newSendQueue (SMPQueueInfo smpServer senderId encryptKey) = do
  g <- asks idsDrg
  senderKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  verifyKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let sndPrivateKey = senderKey
      signKey = verifyKey
      sndQueue =
        SendQueue
          { server = smpServer,
            sndId = senderId,
            sndPrivateKey,
            encryptKey,
            signKey,
            -- verifyKey,
            status = New,
            ackMode = AckMode On
          }
  return (sndQueue, senderKey)
