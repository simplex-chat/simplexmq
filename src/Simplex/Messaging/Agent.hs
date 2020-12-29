{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent (runSMPAgent) where

import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Server.Transmission (CorrId (..))
import Simplex.Messaging.Transport
import UnliftIO.Async
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

runClient :: MonadUnliftIO m => AgentClient -> m ()
runClient c = race_ (processSmp c) (client c)

receive :: MonadUnliftIO m => Handle -> AgentClient -> m ()
receive h AgentClient {rcvQ, sndQ} =
  forever $
    tGet SClient h >>= \(corrId, cAlias, command) -> atomically $ case command of
      Right cmd -> writeTBQueue rcvQ (corrId, cAlias, cmd)
      Left e -> writeTBQueue sndQ (corrId, cAlias, ERR e)

send :: MonadUnliftIO m => Handle -> AgentClient -> m ()
send h AgentClient {sndQ} = forever $ atomically (readTBQueue sndQ) >>= tPut h

client :: forall m. MonadUnliftIO m => AgentClient -> m ()
client AgentClient {rcvQ, sndQ} = forever $ do
  (corrId, cAlias, cmd) <- atomically (readTBQueue rcvQ)
  processCommand cmd >>= \case
    Left e -> atomically $ writeTBQueue sndQ (corrId, cAlias, ERR e)
    Right _ -> return ()
  where
    processCommand :: ACommand 'Client -> m (Either ErrorType ())
    processCommand _ = return $ Left PROHIBITED

processSmp :: MonadUnliftIO m => AgentClient -> m ()
processSmp AgentClient {respQ, sndQ} = forever . atomically $ do
  readTBQueue respQ
  writeTBQueue sndQ (CorrId B.empty, B.empty, ERR UNKNOWN)
