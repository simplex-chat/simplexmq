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

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.Map as M
import Data.Time.Clock
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (PrivateKey, PublicKey)
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import UnliftIO.Async
import UnliftIO.Concurrent
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
      putLn h "Welcome to SMP v0.2.0 agent"
      q <- asks $ tbqSize . config
      c <- atomically $ newAgentClient q
      race_ (connectClient h c) (runClient c)

connectClient :: MonadUnliftIO m => Handle -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

runClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runClient c = race_ (subscriber c) (client c)

receive :: MonadUnliftIO m => Handle -> AgentClient -> m ()
receive h AgentClient {rcvQ, sndQ} =
  forever $
    tGet SClient h >>= \(corrId, cAlias, command) -> atomically $ case command of
      Right cmd -> writeTBQueue rcvQ (corrId, cAlias, cmd)
      Left e -> writeTBQueue sndQ (corrId, cAlias, ERR e)

send :: MonadUnliftIO m => Handle -> AgentClient -> m ()
send h AgentClient {sndQ} = forever $ atomically (readTBQueue sndQ) >>= tPut h

client :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
client c@AgentClient {rcvQ, sndQ} = forever $ do
  t@(corrId, cAlias, _) <- atomically $ readTBQueue rcvQ
  runExceptT (processCommand c t) >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()

withStore ::
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
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

liftSMP :: (MonadUnliftIO m, MonadError ErrorType m) => ExceptT SMPClientError IO a -> m a
liftSMP action =
  liftIO (first smpClientError <$> runExceptT action) >>= liftEither
  where
    smpClientError :: SMPClientError -> ErrorType
    smpClientError = \case
      SMPServerError e -> SMP e
      _ -> INTERNAL -- TODO handle other errors

processCommand ::
  forall m.
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
  AgentClient ->
  ATransmission 'Client ->
  m ()
processCommand c@AgentClient {sndQ} (corrId, connAlias, cmd) =
  case cmd of
    NEW smpServer -> createNewConnection smpServer
    JOIN smpQueueInfo replyMode -> joinConnection smpQueueInfo replyMode
    _ -> throwError PROHIBITED
  where
    createNewConnection :: SMPServer -> m ()
    createNewConnection smpServer = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      qInfo <- newReceiveConnection smpServer
      respond $ INV qInfo

    joinConnection :: SMPQueueInfo -> ReplyMode -> m ()
    joinConnection qInfo replyMode = do
      -- TODO create connection alias if not passed
      -- make connAlias Maybe?
      (sndQueue, senderKey) <- newSendConnection qInfo
      sendConfirmation sndQueue senderKey
      sendHello sndQueue
      sendReplyQueue sndQueue replyMode
      respond OK

    sendReplyQueue :: SendQueue -> ReplyMode -> m ()
    sendReplyQueue sndQueue = \case
      ReplyOff -> return ()
      ReplyOn srv -> do
        qInfo <- newReceiveConnection srv
        sendAgentMessage sndQueue $ REPLY qInfo

    mkConfirmation :: PublicKey -> PublicKey -> m SMP.MsgBody
    mkConfirmation _encKey senderKey = do
      let msg = serializeSMPMessage $ SMPConfirmation senderKey
      -- TODO encryption
      return msg

    sendHello :: SendQueue -> m ()
    sendHello SendQueue {server, sndId, sndPrivateKey, encryptKey} = do
      smp <- getSMPServerClient c server
      msg <- mkHello "" $ AckMode On -- TODO verifyKey
      _send smp 20 msg
      withStore $ \st -> updateQueueStatus st connAlias SND Active
      where
        mkHello :: PublicKey -> AckMode -> m ByteString
        mkHello verifyKey ackMode =
          mkAgentMessage encryptKey $ HELLO verifyKey ackMode

        _send :: SMPClient -> Int -> ByteString -> m ()
        _send _ 0 _ = throwError INTERNAL -- TODO different error
        _send smp retry msg = do
          liftSMP (sendSMPMessage smp sndPrivateKey sndId msg)
            `catchError` ( \case
                             SMP SMP.AUTH -> do
                               liftIO $ threadDelay 100000
                               _send smp (retry - 1) msg
                             _ -> throwError INTERNAL -- TODO wrap client error in some constructor
                         )

    newReceiveConnection :: SMPServer -> m SMPQueueInfo
    newReceiveConnection smpServer = do
      smp <- getSMPServerClient c smpServer
      g <- asks idsDrg
      recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      let rcvPrivateKey = recipientKey
      (recipientId, senderId) <- liftSMP $ createSMPQueue smp rcvPrivateKey recipientKey
      encryptKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      let decryptKey = encryptKey
      withStore $ \st ->
        createRcvConn st connAlias $
          ReceiveQueue
            { server = smpServer,
              rcvId = recipientId,
              rcvPrivateKey,
              sndId = Just senderId,
              sndKey = Nothing,
              decryptKey,
              verifyKey = Nothing,
              status = New,
              ackMode = AckMode On
            }
      return $ SMPQueueInfo smpServer senderId encryptKey

    newSendConnection :: SMPQueueInfo -> m (SendQueue, SMP.SenderKey)
    newSendConnection (SMPQueueInfo smpServer senderId encryptKey) = do
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
      withStore $ \st -> createSndConn st connAlias sndQueue
      return (sndQueue, senderKey)

    sendConfirmation :: SendQueue -> SMP.SenderKey -> m ()
    sendConfirmation SendQueue {server, sndId, encryptKey} senderKey = do
      -- TODO send initial confirmation with signature - change in SMP server
      smp <- getSMPServerClient c server
      msg <- mkConfirmation encryptKey senderKey
      liftSMP $ sendSMPMessage smp "" sndId msg
      withStore $ \st -> updateQueueStatus st connAlias SND Confirmed

    sendAgentMessage :: SendQueue -> AMessage -> m ()
    sendAgentMessage SendQueue {server, sndId, sndPrivateKey, encryptKey} agentMsg = do
      smp <- getSMPServerClient c server
      msg <- mkAgentMessage encryptKey agentMsg
      liftSMP $ sendSMPMessage smp sndPrivateKey sndId msg

    mkAgentMessage :: PrivateKey -> AMessage -> m ByteString
    mkAgentMessage _encKey agentMessage = do
      agentTimestamp <- liftIO getCurrentTime
      let msg =
            serializeSMPMessage
              SMPMessage
                { agentMsgId = 0,
                  agentTimestamp,
                  previousMsgHash = "",
                  agentMessage
                }
      -- TODO encryption
      return msg

    respond :: ACommand 'Agent -> m ()
    respond resp = atomically $ writeTBQueue sndQ (corrId, connAlias, resp)

subscriber :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  -- TODO this will only process messages and notifications
  t <- atomically $ readTBQueue msgQ
  runExceptT (processSMPTransmission c t) >>= \case
    Left e -> liftIO $ print e
    Right _ -> return ()

processSMPTransmission ::
  forall m.
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
  AgentClient ->
  SMPServerTransmission ->
  m ()
processSMPTransmission c (srv, rId, cmd) = do
  case cmd of
    SMP.MSG _msgId _ts msgBody -> do
      -- TODO deduplicate with previously received
      (connAlias, rcvQueue@ReceiveQueue {decryptKey, status}) <- withStore $ \st -> getReceiveQueue st srv rId
      agentMsg <- liftEither . parseSMPMessage =<< decryptMessage decryptKey msgBody
      case agentMsg of
        SMPConfirmation senderKey -> do
          case status of
            New ->
              secureQueue rcvQueue connAlias senderKey
            s ->
              -- TODO maybe send notification to the user
              liftIO . putStrLn $ "unexpected SMP confirmation, queue status " <> show s
        SMPMessage {agentMessage} ->
          case agentMessage of
            HELLO _verifyKey _ -> return ()
            REPLY _qInfo -> return ()
            A_MSG _msgBody -> return ()
      return ()
    SMP.END -> return ()
    _ -> liftIO $ do
      putStrLn "unexpected response"
      print cmd
  where
    secureQueue :: ReceiveQueue -> ConnAlias -> SMP.SenderKey -> m ()
    secureQueue ReceiveQueue {rcvPrivateKey} connAlias senderKey = do
      withStore $ \st -> updateQueueStatus st connAlias RCV Confirmed
      -- TODO update sender key in the store
      smp <- getSMPServerClient c srv
      liftSMP $ secureSMPQueue smp rcvPrivateKey rId senderKey
      withStore $ \st -> updateQueueStatus st connAlias RCV Secured

decryptMessage :: MonadUnliftIO m => PrivateKey -> ByteString -> m ByteString
decryptMessage _decryptKey = return

getSMPServerClient ::
  forall m.
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
  AgentClient ->
  SMPServer ->
  m SMPClient
getSMPServerClient AgentClient {smpClients, msgQ} srv =
  atomically (M.lookup srv <$> readTVar smpClients)
    >>= maybe newSMPClient return
  where
    newSMPClient :: m SMPClient
    newSMPClient = do
      cfg <- asks $ smpCfg . config
      c <- liftIO (getSMPClient srv cfg msgQ) `E.catch` throwErr (BROKER smpErrTCPConnection)
      atomically . modifyTVar smpClients $ M.insert srv c
      return c

    throwErr :: ErrorType -> SomeException -> m a
    throwErr err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err
