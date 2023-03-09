{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Agent
  ( -- Receiving files
    receiveFile,
    addXFTPWorker,
    -- Sending files
    _sendFile,
  )
where

import Control.Logger.Simple (logError)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.FileTransfer.Types
import Simplex.FileTransfer.Util (uniqueCombine)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Agent.Protocol as AP
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol (XFTPServer)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (tshow, whenM)
import UnliftIO
import UnliftIO.Directory
import qualified UnliftIO.Exception as E

receiveFile :: AgentMonad m => AgentClient -> UserId -> ValidFileDescription 'FPRecipient -> FilePath -> m Int64
receiveFile c userId (ValidFileDescription fd@FileDescription {chunks}) xftpPath = do
  encPath <- uniqueCombine xftpPath "xftp.encrypted"
  createDirectory encPath
  fId <- withStore' c $ \db -> createRcvFile db userId fd xftpPath encPath
  forM_ chunks downloadChunk
  pure fId
  where
    downloadChunk :: AgentMonad m => FileChunk -> m ()
    downloadChunk FileChunk {replicas = (FileChunkReplica {server} : _)} = do
      addXFTPWorker c (Just server)
    downloadChunk _ = throwError $ INTERNAL "no replicas"

addXFTPWorker :: AgentMonad m => AgentClient -> Maybe XFTPServer -> m ()
addXFTPWorker c srv_ = do
  ws <- asks $ xftpWorkers . xftpAgent
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
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    runXftpOperation :: m ()
    runXftpOperation = do
      nextChunk <- withStore' c (`getNextRcvChunkToDownload` srv)
      case nextChunk of
        Nothing -> noWorkToDo
        Just RcvFileChunk {rcvFileId, replicas = []} -> workerInternalError c rcvFileId "chunk has no replicas"
        Just fc@RcvFileChunk {rcvFileId, rcvChunkId, delay, replicas = replica@RcvFileChunkReplica {rcvChunkReplicaId} : _} -> do
          ri <- asks $ reconnectInterval . config
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryInterval ri' $ \delay' loop ->
            downloadFileChunk fc replica
              `catchError` retryOnError delay' loop (workerInternalError c rcvFileId . show)
          where
            retryOnError :: Int -> m () -> (AgentErrorType -> m ()) -> AgentErrorType -> m ()
            retryOnError chunkDelay loop done e = do
              logError $ "XFTP worker error: " <> tshow e
              case e of
                BROKER _ NETWORK -> retryLoop
                BROKER _ TIMEOUT -> retryLoop
                _ -> done e
              where
                retryLoop = do
                  withStore' c $ \db -> do
                    updateRcvFileChunkDelay db rcvChunkId chunkDelay
                    increaseRcvChunkReplicaRetries db rcvChunkReplicaId
                  atomically $ endAgentOperation c AORcvNetwork
                  atomically $ throwWhenInactive c
                  atomically $ beginAgentOperation c AORcvNetwork
                  loop
    downloadFileChunk :: RcvFileChunk -> RcvFileChunkReplica -> m ()
    downloadFileChunk RcvFileChunk {userId, rcvFileId, rcvChunkId, chunkNo, chunkSize, digest, fileTmpPath} replica = do
      chunkPath <- uniqueCombine fileTmpPath $ show chunkNo
      let chunkSpec = XFTPRcvChunkSpec chunkPath (unFileSize chunkSize) (unFileDigest digest)
      agentXFTPDownloadChunk c userId replica chunkSpec
      fileReceived <- withStore c $ \db -> runExceptT $ do
        -- both actions can be done in a single store method
        f <- ExceptT $ updateRcvFileChunkReceived db (rcvChunkReplicaId replica) rcvChunkId rcvFileId chunkPath
        let fileReceived = allChunksReceived f
        when fileReceived $
          liftIO $ updateRcvFileStatus db rcvFileId RFSReceived
        pure fileReceived
      -- check if chunk is downloaded and not acknowledged via flag acknowledged?
      -- or just catch and ignore error on acknowledgement? (and remove flag)
      -- agentXFTPAckChunk c replicaKey (unChunkReplicaId replicaId) `catchError` \_ -> pure ()
      when fileReceived $ addXFTPWorker c Nothing
      where
        allChunksReceived :: RcvFile -> Bool
        allChunksReceived RcvFile {chunks} =
          all (\RcvFileChunk {replicas} -> any received replicas) chunks

workerInternalError :: AgentMonad m => AgentClient -> RcvFileId -> String -> m ()
workerInternalError c rcvFileId internalErrStr = do
  withStore' c $ \db -> updateRcvFileError db rcvFileId internalErrStr
  notifyInternalError c rcvFileId internalErrStr

notifyInternalError :: (MonadUnliftIO m) => AgentClient -> RcvFileId -> String -> m ()
notifyInternalError AgentClient {subQ} rcvFileId internalErrStr = atomically $ writeTBQueue subQ ("", "", AP.FRCVERR rcvFileId $ AP.INTERNAL internalErrStr)

runXFTPLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPLocalWorker c@AgentClient {subQ} doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      nextFile <- withStore' c getNextRcvFileToDecrypt
      case nextFile of
        Nothing -> noWorkToDo
        Just f@RcvFile {rcvFileId} ->
          decryptFile f `catchError` (workerInternalError c rcvFileId . show)
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    decryptFile :: RcvFile -> m ()
    decryptFile RcvFile {rcvFileId, key, nonce, tmpPath, saveDir, chunks} = do
      -- TODO remove tmpPath if exists
      withStore' c $ \db -> updateRcvFileStatus db rcvFileId RFSDecrypting
      chunkPaths <- getChunkPaths chunks
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      path <- decrypt encSize chunkPaths
      whenM (doesPathExist tmpPath) $ removeDirectoryRecursive tmpPath
      withStore' c $ \db -> updateRcvFileComplete db rcvFileId path
      notify $ FRCVD rcvFileId path
      where
        notify :: ACommand 'Agent -> m ()
        notify cmd = atomically $ writeTBQueue subQ ("", "", cmd)
        getChunkPaths :: [RcvFileChunk] -> m [FilePath]
        getChunkPaths [] = pure []
        getChunkPaths (RcvFileChunk {chunkTmpPath = Just path} : cs) = do
          ps <- getChunkPaths cs
          pure $ path : ps
        getChunkPaths (RcvFileChunk {chunkTmpPath = Nothing} : _cs) =
          throwError $ INTERNAL "no chunk path"
        decrypt :: Int64 -> [FilePath] -> m FilePath
        decrypt encSize chunkPaths = do
          lazyChunks <- readChunks chunkPaths
          (authOk, f) <- liftEither . first cryptoError $ LC.sbDecryptTailTag key nonce (encSize - authTagSize) lazyChunks
          let (fileHdr, f') = LB.splitAt 1024 f
          -- withFile encPath ReadMode $ \r -> do
          --   fileHdr <- liftIO $ B.hGet r 1024
          case A.parse smpP $ LB.toStrict fileHdr of
            -- TODO XFTP errors
            A.Fail _ _ e -> throwError $ INTERNAL $ "Invalid file header: " <> e
            A.Partial _ -> throwError $ INTERNAL "Invalid file header"
            A.Done rest FileHeader {fileName} -> do
              -- TODO touch file in agent bracket
              path <- uniqueCombine saveDir fileName
              liftIO $ LB.writeFile path $ LB.fromStrict rest <> f'
              unless authOk $ do
                removeFile path
                throwError $ INTERNAL "Error decrypting file: incorrect auth tag"
              pure path
        readChunks :: [FilePath] -> m LB.ByteString
        readChunks =
          foldM
            ( \s path -> do
                chunk <- liftIO $ LB.readFile path
                pure $ s <> chunk
            )
            LB.empty

-- _sendFile :: AgentMonad m => AgentClient -> UserId -> FilePath -> FilePath -> m Int64
_sendFile :: AgentClient -> UserId -> FilePath -> FilePath -> m Int64
_sendFile _c _userId _xftpPath _filePath = do
  -- db: create file in status New without chunks
  -- add local snd worker for encryption
  -- return file id to client
  undefined

_runXFTPSndLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
_runXFTPSndLocalWorker _c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      -- db: get next snd file to encrypt (in status New)
      -- ? (or Encrypted to retry create? - see below)
      -- with fixed retries (?) encryptFile
      undefined
    _encryptFile :: SndFile -> m ()
    _encryptFile _sndFile = do
      -- if enc path exists, remove it
      -- if enc path doesn't exist:
      --   - choose enc path
      --   - touch file, db: update enc path (?)
      -- calculate chunk sizes, encrypt file to enc path
      -- calculate digest
      -- prepare chunk specs
      -- db:
      --   - update file status to Encrypted
      --   - create chunks according to chunk specs
      -- ? since which servers are online is unknown,
      -- ? we can't blindly assign servers to replicas.
      -- ? should we XFTP create chunks on servers here,
      -- ? with retrying for different servers,
      -- ? keeping a list of servers that were tried?
      -- ? then we can add replicas to chunks in db
      -- ? and update file status to Uploading,
      -- ? probably in same transaction as creating chunks,
      -- ? and add XFTP snd workers for uploading chunks.
      undefined

_runXFTPSndWorker :: forall m. AgentMonad m => AgentClient -> XFTPServer -> TMVar () -> m ()
_runXFTPSndWorker c _srv doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AOSndNetwork throwWhenInactive runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      -- db: get next snd chunk to upload (replica is not uploaded)
      -- with retry interval uploadChunk
      --   - with fixed retries, repeat N times:
      --     check if other files are in upload, delay (see xftpSndFiles in XFTPAgent)
      undefined
    _uploadFileChunk :: SndFileChunk -> m ()
    _uploadFileChunk _sndFileChunk = do
      -- add file id to xftpSndFiles
      -- XFTP upload chunk
      -- db: update replica status to Uploaded, return SndFile
      -- if all SndFile's replicas are uploaded:
      --   - serialize file descriptions and notify client
      --   - remove file id from xftpSndFiles
      undefined
