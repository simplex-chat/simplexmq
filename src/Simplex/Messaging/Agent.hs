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
import qualified Data.Map as M
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (PublicKey)
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
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
      putLn h "Welcome to SMP v0.2.0 agent"
      q <- asks $ tbqSize . config
      c <- atomically $ newAgentClient q
      race_ (connectClient h c) (runClient c)

connectClient :: MonadUnliftIO m => Handle -> AgentClient -> m ()
connectClient h c = race_ (send h c) (receive h c)

runClient :: (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
runClient c = race_ (processSmp c) (client c)

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

processCommand ::
  forall m.
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
  AgentClient ->
  ATransmission 'Client ->
  m ()
processCommand AgentClient {sndQ, smpClients} (corrId, connAlias, cmd) =
  case cmd of
    NEW smpServer -> createNewConnection smpServer
    JOIN smpQueueInfo replyMode -> joinConnection smpQueueInfo replyMode
    _ -> throwError PROHIBITED
  where
    createNewConnection :: SMPServer -> m ()
    createNewConnection smpServer = do
      c <- getSMPServerClient smpServer
      g <- asks idsDrg
      recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      let rcvPrivateKey = recipientKey
      (recipientId, senderId) <-
        liftIO (createSMPQueue c recipientKey)
          `E.catch` smpClientError
          `E.catch` replyError INTERNAL
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
      respond . INV $ SMPQueueInfo smpServer senderId encryptKey

    joinConnection :: SMPQueueInfo -> ReplyMode -> m ()
    joinConnection (SMPQueueInfo smpServer senderId encryptKey) _ = do
      c <- getSMPServerClient smpServer
      g <- asks idsDrg
      senderKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      verifyKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      -- TODO create connection with NEW status, it will be upgraded to CONFIRMED status once SMP server replies OK to SEND
      msg <- mkConfirmation encryptKey senderKey
      let sndPrivateKey = senderKey
          signKey = verifyKey
      withStore $ \st ->
        createSndConn st connAlias $
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
      liftIO (sendSMPMessage c "" senderId msg)
        `E.catch` smpClientError
        `E.catch` replyError INTERNAL
      withStore $ \st -> updateQueueStatus st connAlias SND Confirmed
      respond OK

    smpClientError :: SMPClientError -> m a
    smpClientError = \case
      SMPServerError e -> throwError $ SMP e
      _ -> throwError INTERNAL
    -- TODO

    replyError :: ErrorType -> SomeException -> m a
    replyError err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err

    getSMPServerClient :: SMPServer -> m SMPClient
    getSMPServerClient srv =
      atomically (M.lookup srv <$> readTVar smpClients)
        >>= maybe newSMPClient return
      where
        newSMPClient :: m SMPClient
        newSMPClient = do
          qSize <- asks $ tbqSize . config
          c <- liftIO (getSMPClient srv qSize) `E.catch` replyError (BROKER smpErrTCPConnection)
          atomically . modifyTVar smpClients $ M.insert srv c
          return c

    mkConfirmation :: PublicKey -> PublicKey -> m SMP.MsgBody
    mkConfirmation _encKey senderKey = do
      let msg = "KEY " <> senderKey <> "\r\n\r\n"
      -- TODO encryption
      return msg

    respond :: ACommand 'Agent -> m ()
    respond c = atomically $ writeTBQueue sndQ (corrId, connAlias, c)

processSmp :: MonadUnliftIO m => AgentClient -> m ()
processSmp AgentClient {respQ} = forever $ do
  -- TODO this will only process messages and notifications
  (_, (_smpCorrId, _qId, _cmdOrErr)) <- atomically $ readTBQueue respQ
  return ()
