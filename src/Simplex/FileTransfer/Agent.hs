{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.FileTransfer.Agent
  ( startWorkers,
    deleteRcvFilesExpired,
    closeXFTPAgent,
    toFSFilePath,
    -- Receiving files
    receiveFile,
    deleteRcvFile,
    -- Sending files
    sendFileExperimental,
    _sendFile,
  )
where

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple (logError)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:))
import Data.Int (Int64)
import Data.List (foldl', isSuffixOf, partition)
import Data.List.NonEmpty (nonEmpty)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Simplex.FileTransfer.Client.Main (CLIError, SendOptions (..), cliSendFileOpts)
import Simplex.FileTransfer.Crypto
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), FilePartyI)
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.FileTransfer.Types
import Simplex.FileTransfer.Util (removePath, uniqueCombine)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EntityId, XFTPServer, XFTPServerWithAuth)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (liftError, liftIOEither, tshow)
import System.FilePath (takeFileName, (</>))
import UnliftIO
import UnliftIO.Concurrent
import UnliftIO.Directory
import qualified UnliftIO.Exception as E

startWorkers :: AgentMonad m => AgentClient -> Maybe FilePath -> m ()
startWorkers c workDir = do
  wd <- asks $ xftpWorkDir . xftpAgent
  atomically $ writeTVar wd workDir
  startFiles
  where
    startFiles = do
      void . runExceptT $ deleteRcvFilesExpired c `catchError` (liftIO . notify c "" . RFERR)
      pendingRcvServers <- withStore' c getPendingRcvFilesServers
      forM_ pendingRcvServers $ \s -> addXFTPWorker c (Just s)
      -- start local worker for files pending decryption,
      -- no need to make an extra query for the check
      -- as the worker will check the store anyway
      addXFTPWorker c Nothing

deleteRcvFilesExpired :: AgentMonad' m => AgentClient -> ExceptT AgentErrorType m ()
deleteRcvFilesExpired c = do
  rcvExpired <- withStore' c getRcvFilesExpired
  forM_ rcvExpired $ \(dbId, entId, p) -> flip catchError (liftIO . notify c entId . RFERR) $ do
    removePath =<< toFSFilePath p
    withStore' c (`deleteRcvFile'` dbId)

closeXFTPAgent :: MonadUnliftIO m => XFTPAgent -> m ()
closeXFTPAgent XFTPAgent {xftpWorkers} = do
  ws <- atomically $ stateTVar xftpWorkers (,M.empty)
  mapM_ (uninterruptibleCancel . snd) ws

receiveFile :: AgentMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> m RcvFileId
receiveFile c userId (ValidFileDescription fd@FileDescription {chunks}) = do
  g <- asks idsDrg
  workPath <- getWorkPath
  ts <- liftIO getCurrentTime
  let isoTime = formatTime defaultTimeLocale "%Y%m%d_%H%M%S_%6q" ts
  prefixPath <- uniqueCombine workPath (isoTime <> "_rcv.xftp")
  createDirectory prefixPath
  let relPrefixPath = takeFileName prefixPath
      relTmpPath = relPrefixPath </> "xftp.encrypted"
      relSavePath = relPrefixPath </> "xftp.decrypted"
  createDirectory =<< toFSFilePath relTmpPath
  createEmptyFile =<< toFSFilePath relSavePath
  fId <- withStore c $ \db -> createRcvFile db g userId fd relPrefixPath relTmpPath relSavePath
  forM_ chunks downloadChunk
  pure fId
  where
    downloadChunk :: AgentMonad m => FileChunk -> m ()
    downloadChunk FileChunk {replicas = (FileChunkReplica {server} : _)} = do
      addXFTPWorker c (Just server)
    downloadChunk _ = throwError $ INTERNAL "no replicas"

getWorkPath :: AgentMonad m => m FilePath
getWorkPath = do
  workDir <- readTVarIO =<< asks (xftpWorkDir . xftpAgent)
  maybe getTemporaryDirectory pure workDir

toFSFilePath :: AgentMonad m => FilePath -> m FilePath
toFSFilePath f = (</> f) <$> getWorkPath

createEmptyFile :: AgentMonad m => FilePath -> m ()
createEmptyFile fPath = do
  h <- openFile fPath AppendMode
  liftIO $ B.hPut h "" >> hFlush h

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
    agentOperationBracket c AORcvNetwork waitUntilActive runXftpOperation
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    runXftpOperation :: m ()
    runXftpOperation = do
      nextChunk <- withStore' c (`getNextRcvChunkToDownload` srv)
      case nextChunk of
        Nothing -> noWorkToDo
        Just RcvFileChunk {rcvFileId, rcvFileEntityId, fileTmpPath, replicas = []} -> workerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) "chunk has no replicas"
        Just fc@RcvFileChunk {userId, rcvFileId, rcvFileEntityId, fileTmpPath, replicas = replica@RcvFileChunkReplica {rcvChunkReplicaId, delay} : _} -> do
          ri <- asks $ reconnectInterval . config
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryInterval ri' $ \delay' loop ->
            downloadFileChunk fc replica
              `catchError` retryOnError delay' loop (workerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) . show)
          where
            retryOnError :: Int -> m () -> (AgentErrorType -> m ()) -> AgentErrorType -> m ()
            retryOnError replicaDelay loop done e = do
              logError $ "XFTP worker error: " <> tshow e
              if temporaryAgentError e
                then retryLoop
                else done e
              where
                retryLoop = do
                  closeXFTPServerClient c userId replica
                  withStore' c $ \db -> updateRcvChunkReplicaDelay db rcvChunkReplicaId replicaDelay
                  atomically $ endAgentOperation c AORcvNetwork
                  atomically $ throwWhenInactive c
                  atomically $ beginAgentOperation c AORcvNetwork
                  loop
    downloadFileChunk :: RcvFileChunk -> RcvFileChunkReplica -> m ()
    downloadFileChunk RcvFileChunk {userId, rcvFileId, rcvFileEntityId, rcvChunkId, chunkNo, chunkSize, digest, fileTmpPath} replica = do
      fsFileTmpPath <- toFSFilePath fileTmpPath
      chunkPath <- uniqueCombine fsFileTmpPath $ show chunkNo
      let chunkSpec = XFTPRcvChunkSpec chunkPath (unFileSize chunkSize) (unFileDigest digest)
          relChunkPath = fileTmpPath </> takeFileName chunkPath
      agentXFTPDownloadChunk c userId replica chunkSpec
      (complete, progress) <- withStore c $ \db -> runExceptT $ do
        RcvFile {size = FileSize total, chunks} <-
          ExceptT $ updateRcvFileChunkReceived db (rcvChunkReplicaId replica) rcvChunkId rcvFileId relChunkPath
        let rcvd = receivedSize chunks
            complete = all chunkReceived chunks
        liftIO . when complete $ updateRcvFileStatus db rcvFileId RFSReceived
        pure (complete, RFPROG rcvd total)
      liftIO $ notify c rcvFileEntityId progress
      when complete $ addXFTPWorker c Nothing
      where
        receivedSize :: [RcvFileChunk] -> Int64
        receivedSize = foldl' (\sz ch -> sz + receivedChunkSize ch) 0
        receivedChunkSize ch@RcvFileChunk {chunkSize = s}
          | chunkReceived ch = fromIntegral (unFileSize s)
          | otherwise = 0
        chunkReceived RcvFileChunk {replicas} = any received replicas

workerInternalError :: AgentMonad m => AgentClient -> DBRcvFileId -> RcvFileId -> Maybe FilePath -> String -> m ()
workerInternalError c rcvFileId rcvFileEntityId tmpPath internalErrStr = do
  forM_ tmpPath (removePath <=< toFSFilePath)
  withStore' c $ \db -> updateRcvFileError db rcvFileId internalErrStr
  notifyInternalError c rcvFileEntityId internalErrStr

notifyInternalError :: (MonadUnliftIO m) => AgentClient -> RcvFileId -> String -> m ()
notifyInternalError AgentClient {subQ} rcvFileEntityId internalErrStr = atomically $ writeTBQueue subQ ("", rcvFileEntityId, APC SAERcvFile $ RFERR $ INTERNAL internalErrStr)

runXFTPLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPLocalWorker c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    -- TODO agentOperationBracket?
    runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      nextFile <- withStore' c getNextRcvFileToDecrypt
      case nextFile of
        Nothing -> noWorkToDo
        Just f@RcvFile {rcvFileId, rcvFileEntityId, tmpPath} ->
          decryptFile f `catchError` (workerInternalError c rcvFileId rcvFileEntityId tmpPath . show)
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    decryptFile :: RcvFile -> m ()
    decryptFile RcvFile {rcvFileId, rcvFileEntityId, key, nonce, tmpPath, savePath, chunks} = do
      fsSavePath <- toFSFilePath savePath
      -- TODO test; recreate file if it's in status RFSDecrypting
      -- when (status == RFSDecrypting) $
      --   whenM (doesFileExist fsSavePath) (removeFile fsSavePath >> createEmptyFile fsSavePath)
      withStore' c $ \db -> updateRcvFileStatus db rcvFileId RFSDecrypting
      chunkPaths <- getChunkPaths chunks
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      void $ liftError (INTERNAL . show) $ decryptChunks encSize chunkPaths key nonce $ \_ -> pure fsSavePath
      forM_ tmpPath (removePath <=< toFSFilePath)
      withStore' c (`updateRcvFileComplete` rcvFileId)
      liftIO $ notify c rcvFileEntityId $ RFDONE fsSavePath
      where
        getChunkPaths :: [RcvFileChunk] -> m [FilePath]
        getChunkPaths [] = pure []
        getChunkPaths (RcvFileChunk {chunkTmpPath = Just path} : cs) = do
          ps <- getChunkPaths cs
          fsPath <- toFSFilePath path
          pure $ fsPath : ps
        getChunkPaths (RcvFileChunk {chunkTmpPath = Nothing} : _cs) =
          throwError $ INTERNAL "no chunk path"

deleteRcvFile :: AgentMonad m => AgentClient -> UserId -> RcvFileId -> m ()
deleteRcvFile c userId rcvFileEntityId = do
  RcvFile {rcvFileId, prefixPath, status} <- withStore c $ \db -> getRcvFileByEntityId db userId rcvFileEntityId
  if status == RFSComplete || status == RFSError
    then do
      removePath prefixPath
      withStore' c (`deleteRcvFile'` rcvFileId)
    else withStore' c (`updateRcvFileDeleted` rcvFileId)

sendFileExperimental :: forall m. AgentMonad m => AgentClient -> UserId -> FilePath -> Int -> m SndFileId
sendFileExperimental c@AgentClient {xftpServers} userId filePath numRecipients = do
  g <- asks idsDrg
  sndFileId <- liftIO $ randomId g 12
  xftpSrvs <- atomically $ TM.lookup userId xftpServers
  void $ forkIO $ sendCLI sndFileId $ maybe [] L.toList xftpSrvs
  pure sndFileId
  where
    randomId :: TVar ChaChaDRG -> Int -> IO ByteString
    randomId gVar n = U.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)
    sendCLI :: SndFileId -> [XFTPServerWithAuth] -> m ()
    sendCLI sndFileId xftpSrvs = do
      let fileName = takeFileName filePath
      workPath <- getWorkPath
      outputDir <- uniqueCombine workPath $ fileName <> ".descr"
      createDirectory outputDir
      let tempPath = workPath </> "snd"
      createDirectoryIfMissing False tempPath
      let sendOptions =
            SendOptions
              { filePath,
                outputDir = Just outputDir,
                numRecipients,
                xftpServers = xftpSrvs,
                retryCount = 3,
                tempPath = Just tempPath,
                verbose = False
              }
      liftCLI $ cliSendFileOpts sendOptions False $ notify c sndFileId .: SFPROG
      (sndDescr, rcvDescrs) <- readDescrs outputDir fileName
      removePath tempPath
      removePath outputDir
      liftIO $ notify c sndFileId $ SFDONE sndDescr rcvDescrs
    liftCLI :: ExceptT CLIError IO () -> m ()
    liftCLI = either (throwError . INTERNAL . show) pure <=< liftIO . runExceptT
    readDescrs :: FilePath -> FilePath -> m (ValidFileDescription 'FSender, [ValidFileDescription 'FRecipient])
    readDescrs outDir fileName = do
      let descrDir = outDir </> (fileName <> ".xftp")
      files <- listDirectory descrDir
      let (sdFiles, rdFiles) = partition ("snd.xftp.private" `isSuffixOf`) files
          sdFile = maybe "" (\l -> descrDir </> L.head l) (nonEmpty sdFiles)
          rdFiles' = map (descrDir </>) rdFiles
      (,) <$> readDescr sdFile <*> mapM readDescr rdFiles'
    readDescr :: FilePartyI p => FilePath -> m (ValidFileDescription p)
    readDescr f = liftIOEither $ first INTERNAL . strDecode <$> B.readFile f

notify :: forall e. AEntityI e => AgentClient -> EntityId -> ACommand 'Agent e -> IO ()
notify c entId cmd = atomically $ writeTBQueue (subQ c) ("", entId, APC (sAEntity @e) cmd)

-- _sendFile :: AgentMonad m => AgentClient -> UserId -> FilePath -> Int -> m SndFileId
_sendFile :: AgentClient -> UserId -> FilePath -> Int -> m SndFileId
_sendFile _c _userId _filePath _numRecipients = do
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
