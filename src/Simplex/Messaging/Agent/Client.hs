{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Client where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Time.Clock
import Numeric.Natural
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (PrivateKey, PublicKey, SenderKey)
import qualified Simplex.Messaging.Server.Transmission as SMP
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

type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m)

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

    throwErr :: ErrorType -> SomeException -> m a
    throwErr err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err

liftSMP :: (MonadUnliftIO m, MonadError ErrorType m) => ExceptT SMPClientError IO a -> m a
liftSMP action =
  liftIO (first smpClientError <$> runExceptT action) >>= liftEither
  where
    smpClientError :: SMPClientError -> ErrorType
    smpClientError = \case
      SMPServerError e -> SMP e
      _ -> INTERNAL -- TODO handle other errors

newReceiveQueue :: AgentMonad m => AgentClient -> SMPServer -> m (ReceiveQueue, SMPQueueInfo)
newReceiveQueue c server = do
  smp <- getSMPServerClient c server
  g <- asks idsDrg
  recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let rcvPrivateKey = recipientKey
  (rcvId, sId) <- liftSMP $ createSMPQueue smp rcvPrivateKey recipientKey
  encryptKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let decryptKey = encryptKey
      rcvQueue =
        ReceiveQueue
          { server,
            rcvId,
            rcvPrivateKey,
            sndId = Just sId,
            sndKey = Nothing,
            decryptKey,
            verifyKey = Nothing,
            status = New,
            ackMode = AckMode On
          }
  return (rcvQueue, SMPQueueInfo server sId encryptKey)

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SendQueue -> SenderKey -> m ()
sendConfirmation c SendQueue {server, sndId} senderKey = do
  -- TODO send initial confirmation with signature - change in SMP server
  smp <- getSMPServerClient c server
  msg <- mkConfirmation
  liftSMP $ sendSMPMessage smp "" sndId msg
  where
    mkConfirmation :: m SMP.MsgBody
    mkConfirmation = do
      let msg = serializeSMPMessage $ SMPConfirmation senderKey
      -- TODO encryption
      return msg

sendHello :: forall m. AgentMonad m => AgentClient -> SendQueue -> m ()
sendHello c SendQueue {server, sndId, sndPrivateKey, encryptKey} = do
  smp <- getSMPServerClient c server
  msg <- mkHello "5678" $ AckMode On -- TODO verifyKey
  _send smp 20 msg
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
                           threadDelay 100000
                           _send smp (retry - 1) msg
                         _ -> throwError INTERNAL -- TODO wrap client error in some constructor
                     )

secureQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> SenderKey -> m ()
secureQueue c ReceiveQueue {server, rcvId, rcvPrivateKey} senderKey = do
  smp <- getSMPServerClient c server
  liftSMP $ secureSMPQueue smp rcvPrivateKey rcvId senderKey

sendAck :: AgentMonad m => AgentClient -> ReceiveQueue -> m ()
sendAck c ReceiveQueue {server, rcvId, rcvPrivateKey} = do
  smp <- getSMPServerClient c server
  liftSMP $ ackSMPMessage smp rcvPrivateKey rcvId

sendAgentMessage :: AgentMonad m => AgentClient -> SendQueue -> AMessage -> m ()
sendAgentMessage c SendQueue {server, sndId, sndPrivateKey, encryptKey} agentMsg = do
  smp <- getSMPServerClient c server
  msg <- mkAgentMessage encryptKey agentMsg
  liftSMP $ sendSMPMessage smp sndPrivateKey sndId msg

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
