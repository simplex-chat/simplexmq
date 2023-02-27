{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Supervisor
  ( receiveFile,
  )
where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.FileTransfer.Types
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (INTERNAL))
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Protocol (XFTPServer)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO
import qualified UnliftIO.Exception as E

receiveFile :: AgentMonad m => AgentClient -> FileDescription 'FPRecipient -> m ()
receiveFile c fd@FileDescription {chunks} = do
  withStore' c (`createRcvFile` fd)
  forM_ chunks downloadChunk
  where
    downloadChunk :: AgentMonad m => FileChunk -> m ()
    downloadChunk FileChunk {replicas = (FileChunkReplica {server} : _)} = do
      -- createRcvFileAction
      addWorker c (Just server)
    downloadChunk _ = throwError $ INTERNAL "no replicas"

addWorker :: AgentMonad m => AgentClient -> Maybe XFTPServer -> m ()
addWorker c srv_ = do
  ws <- asks $ xftpWorkers . xftpSupervisor
  atomically (TM.lookup srv_ ws) >>= \case
    Nothing -> do
      doWork <- newTMVarIO ()
      let runWorker = case srv_ of
            Just srv -> runXFTPWorker c srv doWork
            Nothing -> runXFTPLocalWorker c doWork
      worker <- async $ runWorker `E.finally` atomically (TM.delete srv_ ws)
      atomically $ TM.insert srv_ (doWork, worker) ws
    Just (doWork, _) ->
      void . atomically $ tryPutTMVar doWork ()

runXFTPWorker :: forall m. AgentMonad m => AgentClient -> XFTPServer -> TMVar () -> m ()
runXFTPWorker c srv doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AORcvNetwork throwWhenInactive runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      nextFile <- withStore' c (`getNextRcvXFTPAction` srv)
      case nextFile of
        Nothing -> noWorkToDo
        Just a@(fd@RcvFileDescription {}, _) -> do
          aCfg <- asks (config :: Env -> AgentConfig)
          let savedDelay = 1000000 -- next delay saved on chunk
              ari = reconnectInterval (aCfg :: AgentConfig)
              ri = ari {initialInterval = savedDelay}
          withRetryInterval ri $ \loop ->
            processAction a
              `catchError` const loop -- filter errors
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    processAction :: (RcvFileDescription, XFTPAction) -> m ()
    processAction (rcvFile, action) = do
      case action of
        XADownloadChunk -> do
          -- downloadFileChunk -- ? which chunk to download? read encoded / parameterized XFTPAction instead?
          undefined
    downloadFileChunk :: FileChunk -> m ()
    downloadFileChunk chunk = do
      -- generate chunk spec? offset is not needed if chunks are saved into separate files
      -- download chunk
      -- save chunk
      -- update chunk status - returns updated file description
      -- should chunk acknowledgement be scheduled as a separate action?
      --   or check if chunk is downloaded and not acknowledged via flag acknowledged
      -- if all chunks are received, create task to decrypt file / or decrypt in same worker?
      undefined

runXFTPLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPLocalWorker c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AODatabase throwWhenInactive runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      -- nextFile <- withStore' c getNextRcvXFTPLocalAction -- TODO in AgentMonad
      let nextFile = Nothing
      case nextFile of
        Nothing -> noWorkToDo
        Just a@(fd@RcvFileDescription {}, _) -> do
          -- ri <- asks $ reconnectInterval . config
          let savedDelay = 1000000 -- next delay saved on chunk
              ri = defaultReconnectInterval {initialInterval = savedDelay}
          withRetryInterval ri $ \loop ->
            processAction a
              `catchError` const loop -- filter errors
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    processAction :: (RcvFileDescription, XFTPLocalAction) -> m ()
    processAction (rcvFile, action) = do
      case action of
        XALDecrypt -> undefined
