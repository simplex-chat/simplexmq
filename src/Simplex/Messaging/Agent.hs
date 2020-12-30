{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent (runSMPAgent) where

import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import Data.Int
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.ServerClient (ServerClient (..), newServerClient)
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Server.Transmission (Cmd (..), CorrId (..), SParty (..))
import qualified Simplex.Messaging.Server.Transmission as SMP
import Simplex.Messaging.Transport
import UnliftIO.Async
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

runSMPAgent :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> m ()
runSMPAgent cfg@AgentConfig {tcpPort} = do
  env <- newEnv cfg
  runReaderT smpAgent env
  where
    smpAgent :: (MonadUnliftIO m, MonadReader Env m) => m ()
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

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => AgentClient -> m ()
client AgentClient {rcvQ, sndQ, respQ, servers, commands} = forever $ do
  t@(corrId, cAlias, cmd) <- atomically $ readTBQueue rcvQ
  processCommand t cmd >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()
  where
    handler :: SomeException -> m (Either StoreError Int64)
    handler e = do
      liftIO (print e)
      return $ Right 1

    processCommand :: ATransmission 'Client -> ACommand 'Client -> m (Either ErrorType ())
    processCommand t = \case
      NEW server@SMPServer {host, port, keyHash} (AckMode mode) -> do
        cfg <- asks $ smpConfig . config
        maybeServer <- atomically $ M.lookup (host, fromMaybe "5223" port) <$> readTVar servers
        srv <- case maybeServer of
          Nothing -> do
            conn <- asks db
            _serverId <- addServer conn server `catch` handler
            newServerClient cfg respQ host port
          Just s -> return s
        _t <- mkSmpNEW t
        atomically $ writeTBQueue (smpSndQ srv) _t
        liftIO $ putStrLn "sending NEW to server"
        liftIO $ print t
        return $ Right ()
      _ -> return $ Left PROHIBITED

    mkSmpNEW :: ATransmission 'Client -> m SMP.Transmission
    mkSmpNEW t = do
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
      atomically . modifyTVar commands $ M.insert smpCorrId req
      return toSMP

processSmp :: MonadUnliftIO m => AgentClient -> m ()
processSmp AgentClient {respQ, sndQ, commands} = forever $ do
  (_, (smpCorrId, qId, cmdOrErr)) <- atomically $ readTBQueue respQ
  liftIO $ putStrLn "received from server"
  liftIO $ print (smpCorrId, qId, cmdOrErr)
  req <- atomically $ M.lookup smpCorrId <$> readTVar commands
  atomically $ case req of -- TODO empty correlation ID is ok - it can be a message
    Nothing -> writeTBQueue sndQ ("", "", ERR $ SMP smpErrCorrelationId)
    Just Request {fromClient = (corrId, cAlias, cmd), toSMP, state} -> do
      writeTBQueue sndQ (corrId, cAlias, ERR UNKNOWN)
