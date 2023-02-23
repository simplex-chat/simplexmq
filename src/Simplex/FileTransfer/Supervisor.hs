{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Supervisor where

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
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO
import qualified UnliftIO.Exception as E

-- add temporary folder to save files to agent environment

-- can be part of agent
-- Maybe XFTPServer - Nothing is for worker dedicated to file decryption
data XFTPSupervisorEnv = XFTPSupervisorEnv
  { xftpWorkers :: TMap (Maybe XFTPServer) (TMVar (), Async ()),
    xftpAgent :: XFTPClientAgent
  }

-- TODO remove, replace uses with AgentMonad
type XFTPMonad m = (MonadUnliftIO m, MonadReader XFTPSupervisorEnv m, MonadError AgentErrorType m)

receiveFile :: XFTPMonad m => AgentClient -> FileDescription 'FPRecipient -> m ()
receiveFile c fd@FileDescription {chunks} = do
  -- same as cli: validate file description
  -- createRcvFile
  -- for each chunk create worker task to download and save chunk
  -- worker that successfully receives last chunk should create task to decrypt file
  forM_ chunks downloadChunk
  where
    downloadChunk :: XFTPMonad m => FileChunk -> m ()
    downloadChunk FileChunk {replicas = (FileChunkReplica {server} : _)} = do
      -- createRcvFileAction
      addWorker c (Just server)
    downloadChunk _ = throwError $ INTERNAL "no replicas"

addWorker :: XFTPMonad m => AgentClient -> Maybe XFTPServer -> m ()
addWorker c srv_ = do
  ws <- asks xftpWorkers
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

runXFTPWorker :: forall m. XFTPMonad m => AgentClient -> XFTPServer -> TMVar () -> m ()
runXFTPWorker c srv doWork = do
  xa <- asks xftpAgent
  xc <- liftXFTP $ getXFTPServerClient xa srv
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AORcvNetwork throwWhenInactive (runXftpOperation xc)
  where
    liftXFTP :: ExceptT XFTPClientAgentError IO XFTPClient -> m XFTPClient
    liftXFTP = either (throwError . INTERNAL . show) return <=< liftIO . runExceptT
    runXftpOperation :: XFTPClient -> m ()
    runXftpOperation xc = do
      -- nextFile <- withStore' c (`getNextRcvXFTPAction` srv) -- TODO in AgentMonad
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
    processAction :: (RcvFileDescription, XFTPAction) -> m ()
    processAction (rcvFile, action) = do
      case action of
        XADownloadChunk -> do
          -- downloadFileChunk -- ? which chunk to download? read encoded / parameterized XFTPAction instead?
          undefined
    downloadFileChunk :: XFTPClient -> FileChunk -> m ()
    downloadFileChunk a chunk = do
      -- generate chunk spec? offset is not needed if chunks are saved into separate files
      -- download chunk
      -- save chunk
      -- update chunk status - returns updated file description
      -- should chunk acknowledgement be scheduled as a separate action?
      --   or check if chunk is downloaded and not acknowledged via flag acknowledged
      -- if all chunks are received, create task to decrypt file / or decrypt in same worker?
      undefined

runXFTPLocalWorker :: forall m. XFTPMonad m => AgentClient -> TMVar () -> m ()
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
