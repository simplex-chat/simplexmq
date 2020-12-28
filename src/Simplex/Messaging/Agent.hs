{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent (runSMPAgent) where

import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
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
runClient c = race_ (respond c) (process c)

receive :: MonadUnliftIO m => Handle -> AgentClient -> m ()
receive h AgentClient {rcvQ, sndQ} = forever $ do
  aCmdGet SClient h >>= \case
    Right cmd -> atomically $ writeTBQueue rcvQ cmd
    Left e -> atomically $ writeTBQueue sndQ $ ERR e

send :: MonadUnliftIO m => Handle -> AgentClient -> m ()
send h AgentClient {sndQ} = forever $ do
  cmd <- atomically $ readTBQueue sndQ
  putLn h $ serializeCommand cmd

process :: MonadUnliftIO m => AgentClient -> m ()
process AgentClient {rcvQ, respQ} = forever $ do
  cmd <- atomically (readTBQueue rcvQ)
  liftIO $ print cmd
  atomically $ writeTBQueue respQ ()

respond :: MonadUnliftIO m => AgentClient -> m ()
respond AgentClient {respQ, sndQ} = forever . atomically $ do
  readTBQueue respQ
  writeTBQueue sndQ $ ERR UNKNOWN
