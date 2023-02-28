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
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.FileTransfer.Types
import Simplex.FileTransfer.Util (uniqueCombine)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol (AgentErrorType (INTERNAL))
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Protocol (XFTPServer)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO
import UnliftIO.Directory
import qualified UnliftIO.Exception as E

receiveFile :: AgentMonad m => AgentClient -> FileDescription 'FPRecipient -> FilePath -> m ()
receiveFile c fd@FileDescription {chunks} xftpPath = do
  encPath <- uniqueCombine xftpPath "xftp.encrypted"
  createDirectory encPath
  withStore' c $ \db -> createRcvFile db fd encPath
  forM_ chunks downloadChunk
  where
    downloadChunk :: AgentMonad m => FileChunk -> m ()
    downloadChunk FileChunk {replicas = (FileChunkReplica {server} : _)} = do
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
      nextChunk <- withStore' c (`getNextRcvChunkToDownload` srv)
      case nextChunk of
        Nothing -> noWorkToDo
        Just fc@RcvFileChunk {nextDelay} -> do
          ari <- asks $ reconnectInterval . config
          let ri = maybe ari (\d -> ari {initialInterval = d}) nextDelay
          withRetryInterval ri $ \loop ->
            downloadFileChunk fc
              `catchError` \_ -> do
                -- TODO don't loop on permanent errors
                -- TODO increase replica retries count
                -- TODO update nextDelay
                loop
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    downloadFileChunk :: RcvFileChunk -> m ()
    downloadFileChunk RcvFileChunk {rcvFileChunkId, chunkNo, chunkSize, digest, fileTmpPath, replicas = replica : _} = do
      let RcvFileChunkReplica {rcvFileChunkReplicaId, replicaId, replicaKey} = replica
      chunkPath <- uniqueCombine fileTmpPath $ show chunkNo
      let chunkSpec = XFTPRcvChunkSpec chunkPath (unFileSize chunkSize) (unFileDigest digest)
      agentXFTPDownloadChunk c replicaKey (unChunkReplicaId replicaId) chunkSpec
      withStore' c $ \db -> updateRcvFileChunkReceived db rcvFileChunkReplicaId rcvFileChunkId chunkPath
      -- check if chunk is downloaded and not acknowledged via flag acknowledged?
      -- or just catch and ignore error on acknowledgement? (and remove flag)
      agentXFTPAckChunk c replicaKey (unChunkReplicaId replicaId)
    -- TODO if all chunks are received, kick local worker to start decryption
    downloadFileChunk _ = throwError $ INTERNAL "no replica"

runXFTPLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPLocalWorker c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AODatabase throwWhenInactive runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      nextFile <- withStore' c getNextRcvFileToDecrypt -- TODO in AgentMonad
      case nextFile of
        Nothing -> noWorkToDo
        Just fd -> do
          -- ri <- asks $ reconnectInterval . config
          let savedDelay = 1000000 -- next delay saved on chunk
              ri = defaultReconnectInterval {initialInterval = savedDelay}
          withRetryInterval ri $ \loop ->
            decryptFile fd
              `catchError` const loop -- filter errors
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    decryptFile :: RcvFileDescription -> m ()
    decryptFile fd = do
      -- decrypt file
      -- update file status
      undefined
