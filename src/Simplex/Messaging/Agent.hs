{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
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
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (Cmd (..), CorrId (..), SParty (..))
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import UnliftIO.Async
import UnliftIO.Exception (Exception, SomeException)
import qualified UnliftIO.Exception as E
import UnliftIO.IO
import UnliftIO.STM

instance (MonadUnliftIO m, Exception e) => MonadUnliftIO (ExceptT e m) where
  withRunInIO inner = ExceptT . E.try $
    withRunInIO $ \run ->
      inner (run . (either E.throwIO pure <=< runExceptT))

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
  t@(corrId, cAlias, cmd) <- atomically $ readTBQueue rcvQ
  runExceptT (processCommand c t cmd) >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()

processCommand :: forall m. (MonadUnliftIO m, MonadReader Env m, MonadError ErrorType m) => AgentClient -> ATransmission 'Client -> ACommand 'Client -> m ()
processCommand AgentClient {respQ, servers, commands} t = \case
  NEW smpServer _ -> do
    srv <- getSMPServer smpServer
    smpT <- mkSmpNEW
    atomically $ writeTBQueue (smpSndQ srv) smpT
    return ()
  _ -> throwError PROHIBITED
  where
    replyError :: ErrorType -> SomeException -> m a
    replyError err e = do
      liftIO . putStrLn $ "Exception: " ++ show e -- TODO remove
      throwError err

    getSMPServer :: SMPServer -> m ServerClient
    getSMPServer s@SMPServer {host, port} = do
      defPort <- asks $ smpTcpPort . config
      let p = fromMaybe defPort port
      atomically (M.lookup (host, p) <$> readTVar servers)
        >>= maybe (newSMPServer s host p) return

    newSMPServer :: SMPServer -> HostName -> ServiceName -> m ServerClient
    newSMPServer s host port = do
      cfg <- asks $ smpConfig . config
      store <- asks db
      _serverId <- addServer store s `E.catch` replyError INTERNAL
      srv <- newServerClient cfg respQ host port `E.catch` replyError (BROKER smpErrTCPConnection)
      atomically . modifyTVar servers $ M.insert (host, port) srv
      return srv

    mkSmpNEW :: m SMP.Transmission
    mkSmpNEW = do
      g <- asks idsDrg
      smpCorrId <- atomically $ CorrId <$> randomBytes 4 g
      recipientKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
      let recipientPrivateKey = recipientKey
          toSMP = ("", (smpCorrId, "", Cmd SRecipient $ SMP.NEW recipientKey))
          req =
            Request
              { fromClient = t,
                toSMP,
                state = NEWRequestState {recipientKey, recipientPrivateKey}
              }
      atomically . modifyTVar commands $ M.insert smpCorrId req -- TODO check ID collision
      return toSMP

processSmp :: forall m. (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
processSmp AgentClient {respQ, sndQ, commands} = forever $ do
  (_, (smpCorrId, qId, cmdOrErr)) <- atomically $ readTBQueue respQ
  liftIO $ putStrLn "received from server" -- TODO remove
  liftIO $ print (smpCorrId, qId, cmdOrErr)
  req <- atomically $ M.lookup smpCorrId <$> readTVar commands
  case req of -- TODO empty correlation ID is ok - it can be a message
    Nothing -> atomically $ writeTBQueue sndQ ("", "", ERR $ BROKER smpErrCorrelationId)
    Just r -> processResponse r cmdOrErr
  where
    processResponse :: Request -> Either SMP.ErrorType SMP.Cmd -> m ()
    processResponse Request {fromClient = (corrId, cAlias, cmd), toSMP = (_, (_, _, smpCmd)), state} cmdOrErr = do
      case cmdOrErr of
        Left e -> respond $ ERR (SMP e)
        Right resp -> case resp of
          Cmd SBroker (SMP.IDS recipientId senderId) -> case smpCmd of
            Cmd SRecipient (SMP.NEW _) -> case (cmd, state) of
              (NEW _ _, NEWRequestState {recipientKey, recipientPrivateKey}) -> do
                -- TODO all good - process response
                respond $ ERR UNKNOWN
              _ -> respond $ ERR INTERNAL
            _ -> respond $ ERR (BROKER smpUnexpectedResponse)
          _ -> respond $ ERR UNSUPPORTED
      where
        respond :: ACommand 'Agent -> m ()
        respond c = atomically $ writeTBQueue sndQ (corrId, cAlias, c)
