{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    newAgentClient,
    AgentMonad,
    getSMPServerClient,
    newReceiveQueue,
    sendConfirmation,
    sendHello,
    secureQueue,
    sendAgentMessage,
    sendAck,
    logServer,
  )
where

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text.Encoding
import Data.Time.Clock
import Numeric.Natural
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import Simplex.Messaging.Common (MsgBody, PrivateKey, PublicKey, QueueId, SMPErrorType (AUTH), SenderKey)
import Simplex.Messaging.Server (randomBytes)
import UnliftIO.Concurrent
import UnliftIO.Exception (SomeException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ATransmission 'Client),
    sndQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue SMPServerTransmission,
    smpClients :: TVar (Map SMPServer SMPClient),
    clientId :: Int
  }

newAgentClient :: TVar Int -> Natural -> STM AgentClient
newAgentClient cc qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpClients <- newTVar M.empty
  clientId <- (+ 1) <$> readTVar cc
  writeTVar cc clientId
  return AgentClient {rcvQ, sndQ, msgQ, smpClients, clientId}

type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

getSMPServerClient :: forall m. AgentMonad m => AgentClient -> SMPServer -> m SMPClient
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

    throwErr :: AgentErrorType -> SomeException -> m a
    throwErr err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err

withSMP :: forall a m. AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withSMP c srv action =
  (getSMPServerClient c srv >>= runAction) `catchError` logServerError
  where
    runAction :: SMPClient -> m a
    runAction smp =
      liftIO (first smpClientError <$> runExceptT (action smp))
        >>= liftEither

    smpClientError :: SMPClientError -> AgentErrorType
    smpClientError = \case
      SMPServerError e -> SMP e
      -- TODO handle other errors
      _ -> INTERNAL

    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ (B.pack . show) e
      throwError e

withLogSMP :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withLogSMP c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withSMP c srv action
  logServer "<--" c srv qId "OK"
  return res

newReceiveQueue :: AgentMonad m => AgentClient -> SMPServer -> m (ReceiveQueue, SMPQueueInfo)
newReceiveQueue c srv = do
  g <- asks idsDrg
  recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let rcvPrivateKey = recipientKey
  logServer "-->" c srv "" "NEW"
  (rcvId, sId) <- withSMP c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sId]
  encryptKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let decryptKey = encryptKey
      rcvQueue =
        ReceiveQueue
          { server = srv,
            rcvId,
            rcvPrivateKey,
            sndId = Just sId,
            sndKey = Nothing,
            decryptKey,
            verifyKey = Nothing,
            status = New,
            ackMode = AckMode On
          }
  return (rcvQueue, SMPQueueInfo srv sId encryptKey)

logServer :: AgentMonad m => ByteString -> AgentClient -> SMPServer -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} SMPServer {host, port} qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> (B.pack . show) clientId <> ")", dir, server, ":", logSecret qId, cmdStr]
  where
    server = B.pack $ host <> maybe "" (":" <>) port

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SendQueue -> SenderKey -> m ()
sendConfirmation c SendQueue {server, sndId} senderKey = do
  -- TODO send initial confirmation with signature - change in SMP server
  msg <- mkConfirmation
  withLogSMP c server sndId "SEND <KEY>" $ \smp ->
    sendSMPMessage smp "" sndId msg
  where
    mkConfirmation :: m MsgBody
    mkConfirmation = do
      let msg = serializeSMPMessage $ SMPConfirmation senderKey
      -- TODO encryption
      return msg

sendHello :: forall m. AgentMonad m => AgentClient -> SendQueue -> m ()
sendHello c SendQueue {server, sndId, sndPrivateKey, encryptKey} = do
  msg <- mkHello "5678" $ AckMode On -- TODO verifyKey
  withLogSMP c server sndId "SEND <HELLO> (retrying)" $
    send 20 msg
  where
    mkHello :: PublicKey -> AckMode -> m ByteString
    mkHello verifyKey ackMode =
      mkAgentMessage encryptKey $ HELLO verifyKey ackMode

    send :: Int -> ByteString -> SMPClient -> ExceptT SMPClientError IO ()
    send 0 _ _ = throwE SMPResponseTimeout -- TODO different error
    send retry msg smp =
      sendSMPMessage smp sndPrivateKey sndId msg `catchE` \case
        SMPServerError AUTH -> do
          threadDelay 100000
          send (retry - 1) msg smp
        e -> throwE e

secureQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> SenderKey -> m ()
secureQueue c ReceiveQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogSMP c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

sendAck :: AgentMonad m => AgentClient -> ReceiveQueue -> m ()
sendAck c ReceiveQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId

sendAgentMessage :: AgentMonad m => AgentClient -> SendQueue -> AMessage -> m ()
sendAgentMessage c SendQueue {server, sndId, sndPrivateKey, encryptKey} agentMsg = do
  msg <- mkAgentMessage encryptKey agentMsg
  withLogSMP c server sndId "SEND <message>" $ \smp ->
    sendSMPMessage smp sndPrivateKey sndId msg

mkAgentMessage :: MonadUnliftIO m => PrivateKey -> AMessage -> m ByteString
mkAgentMessage _encKey agentMessage = do
  agentTimestamp <- liftIO getCurrentTime
  let msg =
        serializeSMPMessage
          SMPMessage
            { agentMsgId = 0,
              agentTimestamp,
              previousMsgHash = "1234", -- TODO hash of the previous message
              agentMessage
            }
  -- TODO encryption
  return msg
