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
import Data.Maybe
import Network.Socket
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.ServerClient (ServerClient (..), newServerClient)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Agent.Store.Types
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (Cmd (..), CorrId (..), PublicKey, SParty (..))
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
      putLn h "Welcome to SMP Agent v0.1"
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
processCommand AgentClient {respQ, servers, commands} t@(_, connAlias, cmd) =
  case cmd of
    NEW smpServer -> do
      srv <- getSMPServer smpServer
      smpT <- mkSmpNEW smpServer
      atomically $ writeTBQueue (smpSndQ srv) smpT
      return ()
    JOIN (SMPQueueInfo smpServer senderId encKey) _ -> do
      srv <- getSMPServer smpServer
      smpT <- mkConfSEND smpServer senderId encKey
      atomically $ writeTBQueue (smpSndQ srv) smpT
      return ()
    _ -> throwError PROHIBITED
  where
    replyError :: ErrorType -> SomeException -> m a
    replyError err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err

    getSMPServer :: SMPServer -> m ServerClient
    getSMPServer SMPServer {host, port} = do
      defPort <- asks $ smpTcpPort . config
      let p = fromMaybe defPort port
      atomically (M.lookup (host, p) <$> readTVar servers)
        >>= maybe (newSMPServer host p) return

    newSMPServer :: HostName -> ServiceName -> m ServerClient
    newSMPServer host port = do
      cfg <- asks $ smpConfig . config
      -- store <- asks db
      -- _serverId <- withStore (addServer store s) `E.catch` replyError INTERNAL
      srv <- newServerClient cfg respQ host port `E.catch` replyError (BROKER smpErrTCPConnection)
      atomically . modifyTVar servers $ M.insert (host, port) srv
      return srv

    mkSmpNEW :: SMPServer -> m SMP.Transmission
    mkSmpNEW smpServer = do
      g <- asks idsDrg
      smpCorrId <- atomically $ CorrId <$> randomBytes 4 g
      recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      let rcvPrivateKey = recipientKey
          toSMP = ("", (smpCorrId, "", Cmd SRecipient $ SMP.NEW recipientKey))
          req =
            Request
              { fromClient = t,
                toSMP,
                state = NEWRequestState {connAlias, smpServer, rcvPrivateKey}
              }
      atomically . modifyTVar commands $ M.insert smpCorrId req -- TODO check ID collision
      return toSMP

    mkConfSEND :: SMPServer -> SMP.SenderId -> PublicKey -> m SMP.Transmission
    mkConfSEND smpServer senderId encKey = do
      g <- asks idsDrg
      smpCorrId <- atomically $ CorrId <$> randomBytes 4 g
      senderKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      -- TODO create connection with NEW status, it will be upgraded to CONFIRMED status once SMP server replies OK to SEND
      msg <- mkConfirmation encKey senderKey
      let sndPrivateKey = senderKey
          toSMP = ("", (smpCorrId, senderId, Cmd SSender $ SMP.SEND msg))
          req =
            Request
              { fromClient = t,
                toSMP,
                state = ConfSENDRequestState {connAlias, smpServer, senderId, sndPrivateKey, encKey}
              }
      atomically . modifyTVar commands $ M.insert smpCorrId req -- TODO check ID collision
      return toSMP

    mkConfirmation :: PublicKey -> PublicKey -> m SMP.MsgBody
    mkConfirmation _encKey senderKey = do
      let msg = "KEY " <> senderKey <> "\r\n\r\n"
      -- TODO encryption
      return msg

processSmp :: forall m. (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
processSmp c@AgentClient {respQ, sndQ, commands} = forever $ do
  (_, (smpCorrId, qId, cmdOrErr)) <- atomically $ readTBQueue respQ
  liftIO $ putStrLn "received from server" -- TODO remove
  liftIO $ print (smpCorrId, qId, cmdOrErr)
  req <- atomically $ M.lookup smpCorrId <$> readTVar commands
  case req of -- TODO empty correlation ID is ok - it can be a message
    Nothing -> atomically $ writeTBQueue sndQ ("", "", ERR $ BROKER smpErrCorrelationId)
    Just r@Request {fromClient = (corrId, cAlias, _)} ->
      runExceptT (processResponse c r cmdOrErr) >>= \case
        Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
        Right _ -> return ()

processResponse ::
  forall m.
  (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) =>
  AgentClient ->
  Request ->
  Either SMP.ErrorType SMP.Cmd ->
  m ()
processResponse
  AgentClient {sndQ}
  Request {fromClient = (corrId, cAlias, cmd), toSMP = (_, (_, _, smpCmd)), state}
  cmdOrErr = do
    case cmdOrErr of
      Left e -> throwError $ SMP e
      Right resp -> case resp of
        Cmd SBroker (SMP.IDS recipientId senderId) -> case smpCmd of
          Cmd SRecipient (SMP.NEW _) -> case (cmd, state) of
            (NEW _, NEWRequestState {connAlias, smpServer, rcvPrivateKey}) -> do
              -- TODO all good - process response
              g <- asks idsDrg
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
            _ -> throwError INTERNAL
          _ -> throwError $ BROKER smpUnexpectedResponse
        _ -> throwError UNSUPPORTED
    where
      respond :: ACommand 'Agent -> m ()
      respond c = atomically $ writeTBQueue sndQ (corrId, cAlias, c)
