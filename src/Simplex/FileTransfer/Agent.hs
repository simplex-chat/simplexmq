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
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.FileTransfer.Agent
  ( startXFTPWorkers,
    startXFTPSndWorkers,
    closeXFTPAgent,
    toFSFilePath,
    -- Receiving files
    xftpReceiveFile',
    xftpDeleteRcvFile',
    xftpDeleteRcvFiles',
    -- Sending files
    xftpSendFile',
    xftpSendDescription',
    deleteSndFileInternal,
    deleteSndFilesInternal,
    deleteSndFileRemote,
    deleteSndFilesRemote,
  )
where

import Control.Logger.Simple (logError)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Coerce (coerce)
import Data.Composition ((.:))
import Data.Either (partitionEithers, rights)
import Data.Int (Int64)
import Data.List (foldl', partition, sortOn)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Simplex.FileTransfer.Chunks (toKB)
import Simplex.FileTransfer.Client (XFTPChunkSpec (..))
import Simplex.FileTransfer.Client.Main
import Simplex.FileTransfer.Crypto
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), SFileParty (..))
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import qualified Simplex.FileTransfer.Transport as XFTP
import Simplex.FileTransfer.Types
import qualified Simplex.FileTransfer.Types as FT
import Simplex.FileTransfer.Util (removePath, uniqueCombine)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Stats
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs)
import qualified Simplex.Messaging.Crypto.File as CF
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Simplex.Messaging.Protocol (ProtocolServer, ProtocolType (..), XFTPServer)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (catchAll_, liftError, tshow, unlessM, whenM)
import System.FilePath (takeFileName, (</>))
import UnliftIO
import UnliftIO.Directory
import qualified UnliftIO.Exception as E

startXFTPWorkers :: AgentClient -> Maybe FilePath -> AM ()
startXFTPWorkers = startXFTPWorkers_ True
{-# INLINE startXFTPWorkers #-}

startXFTPSndWorkers :: AgentClient -> Maybe FilePath -> AM ()
startXFTPSndWorkers = startXFTPWorkers_ False
{-# INLINE startXFTPSndWorkers #-}

startXFTPWorkers_ :: Bool -> AgentClient -> Maybe FilePath -> AM ()
startXFTPWorkers_ allWorkers c workDir = do
  wd <- asks $ xftpWorkDir . xftpAgent
  atomically $ writeTVar wd workDir
  cfg <- asks config
  when allWorkers $ startRcvFiles cfg
  startSndFiles cfg
  when allWorkers $ startDelFiles cfg
  where
    startRcvFiles :: AgentConfig -> AM ()
    startRcvFiles AgentConfig {rcvFilesTTL} = do
      pendingRcvServers <- withStore' c (`getPendingRcvFilesServers` rcvFilesTTL)
      lift . forM_ pendingRcvServers $ \s -> resumeXFTPRcvWork c (Just s)
      -- start local worker for files pending decryption,
      -- no need to make an extra query for the check
      -- as the worker will check the store anyway
      lift $ resumeXFTPRcvWork c Nothing
    startSndFiles :: AgentConfig -> AM ()
    startSndFiles AgentConfig {sndFilesTTL} = do
      -- start worker for files pending encryption/creation
      lift $ resumeXFTPSndWork c Nothing
      pendingSndServers <- withStore' c (`getPendingSndFilesServers` sndFilesTTL)
      lift . forM_ pendingSndServers $ \s -> resumeXFTPSndWork c (Just s)
    startDelFiles :: AgentConfig -> AM ()
    startDelFiles AgentConfig {rcvFilesTTL} = do
      pendingDelServers <- withStore' c (`getPendingDelFilesServers` rcvFilesTTL)
      lift . forM_ pendingDelServers $ resumeXFTPDelWork c

closeXFTPAgent :: XFTPAgent -> IO ()
closeXFTPAgent a = do
  stopWorkers $ xftpRcvWorkers a
  stopWorkers $ xftpSndWorkers a
  stopWorkers $ xftpDelWorkers a
  where
    stopWorkers workers = atomically (swapTVar workers M.empty) >>= mapM_ (liftIO . cancelWorker)

xftpReceiveFile' :: AgentClient -> UserId -> ValidFileDescription 'FRecipient -> Maybe CryptoFileArgs -> Bool -> AM RcvFileId
xftpReceiveFile' c userId (ValidFileDescription fd@FileDescription {chunks, redirect}) cfArgs approvedRelays = do
  g <- asks random
  prefixPath <- lift $ getPrefixPath "rcv.xftp"
  createDirectory prefixPath
  let relPrefixPath = takeFileName prefixPath
      relTmpPath = relPrefixPath </> "xftp.encrypted"
      relSavePath = relPrefixPath </> "xftp.decrypted"
  lift $ createDirectory =<< toFSFilePath relTmpPath
  lift $ createEmptyFile =<< toFSFilePath relSavePath
  let saveFile = CryptoFile relSavePath cfArgs
  fId <- case redirect of
    Nothing -> withStore c $ \db -> createRcvFile db g userId fd relPrefixPath relTmpPath saveFile approvedRelays
    Just _ -> do
      -- prepare description paths
      let relTmpPathRedirect = relPrefixPath </> "xftp.redirect-encrypted"
          relSavePathRedirect = relPrefixPath </> "xftp.redirect-decrypted"
      lift $ createDirectory =<< toFSFilePath relTmpPathRedirect
      lift $ createEmptyFile =<< toFSFilePath relSavePathRedirect
      cfArgsRedirect <- liftIO $ CF.randomArgs g
      let saveFileRedirect = CryptoFile relSavePathRedirect $ Just cfArgsRedirect
      -- create download tasks
      withStore c $ \db -> createRcvFileRedirect db g userId fd relPrefixPath relTmpPathRedirect saveFileRedirect relTmpPath saveFile approvedRelays
  forM_ chunks (downloadChunk c)
  pure fId

downloadChunk :: AgentClient -> FileChunk -> AM ()
downloadChunk c FileChunk {replicas = (FileChunkReplica {server} : _)} = do
  lift . void $ getXFTPRcvWorker True c (Just server)
downloadChunk _ _ = throwE $ INTERNAL "no replicas"

getPrefixPath :: String -> AM' FilePath
getPrefixPath suffix = do
  workPath <- getXFTPWorkPath
  ts <- liftIO getCurrentTime
  let isoTime = formatTime defaultTimeLocale "%Y%m%d_%H%M%S_%6q" ts
  uniqueCombine workPath (isoTime <> "_" <> suffix)

toFSFilePath :: FilePath -> AM' FilePath
toFSFilePath f = (</> f) <$> getXFTPWorkPath

createEmptyFile :: FilePath -> AM' ()
createEmptyFile fPath = liftIO $ B.writeFile fPath ""

resumeXFTPRcvWork :: AgentClient -> Maybe XFTPServer -> AM' ()
resumeXFTPRcvWork = void .: getXFTPRcvWorker False

getXFTPRcvWorker :: Bool -> AgentClient -> Maybe XFTPServer -> AM' Worker
getXFTPRcvWorker hasWork c server = do
  ws <- asks $ xftpRcvWorkers . xftpAgent
  getAgentWorker "xftp_rcv" hasWork c server ws $
    maybe (runXFTPRcvLocalWorker c) (runXFTPRcvWorker c) server

runXFTPRcvWorker :: AgentClient -> XFTPServer -> Worker -> AM ()
runXFTPRcvWorker c srv Worker {doWork} = do
  cfg <- asks config
  forever $ do
    lift $ waitForWork doWork
    liftIO $ assertAgentForeground c
    runXFTPOperation cfg
  where
    runXFTPOperation :: AgentConfig -> AM ()
    runXFTPOperation AgentConfig {rcvFilesTTL, reconnectInterval = ri, xftpConsecutiveRetries} =
      withWork c doWork (\db -> getNextRcvChunkToDownload db srv rcvFilesTTL) $ \case
        (RcvFileChunk {rcvFileId, rcvFileEntityId, fileTmpPath, replicas = []}, _) -> rcvWorkerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) (INTERNAL "chunk has no replicas")
        (fc@RcvFileChunk {userId, rcvFileId, rcvFileEntityId, digest, fileTmpPath, replicas = replica@RcvFileChunkReplica {rcvChunkReplicaId, server, delay} : _}, approvedRelays) -> do
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryIntervalLimit xftpConsecutiveRetries ri' $ \delay' loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            atomically $ incXFTPServerStat c userId srv downloadAttempts
            downloadFileChunk fc replica approvedRelays
              `catchAgentError` \e -> retryOnError "XFTP rcv worker" (retryLoop loop e delay') (retryDone e) e
          where
            retryLoop loop e replicaDelay = do
              flip catchAgentError (\_ -> pure ()) $ do
                when (serverHostError e) $ notify c rcvFileEntityId $ RFWARN e
                liftIO $ closeXFTPServerClient c userId server digest
                withStore' c $ \db -> updateRcvChunkReplicaDelay db rcvChunkReplicaId replicaDelay
              liftIO $ assertAgentForeground c
              loop
            retryDone e = do
              atomically . incXFTPServerStat c userId srv $ case e of
                XFTP _ XFTP.AUTH -> downloadAuthErrs
                _ -> downloadErrs
              rcvWorkerInternalError c rcvFileId rcvFileEntityId (Just fileTmpPath) e
    downloadFileChunk :: RcvFileChunk -> RcvFileChunkReplica -> Bool -> AM ()
    downloadFileChunk RcvFileChunk {userId, rcvFileId, rcvFileEntityId, rcvChunkId, chunkNo, chunkSize, digest, fileTmpPath} replica approvedRelays = do
      unlessM ((approvedRelays ||) <$> ipAddressProtected') $ throwE $ FILE NOT_APPROVED
      fsFileTmpPath <- lift $ toFSFilePath fileTmpPath
      chunkPath <- uniqueCombine fsFileTmpPath $ show chunkNo
      let chSize = unFileSize chunkSize
          chunkSpec = XFTPRcvChunkSpec chunkPath chSize (unFileDigest digest)
          relChunkPath = fileTmpPath </> takeFileName chunkPath
      agentXFTPDownloadChunk c userId digest replica chunkSpec
      liftIO $ waitUntilForeground c
      (entityId, complete, progress) <- withStore c $ \db -> runExceptT $ do
        liftIO $ updateRcvFileChunkReceived db (rcvChunkReplicaId replica) rcvChunkId relChunkPath
        RcvFile {size = FileSize currentSize, chunks, redirect} <- ExceptT $ getRcvFile db rcvFileId
        let rcvd = receivedSize chunks
            complete = all chunkReceived chunks
            (entityId, total) = case redirect of
              Nothing -> (rcvFileEntityId, currentSize)
              Just RcvFileRedirect {redirectFileInfo = RedirectFileInfo {size = FileSize finalSize}, redirectEntityId} -> (redirectEntityId, finalSize)
        liftIO . when complete $ updateRcvFileStatus db rcvFileId RFSReceived
        pure (entityId, complete, RFPROG rcvd total)
      atomically $ incXFTPServerStat c userId srv downloads
      atomically $ incXFTPServerSizeStat c userId srv downloadsSize (fromIntegral $ toKB chSize)
      notify c entityId progress
      when complete . lift . void $
        getXFTPRcvWorker True c Nothing
      where
        ipAddressProtected' :: AM Bool
        ipAddressProtected' = do
          cfg <- liftIO $ getFastNetworkConfig c
          pure $ ipAddressProtected cfg srv
        receivedSize :: [RcvFileChunk] -> Int64
        receivedSize = foldl' (\sz ch -> sz + receivedChunkSize ch) 0
        receivedChunkSize ch@RcvFileChunk {chunkSize = s}
          | chunkReceived ch = fromIntegral (unFileSize s)
          | otherwise = 0
        chunkReceived RcvFileChunk {replicas} = any received replicas

-- The first call of action has n == 0, maxN is max number of retries
withRetryIntervalLimit :: forall m. MonadIO m => Int -> RetryInterval -> (Int64 -> m () -> m ()) -> m ()
withRetryIntervalLimit maxN ri action =
  withRetryIntervalCount ri $ \n delay loop ->
    when (n < maxN) $ action delay loop

retryOnError :: Text -> AM a -> AM a -> AgentErrorType -> AM a
retryOnError name loop done e = do
  logError $ name <> " error: " <> tshow e
  if temporaryOrHostError e
    then loop
    else done

rcvWorkerInternalError :: AgentClient -> DBRcvFileId -> RcvFileId -> Maybe FilePath -> AgentErrorType -> AM ()
rcvWorkerInternalError c rcvFileId rcvFileEntityId tmpPath err = do
  lift $ forM_ tmpPath (removePath <=< toFSFilePath)
  withStore' c $ \db -> updateRcvFileError db rcvFileId (show err)
  notify c rcvFileEntityId $ RFERR err

runXFTPRcvLocalWorker :: AgentClient -> Worker -> AM ()
runXFTPRcvLocalWorker c Worker {doWork} = do
  cfg <- asks config
  forever $ do
    lift $ waitForWork doWork
    liftIO $ assertAgentForeground c
    runXFTPOperation cfg
  where
    runXFTPOperation :: AgentConfig -> AM ()
    runXFTPOperation AgentConfig {rcvFilesTTL} =
      withWork c doWork (`getNextRcvFileToDecrypt` rcvFilesTTL) $
        \f@RcvFile {rcvFileId, rcvFileEntityId, tmpPath} ->
          decryptFile f `catchAgentError` rcvWorkerInternalError c rcvFileId rcvFileEntityId tmpPath
    decryptFile :: RcvFile -> AM ()
    decryptFile RcvFile {rcvFileId, rcvFileEntityId, size, digest, key, nonce, tmpPath, saveFile, status, chunks, redirect} = do
      let CryptoFile savePath cfArgs = saveFile
      fsSavePath <- lift $ toFSFilePath savePath
      lift . when (status == RFSDecrypting) $
        whenM (doesFileExist fsSavePath) (removeFile fsSavePath >> createEmptyFile fsSavePath)
      withStore' c $ \db -> updateRcvFileStatus db rcvFileId RFSDecrypting
      chunkPaths <- getChunkPaths chunks
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      when (FileSize encSize /= size) $ throwE $ XFTP "" XFTP.SIZE
      encDigest <- liftIO $ LC.sha512Hash <$> readChunks chunkPaths
      when (FileDigest encDigest /= digest) $ throwE $ XFTP "" XFTP.DIGEST
      let destFile = CryptoFile fsSavePath cfArgs
      void $ liftError (FILE . FILE_IO . show) $ decryptChunks encSize chunkPaths key nonce $ \_ -> pure destFile
      case redirect of
        Nothing -> do
          notify c rcvFileEntityId $ RFDONE fsSavePath
          lift $ forM_ tmpPath (removePath <=< toFSFilePath)
          liftIO $ waitUntilForeground c
          withStore' c (`updateRcvFileComplete` rcvFileId)
        Just RcvFileRedirect {redirectFileInfo, redirectDbId} -> do
          let RedirectFileInfo {size = redirectSize, digest = redirectDigest} = redirectFileInfo
          lift $ forM_ tmpPath (removePath <=< toFSFilePath)
          liftIO $ waitUntilForeground c
          withStore' c (`updateRcvFileComplete` rcvFileId)
          -- proceed with redirect
          yaml <- liftError (FILE . FILE_IO . show) (CF.readFile $ CryptoFile fsSavePath cfArgs) `agentFinally` (lift $ toFSFilePath fsSavePath >>= removePath)
          next@FileDescription {chunks = nextChunks} <- case strDecode (LB.toStrict yaml) of
            -- TODO switch to another error constructor
            Left _ -> throwE . FILE $ REDIRECT "decode error"
            Right (ValidFileDescription fd@FileDescription {size = dstSize, digest = dstDigest})
              | dstSize /= redirectSize -> throwE . FILE $ REDIRECT "size mismatch"
              | dstDigest /= redirectDigest -> throwE . FILE $ REDIRECT "digest mismatch"
              | otherwise -> pure fd
          -- register and download chunks from the actual file
          withStore c $ \db -> updateRcvFileRedirect db redirectDbId next
          forM_ nextChunks (downloadChunk c)
      where
        getChunkPaths :: [RcvFileChunk] -> AM [FilePath]
        getChunkPaths [] = pure []
        getChunkPaths (RcvFileChunk {chunkTmpPath = Just path} : cs) = do
          ps <- getChunkPaths cs
          fsPath <- lift $ toFSFilePath path
          pure $ fsPath : ps
        getChunkPaths (RcvFileChunk {chunkTmpPath = Nothing} : _cs) =
          throwE $ INTERNAL "no chunk path"

xftpDeleteRcvFile' :: AgentClient -> RcvFileId -> AM' ()
xftpDeleteRcvFile' c rcvFileEntityId = xftpDeleteRcvFiles' c [rcvFileEntityId]

xftpDeleteRcvFiles' :: AgentClient -> [RcvFileId] -> AM' ()
xftpDeleteRcvFiles' c rcvFileEntityIds = do
  rcvFiles <- rights <$> withStoreBatch c (\db -> map (fmap (first storeError) . getRcvFileByEntityId db) rcvFileEntityIds)
  redirects <- rights <$> batchFiles getRcvFileRedirects rcvFiles
  let (toDelete, toMarkDeleted) = partition fileComplete $ concat redirects <> rcvFiles
  void $ batchFiles deleteRcvFile' toDelete
  void $ batchFiles updateRcvFileDeleted toMarkDeleted
  workPath <- getXFTPWorkPath
  liftIO . forM_ toDelete $ \RcvFile {prefixPath} ->
    (removePath . (workPath </>)) prefixPath `catchAll_` pure ()
  where
    fileComplete RcvFile {status} = status == RFSComplete || status == RFSError
    batchFiles :: (DB.Connection -> DBRcvFileId -> IO a) -> [RcvFile] -> AM' [Either AgentErrorType a]
    batchFiles f rcvFiles = withStoreBatch' c $ \db -> map (\RcvFile {rcvFileId} -> f db rcvFileId) rcvFiles

notify :: forall m e. (MonadIO m, AEntityI e) => AgentClient -> AEntityId -> AEvent e -> m ()
notify c entId cmd = atomically $ writeTBQueue (subQ c) ("", entId, AEvt (sAEntity @e) cmd)

xftpSendFile' :: AgentClient -> UserId -> CryptoFile -> Int -> AM SndFileId
xftpSendFile' c userId file numRecipients = do
  g <- asks random
  prefixPath <- lift $ getPrefixPath "snd.xftp"
  createDirectory prefixPath
  let relPrefixPath = takeFileName prefixPath
  key <- liftIO $ C.randomSbKey g
  nonce <- liftIO $ C.randomCbNonce g
  -- saving absolute filePath will not allow to restore file encryption after app update, but it's a short window
  fId <- withStore c $ \db -> createSndFile db g userId file numRecipients relPrefixPath key nonce Nothing
  lift . void $ getXFTPSndWorker True c Nothing
  pure fId

xftpSendDescription' :: AgentClient -> UserId -> ValidFileDescription 'FRecipient -> Int -> AM SndFileId
xftpSendDescription' c userId (ValidFileDescription fdDirect@FileDescription {size, digest}) numRecipients = do
  g <- asks random
  prefixPath <- lift $ getPrefixPath "snd.xftp"
  createDirectory prefixPath
  let relPrefixPath = takeFileName prefixPath
  let directYaml = prefixPath </> "direct.yaml"
  cfArgs <- liftIO $ CF.randomArgs g
  let file = CryptoFile directYaml (Just cfArgs)
  liftError (FILE . FILE_IO . show) $ CF.writeFile file (LB.fromStrict $ strEncode fdDirect)
  key <- liftIO $ C.randomSbKey g
  nonce <- liftIO $ C.randomCbNonce g
  fId <- withStore c $ \db -> createSndFile db g userId file numRecipients relPrefixPath key nonce $ Just RedirectFileInfo {size, digest}
  lift . void $ getXFTPSndWorker True c Nothing
  pure fId

resumeXFTPSndWork :: AgentClient -> Maybe XFTPServer -> AM' ()
resumeXFTPSndWork = void .: getXFTPSndWorker False

getXFTPSndWorker :: Bool -> AgentClient -> Maybe XFTPServer -> AM' Worker
getXFTPSndWorker hasWork c server = do
  ws <- asks $ xftpSndWorkers . xftpAgent
  getAgentWorker "xftp_snd" hasWork c server ws $
    maybe (runXFTPSndPrepareWorker c) (runXFTPSndWorker c) server

runXFTPSndPrepareWorker :: AgentClient -> Worker -> AM ()
runXFTPSndPrepareWorker c Worker {doWork} = do
  cfg <- asks config
  forever $ do
    lift $ waitForWork doWork
    liftIO $ assertAgentForeground c
    runXFTPOperation cfg
  where
    runXFTPOperation :: AgentConfig -> AM ()
    runXFTPOperation cfg@AgentConfig {sndFilesTTL} =
      withWork c doWork (`getNextSndFileToPrepare` sndFilesTTL) $
        \f@SndFile {sndFileId, sndFileEntityId, prefixPath} ->
          prepareFile cfg f `catchAgentError` sndWorkerInternalError c sndFileId sndFileEntityId prefixPath
    prepareFile :: AgentConfig -> SndFile -> AM ()
    prepareFile _ SndFile {prefixPath = Nothing} =
      throwE $ INTERNAL "no prefix path"
    prepareFile cfg sndFile@SndFile {sndFileId, sndFileEntityId, userId, prefixPath = Just ppath, status} = do
      SndFile {numRecipients, chunks} <-
        if status /= SFSEncrypted -- status is SFSNew or SFSEncrypting
          then do
            fsEncPath <- lift . toFSFilePath $ sndFileEncPath ppath
            when (status == SFSEncrypting) . whenM (doesFileExist fsEncPath) $
              removeFile fsEncPath
            withStore' c $ \db -> updateSndFileStatus db sndFileId SFSEncrypting
            (digest, chunkSpecsDigests) <- encryptFileForUpload sndFile fsEncPath
            withStore c $ \db -> do
              updateSndFileEncrypted db sndFileId digest chunkSpecsDigests
              getSndFile db sndFileId
          else pure sndFile
      let numRecipients' = min numRecipients maxRecipients
      -- in case chunk preparation previously failed mid-way, some chunks may already be created -
      -- here we split previously prepared chunks from the pending ones to then build full list of servers
      let (pendingChunks, preparedSrvs) = partitionEithers $ map srvOrPendingChunk chunks
      -- concurrently?
      -- separate worker to create chunks? record retries and delay on snd_file_chunks?
      srvs <- forM pendingChunks $ createChunk numRecipients'
      let allSrvs = S.fromList $ preparedSrvs <> srvs
      lift $ forM_ allSrvs $ \srv -> getXFTPSndWorker True c (Just srv)
      withStore' c $ \db -> updateSndFileStatus db sndFileId SFSUploading
      where
        AgentConfig {xftpMaxRecipientsPerRequest = maxRecipients, messageRetryInterval = ri} = cfg
        encryptFileForUpload :: SndFile -> FilePath -> AM (FileDigest, [(XFTPChunkSpec, FileDigest)])
        encryptFileForUpload SndFile {key, nonce, srcFile, redirect} fsEncPath = do
          let CryptoFile {filePath} = srcFile
              fileName = takeFileName filePath
          fileSize <- liftIO $ fromInteger <$> CF.getFileContentsSize srcFile
          when (fileSize > maxFileSizeHard) $ throwE $ FILE FT.SIZE
          let fileHdr = smpEncode FileHeader {fileName, fileExtra = Nothing}
              fileSize' = fromIntegral (B.length fileHdr) + fileSize
              payloadSize = fileSize' + fileSizeLen + authTagSize
          chunkSizes <- case redirect of
            Nothing -> pure $ prepareChunkSizes payloadSize
            Just _ -> case singleChunkSize payloadSize of
              Nothing -> throwE $ FILE FT.SIZE
              Just chunkSize -> pure [chunkSize]
          let encSize = sum $ map fromIntegral chunkSizes
          void $ liftError (FILE . FILE_IO . show) $ encryptFile srcFile fileHdr key nonce fileSize' encSize fsEncPath
          digest <- liftIO $ LC.sha512Hash <$> LB.readFile fsEncPath
          let chunkSpecs = prepareChunkSpecs fsEncPath chunkSizes
          chunkDigests <- liftIO $ mapM getChunkDigest chunkSpecs
          pure (FileDigest digest, zip chunkSpecs $ coerce chunkDigests)
        srvOrPendingChunk :: SndFileChunk -> Either SndFileChunk (ProtocolServer 'PXFTP)
        srvOrPendingChunk ch@SndFileChunk {replicas} = case replicas of
          [] -> Left ch
          SndFileChunkReplica {server} : _ -> Right server
        createChunk :: Int -> SndFileChunk -> AM (ProtocolServer 'PXFTP)
        createChunk numRecipients' ch = do
          liftIO $ assertAgentForeground c
          (replica, ProtoServerWithAuth srv _) <- tryCreate
          withStore' c $ \db -> createSndFileReplica db ch replica
          pure srv
          where
            tryCreate = do
              usedSrvs <- newTVarIO ([] :: [XFTPServer])
              let AgentClient {xftpServers} = c
              userSrvCount <- liftIO $ length <$> TM.lookupIO userId xftpServers
              withRetryIntervalCount (riFast ri) $ \n _ loop -> do
                liftIO $ waitWhileSuspended c
                liftIO $ waitForUserNetwork c
                let triedAllSrvs = n > userSrvCount
                createWithNextSrv usedSrvs
                  `catchAgentError` \e -> retryOnError "XFTP prepare worker" (retryLoop loop triedAllSrvs e) (throwE e) e
              where
                -- we don't do closeXFTPServerClient here to not risk closing connection for concurrent chunk upload
                retryLoop loop triedAllSrvs e = do
                  flip catchAgentError (\_ -> pure ()) $ do
                    when (triedAllSrvs && serverHostError e) $ notify c sndFileEntityId $ SFWARN e
                  liftIO $ assertAgentForeground c
                  loop
            createWithNextSrv usedSrvs = do
              deleted <- withStore' c $ \db -> getSndFileDeleted db sndFileId
              when deleted $ throwE $ FILE NO_FILE
              withNextSrv c userId usedSrvs [] $ \srvAuth -> do
                replica <- agentXFTPNewChunk c ch numRecipients' srvAuth
                pure (replica, srvAuth)

sndWorkerInternalError :: AgentClient -> DBSndFileId -> SndFileId -> Maybe FilePath -> AgentErrorType -> AM ()
sndWorkerInternalError c sndFileId sndFileEntityId prefixPath err = do
  lift . forM_ prefixPath $ removePath <=< toFSFilePath
  withStore' c $ \db -> updateSndFileError db sndFileId (show err)
  notify c sndFileEntityId $ SFERR err

runXFTPSndWorker :: AgentClient -> XFTPServer -> Worker -> AM ()
runXFTPSndWorker c srv Worker {doWork} = do
  cfg <- asks config
  forever $ do
    lift $ waitForWork doWork
    liftIO $ assertAgentForeground c
    runXFTPOperation cfg
  where
    runXFTPOperation :: AgentConfig -> AM ()
    runXFTPOperation cfg@AgentConfig {sndFilesTTL, reconnectInterval = ri, xftpConsecutiveRetries} = do
      withWork c doWork (\db -> getNextSndChunkToUpload db srv sndFilesTTL) $ \case
        SndFileChunk {sndFileId, sndFileEntityId, filePrefixPath, replicas = []} -> sndWorkerInternalError c sndFileId sndFileEntityId (Just filePrefixPath) (INTERNAL "chunk has no replicas")
        fc@SndFileChunk {userId, sndFileId, sndFileEntityId, filePrefixPath, digest, replicas = replica@SndFileChunkReplica {sndChunkReplicaId, server, delay} : _} -> do
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryIntervalLimit xftpConsecutiveRetries ri' $ \delay' loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            atomically $ incXFTPServerStat c userId srv uploadAttempts
            uploadFileChunk cfg fc replica
              `catchAgentError` \e -> retryOnError "XFTP snd worker" (retryLoop loop e delay') (retryDone e) e
          where
            retryLoop loop e replicaDelay = do
              flip catchAgentError (\_ -> pure ()) $ do
                when (serverHostError e) $ notify c sndFileEntityId $ SFWARN e
                liftIO $ closeXFTPServerClient c userId server digest
                withStore' c $ \db -> updateSndChunkReplicaDelay db sndChunkReplicaId replicaDelay
              liftIO $ assertAgentForeground c
              loop
            retryDone e = do
              atomically $ incXFTPServerStat c userId srv uploadErrs
              sndWorkerInternalError c sndFileId sndFileEntityId (Just filePrefixPath) e
    uploadFileChunk :: AgentConfig -> SndFileChunk -> SndFileChunkReplica -> AM ()
    uploadFileChunk AgentConfig {xftpMaxRecipientsPerRequest = maxRecipients} sndFileChunk@SndFileChunk {sndFileId, userId, chunkSpec = chunkSpec@XFTPChunkSpec {filePath, chunkSize = chSize}, digest = chunkDigest} replica = do
      replica'@SndFileChunkReplica {sndChunkReplicaId} <- addRecipients sndFileChunk replica
      fsFilePath <- lift $ toFSFilePath filePath
      unlessM (doesFileExist fsFilePath) $ throwE $ FILE NO_FILE
      let chunkSpec' = chunkSpec {filePath = fsFilePath} :: XFTPChunkSpec
      liftIO $ assertAgentForeground c
      agentXFTPUploadChunk c userId chunkDigest replica' chunkSpec'
      liftIO $ waitUntilForeground c
      sf@SndFile {sndFileEntityId, prefixPath, chunks} <- withStore c $ \db -> do
        updateSndChunkReplicaStatus db sndChunkReplicaId SFRSUploaded
        getSndFile db sndFileId
      let uploaded = uploadedSize chunks
          total = totalSize chunks
          complete = all chunkUploaded chunks
      atomically $ incXFTPServerStat c userId srv uploads
      atomically $ incXFTPServerSizeStat c userId srv uploadsSize (fromIntegral $ toKB chSize)
      notify c sndFileEntityId $ SFPROG uploaded total
      when complete $ do
        (sndDescr, rcvDescrs) <- sndFileToDescrs sf
        notify c sndFileEntityId $ SFDONE sndDescr rcvDescrs
        lift . forM_ prefixPath $ removePath <=< toFSFilePath
        withStore' c $ \db -> updateSndFileComplete db sndFileId
      where
        addRecipients :: SndFileChunk -> SndFileChunkReplica -> AM SndFileChunkReplica
        addRecipients ch@SndFileChunk {numRecipients} cr@SndFileChunkReplica {rcvIdsKeys}
          | length rcvIdsKeys > numRecipients = throwE $ INTERNAL "too many recipients"
          | length rcvIdsKeys == numRecipients = pure cr
          | otherwise = do
              let numRecipients' = min (numRecipients - length rcvIdsKeys) maxRecipients
              rcvIdsKeys' <- agentXFTPAddRecipients c userId chunkDigest cr numRecipients'
              cr' <- withStore' c $ \db -> addSndChunkReplicaRecipients db cr $ L.toList rcvIdsKeys'
              addRecipients ch cr'
        sndFileToDescrs :: SndFile -> AM (ValidFileDescription 'FSender, [ValidFileDescription 'FRecipient])
        sndFileToDescrs SndFile {digest = Nothing} = throwE $ INTERNAL "snd file has no digest"
        sndFileToDescrs SndFile {chunks = []} = throwE $ INTERNAL "snd file has no chunks"
        sndFileToDescrs SndFile {digest = Just digest, key, nonce, chunks = chunks@(fstChunk : _), redirect} = do
          let chunkSize = FileSize $ sndChunkSize fstChunk
              size = FileSize $ sum $ map (fromIntegral . sndChunkSize) chunks
          -- snd description
          sndDescrChunks <- mapM toSndDescrChunk chunks
          let fdSnd = FileDescription {party = SFSender, size, digest, key, nonce, chunkSize, chunks = sndDescrChunks, redirect = Nothing}
          validFdSnd <- either (throwE . INTERNAL) pure $ validateFileDescription fdSnd
          -- rcv descriptions
          let fdRcv = FileDescription {party = SFRecipient, size, digest, key, nonce, chunkSize, chunks = [], redirect}
              fdRcvs = createRcvFileDescriptions fdRcv chunks
          validFdRcvs <- either (throwE . INTERNAL) pure $ mapM validateFileDescription fdRcvs
          pure (validFdSnd, validFdRcvs)
        toSndDescrChunk :: SndFileChunk -> AM FileChunk
        toSndDescrChunk SndFileChunk {replicas = []} = throwE $ INTERNAL "snd file chunk has no replicas"
        toSndDescrChunk ch@SndFileChunk {chunkNo, digest = chDigest, replicas = (SndFileChunkReplica {server, replicaId, replicaKey} : _)} = do
          let chunkSize = FileSize $ sndChunkSize ch
              replicas = [FileChunkReplica {server, replicaId, replicaKey}]
          pure FileChunk {chunkNo, digest = chDigest, chunkSize, replicas}
        createRcvFileDescriptions :: FileDescription 'FRecipient -> [SndFileChunk] -> [FileDescription 'FRecipient]
        createRcvFileDescriptions fd sndChunks = map (\chunks -> (fd :: (FileDescription 'FRecipient)) {chunks}) rcvChunks
          where
            rcvReplicas :: [SentRecipientReplica]
            rcvReplicas = concatMap toSentRecipientReplicas sndChunks
            toSentRecipientReplicas :: SndFileChunk -> [SentRecipientReplica]
            toSentRecipientReplicas ch@SndFileChunk {chunkNo, digest, replicas} =
              let chunkSize = FileSize $ sndChunkSize ch
               in concatMap
                    ( \SndFileChunkReplica {server, rcvIdsKeys} ->
                        zipWith
                          (\rcvNo (replicaId, replicaKey) -> SentRecipientReplica {chunkNo, server, rcvNo, replicaId, replicaKey, digest, chunkSize})
                          [1 ..]
                          rcvIdsKeys
                    )
                    replicas
            rcvChunks :: [[FileChunk]]
            rcvChunks = map (sortChunks . M.elems) $ M.elems $ foldl' addRcvChunk M.empty rcvReplicas
            sortChunks :: [FileChunk] -> [FileChunk]
            sortChunks = map reverseReplicas . sortOn (\FileChunk {chunkNo} -> chunkNo)
            reverseReplicas ch@FileChunk {replicas} = (ch :: FileChunk) {replicas = reverse replicas}
            addRcvChunk :: Map Int (Map Int FileChunk) -> SentRecipientReplica -> Map Int (Map Int FileChunk)
            addRcvChunk m SentRecipientReplica {chunkNo, server, rcvNo, replicaId, replicaKey, digest, chunkSize} =
              M.alter (Just . addOrChangeRecipient) rcvNo m
              where
                addOrChangeRecipient :: Maybe (Map Int FileChunk) -> Map Int FileChunk
                addOrChangeRecipient = \case
                  Just m' -> M.alter (Just . addOrChangeChunk) chunkNo m'
                  _ -> M.singleton chunkNo $ FileChunk {chunkNo, digest, chunkSize, replicas = [replica']}
                addOrChangeChunk :: Maybe FileChunk -> FileChunk
                addOrChangeChunk = \case
                  Just ch@FileChunk {replicas} -> ch {replicas = replica' : replicas}
                  _ -> FileChunk {chunkNo, digest, chunkSize, replicas = [replica']}
                replica' = FileChunkReplica {server, replicaId, replicaKey}
        uploadedSize :: [SndFileChunk] -> Int64
        uploadedSize = foldl' (\sz ch -> sz + uploadedChunkSize ch) 0
        uploadedChunkSize ch
          | chunkUploaded ch = fromIntegral (sndChunkSize ch)
          | otherwise = 0
        totalSize :: [SndFileChunk] -> Int64
        totalSize = foldl' (\sz ch -> sz + fromIntegral (sndChunkSize ch)) 0
        chunkUploaded :: SndFileChunk -> Bool
        chunkUploaded SndFileChunk {replicas} =
          any (\SndFileChunkReplica {replicaStatus} -> replicaStatus == SFRSUploaded) replicas

deleteSndFileInternal :: AgentClient -> SndFileId -> AM' ()
deleteSndFileInternal c sndFileEntityId = deleteSndFilesInternal c [sndFileEntityId]

deleteSndFilesInternal :: AgentClient -> [SndFileId] -> AM' ()
deleteSndFilesInternal c sndFileEntityIds = do
  sndFiles <- rights <$> withStoreBatch c (\db -> map (fmap (first storeError) . getSndFileByEntityId db) sndFileEntityIds)
  let (toDelete, toMarkDeleted) = partition fileComplete sndFiles
  workPath <- getXFTPWorkPath
  liftIO . forM_ toDelete $ \SndFile {prefixPath} ->
    mapM_ (removePath . (workPath </>)) prefixPath `catchAll_` pure ()
  batchFiles_ deleteSndFile' toDelete
  batchFiles_ updateSndFileDeleted toMarkDeleted
  where
    fileComplete SndFile {status} = status == SFSComplete || status == SFSError
    batchFiles_ :: (DB.Connection -> DBSndFileId -> IO a) -> [SndFile] -> AM' ()
    batchFiles_ f sndFiles = void $ withStoreBatch' c $ \db -> map (\SndFile {sndFileId} -> f db sndFileId) sndFiles

deleteSndFileRemote :: AgentClient -> UserId -> SndFileId -> ValidFileDescription 'FSender -> AM' ()
deleteSndFileRemote c userId sndFileEntityId sfd = deleteSndFilesRemote c userId [(sndFileEntityId, sfd)]

deleteSndFilesRemote :: AgentClient -> UserId -> [(SndFileId, ValidFileDescription 'FSender)] -> AM' ()
deleteSndFilesRemote c userId sndFileIdsDescrs = do
  deleteSndFilesInternal c (map fst sndFileIdsDescrs) `E.catchAny` (notify c "" . SFERR . INTERNAL . show)
  let rs = concatMap (mapMaybe chunkReplica . fdChunks . snd) sndFileIdsDescrs
  void $ withStoreBatch' c (\db -> map (uncurry $ createDeletedSndChunkReplica db userId) rs)
  let servers = S.fromList $ map (\(FileChunkReplica {server}, _) -> server) rs
  mapM_ (getXFTPDelWorker True c) servers
  where
    fdChunks (ValidFileDescription FileDescription {chunks}) = chunks
    chunkReplica :: FileChunk -> Maybe (FileChunkReplica, FileDigest)
    chunkReplica = \case
      FileChunk {digest, replicas = replica : _} -> Just (replica, digest)
      _ -> Nothing

resumeXFTPDelWork :: AgentClient -> XFTPServer -> AM' ()
resumeXFTPDelWork = void .: getXFTPDelWorker False

getXFTPDelWorker :: Bool -> AgentClient -> XFTPServer -> AM' Worker
getXFTPDelWorker hasWork c server = do
  ws <- asks $ xftpDelWorkers . xftpAgent
  getAgentWorker "xftp_del" hasWork c server ws $ runXFTPDelWorker c server

runXFTPDelWorker :: AgentClient -> XFTPServer -> Worker -> AM ()
runXFTPDelWorker c srv Worker {doWork} = do
  cfg <- asks config
  forever $ do
    lift $ waitForWork doWork
    liftIO $ assertAgentForeground c
    runXFTPOperation cfg
  where
    runXFTPOperation :: AgentConfig -> AM ()
    runXFTPOperation AgentConfig {rcvFilesTTL, reconnectInterval = ri, xftpConsecutiveRetries} = do
      -- no point in deleting files older than rcv ttl, as they will be expired on server
      withWork c doWork (\db -> getNextDeletedSndChunkReplica db srv rcvFilesTTL) processDeletedReplica
      where
        processDeletedReplica replica@DeletedSndChunkReplica {deletedSndChunkReplicaId, userId, server, chunkDigest, delay} = do
          let ri' = maybe ri (\d -> ri {initialInterval = d, increaseAfter = 0}) delay
          withRetryIntervalLimit xftpConsecutiveRetries ri' $ \delay' loop -> do
            liftIO $ waitWhileSuspended c
            liftIO $ waitForUserNetwork c
            atomically $ incXFTPServerStat c userId srv deleteAttempts
            deleteChunkReplica
              `catchAgentError` \e -> retryOnError "XFTP del worker" (retryLoop loop e delay') (retryDone e) e
          where
            retryLoop loop e replicaDelay = do
              flip catchAgentError (\_ -> pure ()) $ do
                when (serverHostError e) $ notify c "" $ SFWARN e
                liftIO $ closeXFTPServerClient c userId server chunkDigest
                withStore' c $ \db -> updateDeletedSndChunkReplicaDelay db deletedSndChunkReplicaId replicaDelay
              liftIO $ assertAgentForeground c
              loop
            retryDone e = do
              atomically $ incXFTPServerStat c userId srv deleteErrs
              delWorkerInternalError c deletedSndChunkReplicaId e
            deleteChunkReplica = do
              agentXFTPDeleteChunk c userId replica
              withStore' c $ \db -> deleteDeletedSndChunkReplica db deletedSndChunkReplicaId
              atomically $ incXFTPServerStat c userId srv deletions

delWorkerInternalError :: AgentClient -> Int64 -> AgentErrorType -> AM ()
delWorkerInternalError c deletedSndChunkReplicaId e = do
  withStore' c $ \db -> deleteDeletedSndChunkReplica db deletedSndChunkReplicaId
  notify c "" $ SFERR e

assertAgentForeground :: AgentClient -> IO ()
assertAgentForeground c = do
  throwWhenInactive c
  waitUntilForeground c
