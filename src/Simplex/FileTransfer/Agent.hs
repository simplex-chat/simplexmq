{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.FileTransfer.Agent
  ( -- Receiving files
    receiveFile,
    addXFTPWorker,
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
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as U
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List (isSuffixOf, partition)
import Data.List.NonEmpty (nonEmpty)
import qualified Data.List.NonEmpty as L
import Simplex.FileTransfer.Client.Main (CLIError, SendOptions (..), cliSendFile)
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
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (XFTPServer)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (liftIOEither, tshow)
import System.FilePath (takeFileName, (</>))
import UnliftIO
import UnliftIO.Concurrent
import UnliftIO.Directory
import qualified UnliftIO.Exception as E

receiveFile :: AgentMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> Maybe FilePath -> FilePath -> m RcvFileId
receiveFile c userId (ValidFileDescription fd@FileDescription {chunks}) xftpWorkPath savePath = do
  g <- asks idsDrg
  workPath <- maybe getTemporaryDirectory pure xftpWorkPath
  encPath <- uniqueCombine workPath "xftp.encrypted"
  createDirectory encPath
  fId <- withStore c $ \db -> createRcvFile db g userId fd encPath savePath
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
        Just RcvFileChunk {rcvFileId, rcvFileEntityId, fileTmpPath, replicas = []} -> workerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) "chunk has no replicas"
        Just fc@RcvFileChunk {rcvFileId, rcvFileEntityId, rcvChunkId, fileTmpPath, delay, replicas = replica@RcvFileChunkReplica {rcvChunkReplicaId} : _} -> do
          ri <- asks $ reconnectInterval . config
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryInterval ri' $ \delay' loop ->
            downloadFileChunk fc replica
              `catchError` retryOnError delay' loop (workerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) . show)
          where
            retryOnError :: Int -> m () -> (AgentErrorType -> m ()) -> AgentErrorType -> m ()
            retryOnError chunkDelay loop done e = do
              logError $ "XFTP worker error: " <> tshow e
              if temporaryAgentError e
                then retryLoop
                else done e
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

workerInternalError :: AgentMonad m => AgentClient -> DBRcvFileId -> RcvFileId -> Maybe FilePath -> String -> m ()
workerInternalError c rcvFileId rcvFileEntityId tmpPath internalErrStr = do
  forM_ tmpPath removePath
  withStore' c $ \db -> updateRcvFileError db rcvFileId internalErrStr
  notifyInternalError c rcvFileEntityId internalErrStr

notifyInternalError :: (MonadUnliftIO m) => AgentClient -> RcvFileId -> String -> m ()
notifyInternalError AgentClient {subQ} rcvFileEntityId internalErrStr = atomically $ writeTBQueue subQ ("", rcvFileEntityId, APC SAERcvFile $ RFERR $ INTERNAL internalErrStr)

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
        Just f@RcvFile {rcvFileId, rcvFileEntityId, tmpPath} ->
          decryptFile f `catchError` (workerInternalError c rcvFileId rcvFileEntityId tmpPath . show)
    noWorkToDo = void . atomically $ tryTakeTMVar doWork
    decryptFile :: RcvFile -> m ()
    decryptFile RcvFile {rcvFileId, rcvFileEntityId, key, nonce, tmpPath, savePath, chunks} = do
      -- TODO test; recreate file if it's in status RFSDecrypting
      -- when (status == RFSDecrypting) $
      --   whenM (doesFileExist savePath) (removeFile savePath >> emptyFile)
      withStore' c $ \db -> updateRcvFileStatus db rcvFileId RFSDecrypting
      chunkPaths <- getChunkPaths chunks
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      decrypt encSize chunkPaths
      forM_ tmpPath removePath
      withStore' c (`updateRcvFileComplete` rcvFileId)
      notify RFDONE
      where
        -- emptyFile :: m ()
        -- emptyFile = do
        --   h <- openFile savePath AppendMode
        --   liftIO $ B.hPut h "" >> hFlush h
        notify :: forall e. AEntityI e => ACommand 'Agent e -> m ()
        notify cmd = atomically $ writeTBQueue subQ ("", rcvFileEntityId, APC (sAEntity @e) cmd)
        getChunkPaths :: [RcvFileChunk] -> m [FilePath]
        getChunkPaths [] = pure []
        getChunkPaths (RcvFileChunk {chunkTmpPath = Just path} : cs) = do
          ps <- getChunkPaths cs
          pure $ path : ps
        getChunkPaths (RcvFileChunk {chunkTmpPath = Nothing} : _cs) =
          throwError $ INTERNAL "no chunk path"
        -- TODO refactor with decrypt in CLI, streaming decryption
        decrypt :: Int64 -> [FilePath] -> m ()
        decrypt encSize chunkPaths = do
          lazyChunks <- liftIO $ readChunks chunkPaths
          (authOk, f) <- liftEither . first cryptoError $ LC.sbDecryptTailTag key nonce (encSize - authTagSize) lazyChunks
          let (fileHdr, f') = LB.splitAt 1024 f
          -- withFile encPath ReadMode $ \r -> do
          --   fileHdr <- liftIO $ B.hGet r 1024
          case A.parse smpP $ LB.toStrict fileHdr of
            -- TODO XFTP errors
            A.Fail _ _ e -> throwError $ INTERNAL $ "Invalid file header: " <> e
            A.Partial _ -> throwError $ INTERNAL "Invalid file header"
            A.Done rest FileHeader {fileName = _fn} -> do
              -- ? check file name match
              liftIO $ LB.writeFile savePath $ LB.fromStrict rest <> f'
              unless authOk $ do
                removeFile savePath
                throwError $ INTERNAL "Error decrypting file: incorrect auth tag"
        readChunks :: [FilePath] -> IO LB.ByteString
        readChunks = foldM (\s path -> (s <>) <$> LB.readFile path) ""

sendFileExperimental :: forall m. AgentMonad m => AgentClient -> UserId -> FilePath -> Int -> Maybe FilePath -> m SndFileId
sendFileExperimental AgentClient {subQ} _userId filePath numRecipients xftpWorkPath = do
  g <- asks idsDrg
  sndFileId <- liftIO $ randomId g 12
  void $ forkIO $ sendCLI sndFileId
  pure sndFileId
  where
    randomId :: TVar ChaChaDRG -> Int -> IO ByteString
    randomId gVar n = U.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)
    sendCLI :: SndFileId -> m ()
    sendCLI sndFileId = do
      let fileName = takeFileName filePath
      workPath <- maybe getTemporaryDirectory pure xftpWorkPath
      outputDir <- uniqueCombine workPath $ fileName <> ".descr"
      createDirectory outputDir
      let tempPath = workPath </> "snd"
      createDirectoryIfMissing False tempPath
      let sendOptions =
            SendOptions
              { filePath,
                outputDir = Just outputDir,
                numRecipients,
                xftpServers = [],
                retryCount = 3,
                tempPath = Just tempPath,
                verbose = False
              }
      liftCLI $ cliSendFile sendOptions
      (sndDescr, rcvDescrs) <- readDescrs outputDir fileName
      notify sndFileId $ SFDONE sndDescr rcvDescrs
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
    notify :: forall e. AEntityI e => SndFileId -> ACommand 'Agent e -> m ()
    notify sndFileId cmd = atomically $ writeTBQueue subQ ("", sndFileId, APC (sAEntity @e) cmd)

-- _sendFile :: AgentMonad m => AgentClient -> UserId -> Int -> FilePath -> FilePath -> m SndFileId
_sendFile :: AgentClient -> UserId -> Int -> FilePath -> FilePath -> m SndFileId
_sendFile _c _userId _numRecipients _xftpPath _filePath = do
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
