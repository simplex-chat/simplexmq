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
    closeXFTPAgent,
    toFSFilePath,
    -- Receiving files
    receiveFile,
    deleteRcvFile,
    -- Sending files
    sendFileExperimental,
    sendFile,
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
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Composition ((.:))
import Data.Int (Int64)
import Data.List (foldl', isSuffixOf, partition)
import Data.List.NonEmpty (nonEmpty)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Simplex.FileTransfer.Client (XFTPChunkSpec)
import Simplex.FileTransfer.Client.Main
import Simplex.FileTransfer.Crypto
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileInfo (..), FileParty (..), FilePartyI)
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.FileTransfer.Types
import Simplex.FileTransfer.Util (removePath, uniqueCombine)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EntityId, XFTPServer, XFTPServerWithAuth)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (liftError, liftIOEither, tshow, whenM)
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
      rcvFilesTTL <- asks (rcvFilesTTL . config)
      pendingRcvServers <- withStore' c (`getPendingRcvFilesServers` rcvFilesTTL)
      forM_ pendingRcvServers $ \s -> addXFTPRcvWorker c (Just s)
      -- start local worker for files pending decryption,
      -- no need to make an extra query for the check
      -- as the worker will check the store anyway
      addXFTPRcvWorker c Nothing

closeXFTPAgent :: MonadUnliftIO m => XFTPAgent -> m ()
closeXFTPAgent XFTPAgent {xftpRcvWorkers, xftpSndWorkers} = do
  rws <- atomically $ stateTVar xftpRcvWorkers (,M.empty)
  mapM_ (uninterruptibleCancel . snd) rws
  sws <- atomically $ stateTVar xftpSndWorkers (,M.empty)
  mapM_ (uninterruptibleCancel . snd) sws

receiveFile :: AgentMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> m RcvFileId
receiveFile c userId (ValidFileDescription fd@FileDescription {chunks}) = do
  g <- asks idsDrg
  prefixPath <- getPrefixPath "rcv.xftp"
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
      addXFTPRcvWorker c (Just server)
    downloadChunk _ = throwError $ INTERNAL "no replicas"

getPrefixPath :: AgentMonad m => String -> m FilePath
getPrefixPath suffix = do
  workPath <- getXFTPWorkPath
  ts <- liftIO getCurrentTime
  let isoTime = formatTime defaultTimeLocale "%Y%m%d_%H%M%S_%6q" ts
  uniqueCombine workPath (isoTime <> "_" <> suffix)

toFSFilePath :: AgentMonad m => FilePath -> m FilePath
toFSFilePath f = (</> f) <$> getXFTPWorkPath

createEmptyFile :: AgentMonad m => FilePath -> m ()
createEmptyFile fPath = do
  h <- openFile fPath AppendMode
  liftIO $ B.hPut h "" >> hFlush h

addXFTPRcvWorker :: AgentMonad m => AgentClient -> Maybe XFTPServer -> m ()
addXFTPRcvWorker c = addWorker c xftpRcvWorkers runXFTPRcvWorker runXFTPRcvLocalWorker

addWorker ::
  AgentMonad m =>
  AgentClient ->
  (XFTPAgent -> TMap (Maybe XFTPServer) (TMVar (), Async ())) ->
  (AgentClient -> XFTPServer -> TMVar () -> m ()) ->
  (AgentClient -> TMVar () -> m ()) ->
  Maybe XFTPServer ->
  m ()
addWorker c wsSel runWorker runWorkerNoSrv srv_ = do
  ws <- asks $ wsSel . xftpAgent
  atomically (TM.lookup srv_ ws) >>= \case
    Nothing -> do
      doWork <- newTMVarIO ()
      let runWorker' = case srv_ of
            Just srv -> runWorker c srv doWork
            Nothing -> runWorkerNoSrv c doWork
      worker <- async $ runWorker' `E.finally` atomically (TM.delete srv_ ws)
      atomically $ TM.insert srv_ (doWork, worker) ws
    Just (doWork, _) ->
      void . atomically $ tryPutTMVar doWork ()

runXFTPRcvWorker :: forall m. AgentMonad m => AgentClient -> XFTPServer -> TMVar () -> m ()
runXFTPRcvWorker c srv doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AORcvNetwork waitUntilActive runXftpOperation
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    runXftpOperation :: m ()
    runXftpOperation = do
      rcvFilesTTL <- asks (rcvFilesTTL . config)
      nextChunk <- withStore' c $ \db -> getNextRcvChunkToDownload db srv rcvFilesTTL
      case nextChunk of
        Nothing -> noWorkToDo
        Just RcvFileChunk {rcvFileId, rcvFileEntityId, fileTmpPath, replicas = []} -> rcvWorkerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) "chunk has no replicas"
        Just fc@RcvFileChunk {userId, rcvFileId, rcvFileEntityId, fileTmpPath, replicas = replica@RcvFileChunkReplica {rcvChunkReplicaId, server, replicaId, delay} : _} -> do
          ri <- asks $ reconnectInterval . config
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryInterval ri' $ \delay' loop ->
            downloadFileChunk fc replica
              `catchError` \e -> retryOnError c AORcvNetwork "XFTP rcv worker" loop (retryMaintenance e delay') (retryDone e) e
          where
            retryMaintenance e replicaDelay = do
              notifyOnRetry <- asks (xftpNotifyErrsOnRetry . config)
              when notifyOnRetry $ notify c rcvFileEntityId $ RFERR e
              closeXFTPServerClient c userId server replicaId
              withStore' c $ \db -> updateRcvChunkReplicaDelay db rcvChunkReplicaId replicaDelay
            retryDone e = rcvWorkerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) (show e)
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
      notify c rcvFileEntityId progress
      when complete $ addXFTPRcvWorker c Nothing
      where
        receivedSize :: [RcvFileChunk] -> Int64
        receivedSize = foldl' (\sz ch -> sz + receivedChunkSize ch) 0
        receivedChunkSize ch@RcvFileChunk {chunkSize = s}
          | chunkReceived ch = fromIntegral (unFileSize s)
          | otherwise = 0
        chunkReceived RcvFileChunk {replicas} = any received replicas

retryOnError :: AgentMonad' m => AgentClient -> AgentOperation -> Text -> m () -> m () -> m () -> AgentErrorType -> m ()
retryOnError c agentOp name loop maintenance done e = do
  logError $ name <> " error: " <> tshow e
  if temporaryAgentError e
    then retryLoop
    else done
  where
    retryLoop = do
      maintenance
      atomically $ endAgentOperation c agentOp
      atomically $ throwWhenInactive c
      atomically $ beginAgentOperation c agentOp
      loop

rcvWorkerInternalError :: AgentMonad m => AgentClient -> DBRcvFileId -> RcvFileId -> Maybe FilePath -> String -> m ()
rcvWorkerInternalError c rcvFileId rcvFileEntityId tmpPath internalErrStr = do
  forM_ tmpPath (removePath <=< toFSFilePath)
  withStore' c $ \db -> updateRcvFileError db rcvFileId internalErrStr
  notify c rcvFileEntityId $ RFERR $ INTERNAL internalErrStr

runXFTPRcvLocalWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPRcvLocalWorker c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    -- TODO agentOperationBracket?
    runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      rcvFilesTTL <- asks (rcvFilesTTL . config)
      nextFile <- withStore' c (`getNextRcvFileToDecrypt` rcvFilesTTL)
      case nextFile of
        Nothing -> noWorkToDo
        Just f@RcvFile {rcvFileId, rcvFileEntityId, tmpPath} ->
          decryptFile f `catchError` (rcvWorkerInternalError c rcvFileId rcvFileEntityId tmpPath . show)
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    decryptFile :: RcvFile -> m ()
    decryptFile RcvFile {rcvFileId, rcvFileEntityId, key, nonce, tmpPath, savePath, status, chunks} = do
      fsSavePath <- toFSFilePath savePath
      when (status == RFSDecrypting) $
        whenM (doesFileExist fsSavePath) (removeFile fsSavePath >> createEmptyFile fsSavePath)
      withStore' c $ \db -> updateRcvFileStatus db rcvFileId RFSDecrypting
      chunkPaths <- getChunkPaths chunks
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      void $ liftError (INTERNAL . show) $ decryptChunks encSize chunkPaths key nonce $ \_ -> pure fsSavePath
      notify c rcvFileEntityId $ RFDONE fsSavePath
      forM_ tmpPath (removePath <=< toFSFilePath)
      withStore' c (`updateRcvFileComplete` rcvFileId)
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
      workPath <- getXFTPWorkPath
      outputDir <- uniqueCombine workPath $ fileName <> ".descr"
      createDirectory outputDir
      let tempPath = workPath </> "snd"
      createDirectoryIfMissing False tempPath
      runSend fileName outputDir tempPath `catchError` \e -> do
        cleanup outputDir tempPath
        notify c sndFileId $ SFERR e
      where
        runSend :: String -> FilePath -> FilePath -> m ()
        runSend fileName outputDir tempPath = do
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
          cleanup outputDir tempPath
          notify c sndFileId $ SFDONE sndDescr rcvDescrs
        cleanup :: FilePath -> FilePath -> m ()
        cleanup outputDir tempPath = do
          removePath tempPath
          removePath outputDir
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

notify :: forall m e. (MonadUnliftIO m, AEntityI e) => AgentClient -> EntityId -> ACommand 'Agent e -> m ()
notify c entId cmd = atomically $ writeTBQueue (subQ c) ("", entId, APC (sAEntity @e) cmd)

sendFile :: AgentMonad m => AgentClient -> UserId -> FilePath -> Int -> m SndFileId
sendFile c userId filePath numRecipients = do
  g <- asks idsDrg
  prefixPath <- getPrefixPath "snd.xftp"
  createDirectory prefixPath
  let relPrefixPath = takeFileName prefixPath
  key <- liftIO C.randomSbKey
  nonce <- liftIO C.randomCbNonce
  -- saving absolute filePath will not allow to restore file encryption after app update, but it's a short window
  fId <- withStore c $ \db -> createSndFile db g userId numRecipients filePath relPrefixPath key nonce
  addXFTPSndWorker c Nothing
  pure fId

addXFTPSndWorker :: AgentMonad m => AgentClient -> Maybe XFTPServer -> m ()
addXFTPSndWorker c = addWorker c xftpSndWorkers runXFTPSndWorker runXFTPSndPrepareWorker

runXFTPSndPrepareWorker :: forall m. AgentMonad m => AgentClient -> TMVar () -> m ()
runXFTPSndPrepareWorker c doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    -- TODO agentOperationBracket
    runXftpOperation
  where
    runXftpOperation :: m ()
    runXftpOperation = do
      nextFile <- withStore' c getNextSndFileToPrepare
      case nextFile of
        Nothing -> noWorkToDo
        Just f@SndFile {sndFileId, sndFileEntityId, prefixPath} ->
          prepareFile f `catchError` (sndWorkerInternalError c sndFileId sndFileEntityId prefixPath . show)
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    prepareFile :: SndFile -> m ()
    prepareFile SndFile {prefixPath = Nothing} =
      throwError $ INTERNAL "no prefix path"
    prepareFile sndFile@SndFile {sndFileId, prefixPath = Just ppath, status} = do
      SndFile {numRecipients, chunks} <-
        if status /= SFSEncrypted -- status is SFSNew or SFSEncrypting
          then do
            let encPath = sndFileEncPath ppath
            fsEncPath <- toFSFilePath encPath
            when (status == SFSEncrypting) $
              whenM (doesFileExist fsEncPath) $ removeFile fsEncPath
            withStore' c $ \db -> updateSndFileStatus db sndFileId SFSEncrypting
            (digest, chunkSpecs) <- encryptFileForUpload sndFile encPath
            withStore c $ \db -> do
              updateSndFileEncrypted db sndFileId digest chunkSpecs
              getSndFile db sndFileId
          else pure sndFile
      maxRecipients <- asks (xftpMaxRecipientsPerRequest . config)
      let numRecipients' = min numRecipients maxRecipients
      -- concurrently?
      forM_ chunks $ createChunk numRecipients'
      withStore' c $ \db -> updateSndFileStatus db sndFileId SFSUploading
      where
        encryptFileForUpload :: SndFile -> FilePath -> m (FileDigest, [XFTPChunkSpec])
        encryptFileForUpload SndFile {key, nonce, filePath} encPath = do
          let fileName = takeFileName filePath
          fileSize <- fromInteger <$> getFileSize filePath
          when (fileSize > maxFileSize) $ throwError $ INTERNAL "max file size exceeded"
          let fileHdr = smpEncode FileHeader {fileName, fileExtra = Nothing}
              fileSize' = fromIntegral (B.length fileHdr) + fileSize
              chunkSizes = prepareChunkSizes $ fileSize' + fileSizeLen + authTagSize
              chunkSizes' = map fromIntegral chunkSizes
              encSize = sum chunkSizes'
          void $ liftError (INTERNAL . show) $ encryptFile filePath fileHdr key nonce fileSize' encSize encPath
          digest <- liftIO $ LC.sha512Hash <$> LB.readFile encPath
          let chunkSpecs = prepareChunkSpecs encPath chunkSizes
          pure (FileDigest digest, chunkSpecs)
        createChunk :: Int -> SndFileChunk -> m ()
        createChunk numRecipients' SndFileChunk {sndChunkId, userId, chunkSpec} = do
          (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
          rKeys <- liftIO $ L.fromList <$> replicateM numRecipients' (C.generateSignatureKeyPair C.SEd25519)
          ch@FileInfo {digest} <- liftIO $ getChunkInfo sndKey chunkSpec
          -- TODO with retry on temporary errors
          xftpServer <- getServer
          (sndId, rIds) <- agentXFTPCreateChunk c userId xftpServer spKey ch (L.map fst rKeys)
          let rcvIdsKeys = L.toList $ L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys
          withStore' c $ \db -> createSndFileReplica db sndChunkId (FileDigest digest) xftpServer (ChunkReplicaId sndId) spKey rcvIdsKeys
          addXFTPSndWorker c $ Just xftpServer
        getServer :: m XFTPServer
        getServer = do
          -- TODO get user servers from config
          -- TODO choose next server (per chunk? per file?)
          undefined

sndWorkerInternalError :: AgentMonad m => AgentClient -> DBSndFileId -> SndFileId -> Maybe FilePath -> String -> m ()
sndWorkerInternalError c sndFileId sndFileEntityId prefixPath internalErrStr = do
  forM_ prefixPath (removePath <=< toFSFilePath)
  withStore' c $ \db -> updateSndFileError db sndFileId internalErrStr
  notify c sndFileEntityId $ SFERR $ INTERNAL internalErrStr

runXFTPSndWorker :: forall m. AgentMonad m => AgentClient -> XFTPServer -> TMVar () -> m ()
runXFTPSndWorker c srv doWork = do
  forever $ do
    void . atomically $ readTMVar doWork
    agentOperationBracket c AOSndNetwork throwWhenInactive runXftpOperation
  where
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    runXftpOperation :: m ()
    runXftpOperation = do
      nextChunk <- withStore' c $ \db -> getNextSndChunkToUpload db srv
      case nextChunk of
        Nothing -> noWorkToDo
        Just SndFileChunk {sndFileId, sndFileEntityId, filePrefixPath, replicas = []} -> sndWorkerInternalError c sndFileId sndFileEntityId (Just filePrefixPath) "chunk has no replicas"
        Just fc@SndFileChunk {userId, sndFileId, sndFileEntityId, filePrefixPath, replicas = replica@SndFileChunkReplica {sndChunkReplicaId, server, replicaId, delay} : _} -> do
          ri <- asks $ reconnectInterval . config
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryInterval ri' $ \delay' loop ->
            uploadFileChunk fc replica
              `catchError` \e -> retryOnError c AOSndNetwork "XFTP snd worker" loop (retryMaintenance e delay') (retryDone e) e
          where
            retryMaintenance e replicaDelay = do
              notifyOnRetry <- asks (xftpNotifyErrsOnRetry . config)
              when notifyOnRetry $ notify c sndFileEntityId $ SFERR e
              closeXFTPServerClient c userId server replicaId
              withStore' c $ \db -> updateRcvChunkReplicaDelay db sndChunkReplicaId replicaDelay
            retryDone e = sndWorkerInternalError c sndFileId sndFileEntityId (Just filePrefixPath) (show e)
    uploadFileChunk :: SndFileChunk -> SndFileChunkReplica -> m ()
    uploadFileChunk sndFileChunk@SndFileChunk {sndFileId, userId, chunkSpec} replica = do
      replica'@SndFileChunkReplica {sndChunkReplicaId} <- addRecipients sndFileChunk replica
      agentXFTPUploadChunk c userId replica' chunkSpec
      sf@SndFile {sndFileEntityId, prefixPath, chunks} <- withStore c $ \db -> do
        updateSndChunkReplicaStatus db sndChunkReplicaId SFRSUploaded
        getSndFile db sndFileId
      let complete = all chunkUploaded chunks
      -- TODO calculate progress, notify SFPROG
      when complete $ do
        (sndDescr, rcvDescrs) <- sndFileToDescriptions sf
        notify c sndFileEntityId $ SFDONE sndDescr rcvDescrs
        forM_ prefixPath (removePath <=< toFSFilePath)
        withStore' c $ \db -> updateSndFileStatus db sndFileId SFSComplete
      where
        addRecipients :: SndFileChunk -> SndFileChunkReplica -> m SndFileChunkReplica
        addRecipients ch@SndFileChunk {numRecipients} cr@SndFileChunkReplica {rcvIdsKeys}
          | length rcvIdsKeys > numRecipients = throwError $ INTERNAL "too many recipients"
          | length rcvIdsKeys == numRecipients = pure cr
          | otherwise = do
            maxRecipients <- asks (xftpMaxRecipientsPerRequest . config)
            let numRecipients' = min (numRecipients - length rcvIdsKeys) maxRecipients
            rKeys <- liftIO $ L.fromList <$> replicateM numRecipients' (C.generateSignatureKeyPair C.SEd25519)
            rIds <- agentXFTPAddRecipients c userId cr (L.map fst rKeys)
            let rcvIdsKeys' = L.toList $ L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys
            cr' <- withStore' c $ \db -> addSndChunkReplicaRecipients db cr rcvIdsKeys'
            addRecipients ch cr'
        sndFileToDescriptions :: SndFile -> m (ValidFileDescription 'FSender, [ValidFileDescription 'FRecipient])
        sndFileToDescriptions =
          undefined
        chunkUploaded SndFileChunk {replicas} =
          any (\SndFileChunkReplica {replicaStatus} -> replicaStatus == SFRSUploaded) replicas
