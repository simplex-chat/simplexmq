{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Agent (runSMPAgent) where

import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Simplex.Messaging.Agent.Command
import Simplex.Messaging.Agent.Env
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
receive h AgentClient {rcvQ} = forever $ do
  cmdOrError <- aCmdGet SUser h
  atomically $ writeTBQueue rcvQ cmdOrError

send :: MonadUnliftIO m => Handle -> AgentClient -> m ()
send h AgentClient {sndQ} = forever $ do
  cmd <- atomically $ readTBQueue sndQ
  putLn h $ serializeCommand cmd

process :: MonadUnliftIO m => AgentClient -> m ()
process AgentClient {rcvQ, respQ} = forever $ do
  atomically (readTBQueue rcvQ)
    >>= \case
      Left e -> liftIO $ print e
      Right cmd -> liftIO $ print cmd
  atomically $ writeTBQueue respQ ()

respond :: MonadUnliftIO m => AgentClient -> m ()
respond AgentClient {respQ, sndQ} = forever . atomically $ do
  readTBQueue respQ
  writeTBQueue sndQ $ ERR UNKNOWN
