{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Server where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CorrId, RcvPublicDhKey, RcvPublicVerifyKey, RecipientId)
import Simplex.Messaging.Server (dummyVerifyCmd, verifyCmdSignature)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering)
import UnliftIO (IOMode (..), withFile)
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Directory (doesFileExist, removeFile, renameFile)
import UnliftIO.Exception
import UnliftIO.STM

type M a = ReaderT XFTPEnv IO a

runXFTPServer :: XFTPServerConfig -> IO ()
runXFTPServer cfg = do
  started <- newEmptyTMVarIO
  runXFTPServerBlocking started cfg

runXFTPServerBlocking :: TMVar Bool -> XFTPServerConfig -> IO ()
runXFTPServerBlocking started cfg = newXFTPServerEnv cfg >>= runReaderT (xftpServer cfg started)

xftpServer :: XFTPServerConfig -> TMVar Bool -> M ()
xftpServer cfg@XFTPServerConfig {xftpPort, transportConfig} started = do
  restoreServerStats
  raceAny_ (runServer : expireFilesThread_ cfg <> serverStatsThread_ cfg) `finally` stopServer
  where
    runServer :: M ()
    runServer = do
      serverParams <- asks tlsServerParams
      env <- ask
      liftIO $
        runHTTP2Server started xftpPort defaultHTTP2BufferSize serverParams transportConfig $ \sessionId r sendResponse -> do
          reqBody <- getHTTP2Body r xftpBlockSize
          processRequest HTTP2Request {sessionId, request = r, reqBody, sendResponse} `runReaderT` env

    stopServer :: M ()
    stopServer = do
      withFileLog closeStoreLog
      saveServerStats

    expireFilesThread_ :: XFTPServerConfig -> [M ()]
    expireFilesThread_ XFTPServerConfig {fileExpiration = Just fileExp} = [expireFiles fileExp]
    expireFilesThread_ _ = []

    expireFiles :: ExpirationConfig -> M ()
    expireFiles expCfg = do
      st <- asks store
      let interval = checkInterval expCfg * 1000000
      forever $ do
        liftIO $ threadDelay' interval
        old <- liftIO $ expireBeforeEpoch expCfg
        sIds <- M.keysSet <$> readTVarIO (files st)
        forM_ sIds $ \sId -> do
          threadDelay 100000
          atomically (expiredFilePath st sId old)
            >>= mapM_ (remove $ delete st sId)
      where
        remove del filePath =
          ifM
            (doesFileExist filePath)
            (removeFile filePath >> del `catch` \(e :: SomeException) -> logError $ "failed to remove expired file " <> tshow filePath <> ": " <> tshow e)
            del
        delete st sId = do
          withFileLog (`logDeleteFile` sId)
          void $ atomically $ deleteFile st sId

    serverStatsThread_ :: XFTPServerConfig -> [M ()]
    serverStatsThread_ XFTPServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1_000_000 * (initialDelay + if initialDelay < 0 then 86_400 else 0)
      FileServerStats {fromTime, filesCreated, fileRecipients, filesUploaded, filesDeleted, filesDownloaded, fileDownloads, fileDownloadAcks, filesCount, filesSize} <- asks serverStats
      let interval = 1_000_000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomically $ swapTVar fromTime ts
          filesCreated' <- atomically $ swapTVar filesCreated 0
          fileRecipients' <- atomically $ swapTVar fileRecipients 0
          filesUploaded' <- atomically $ swapTVar filesUploaded 0
          filesDeleted' <- atomically $ swapTVar filesDeleted 0
          files <- atomically $ periodStatCounts filesDownloaded ts
          fileDownloads' <- atomically $ swapTVar fileDownloads 0
          fileDownloadAcks' <- atomically $ swapTVar fileDownloadAcks 0
          filesCount' <- atomically $ swapTVar filesCount 0
          filesSize' <- atomically $ swapTVar filesSize 0
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show filesCreated',
                show fileRecipients',
                show filesUploaded',
                show filesDeleted',
                dayCount files,
                weekCount files,
                monthCount files,
                show fileDownloads',
                show fileDownloadAcks',
                show filesCount',
                show filesSize'
              ]
        liftIO $ threadDelay' interval

data ServerFile = ServerFile
  { filePath :: FilePath,
    fileSize :: Word32,
    sbState :: LC.SbState
  }

processRequest :: HTTP2Request -> M ()
processRequest HTTP2Request {sessionId, reqBody = body@HTTP2Body {bodyHead}, sendResponse}
  | B.length bodyHead /= xftpBlockSize = sendXFTPResponse ("", "", FRErr BLOCK) Nothing
  | otherwise = do
      case xftpDecodeTransmission sessionId bodyHead of
        Right (sig_, signed, (corrId, fId, cmdOrErr)) -> do
          case cmdOrErr of
            Right cmd -> do
              verifyXFTPTransmission sig_ signed fId cmd >>= \case
                VRVerified req -> uncurry send =<< processXFTPRequest body req
                VRFailed -> send (FRErr AUTH) Nothing
            Left e -> send (FRErr e) Nothing
          where
            send resp = sendXFTPResponse (corrId, fId, resp)
        Left e -> sendXFTPResponse ("", "", FRErr e) Nothing
  where
    sendXFTPResponse :: (CorrId, XFTPFileId, FileResponse) -> Maybe ServerFile -> M ()
    sendXFTPResponse (corrId, fId, resp) serverFile_ = do
      let t_ = xftpEncodeTransmission sessionId Nothing (corrId, fId, resp)
      liftIO $ sendResponse $ H.responseStreaming N.ok200 [] $ streamBody t_
      where
        streamBody t_ send done = do
          case t_ of
            Left _ -> do
              send "padding error" -- TODO respond with BLOCK error?
              done
            Right t -> do
              send $ byteString t
              -- timeout sending file in the same way as receiving
              forM_ serverFile_ $ \ServerFile {filePath, fileSize, sbState} -> do
                withFile filePath ReadMode $ \h -> sendEncFile h send sbState (fromIntegral fileSize)
          done

data VerificationResult = VRVerified XFTPRequest | VRFailed

verifyXFTPTransmission :: Maybe C.ASignature -> ByteString -> XFTPFileId -> FileCmd -> M VerificationResult
verifyXFTPTransmission sig_ signed fId cmd =
  case cmd of
    FileCmd SFSender (FNEW file rcps auth) -> pure $ XFTPReqNew file rcps auth `verifyWith` sndKey file
    FileCmd SFRecipient PING -> pure $ VRVerified XFTPReqPing
    FileCmd party _ -> verifyCmd party
  where
    verifyCmd :: SFileParty p -> M VerificationResult
    verifyCmd party = do
      st <- asks store
      atomically $ verify <$> getFile st party fId
      where
        verify = \case
          Right (fr, k) -> XFTPReqCmd fId fr cmd `verifyWith` k
          _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    req `verifyWith` k = if verifyCmdSignature sig_ signed k then VRVerified req else VRFailed

processXFTPRequest :: HTTP2Body -> XFTPRequest -> M (FileResponse, Maybe ServerFile)
processXFTPRequest HTTP2Body {bodyPart} = \case
  XFTPReqNew file rks auth -> noFile =<< ifM allowNew (createFile file rks) (pure $ FRErr AUTH)
    where
      allowNew = do
        XFTPServerConfig {allowNewFiles, newFileBasicAuth} <- asks config
        pure $ allowNewFiles && maybe True ((== auth) . Just) newFileBasicAuth
  XFTPReqCmd fId fr (FileCmd _ cmd) -> case cmd of
    FADD rks -> noFile =<< addRecipients fId rks
    FPUT -> noFile =<< receiveServerFile fr
    FDEL -> noFile =<< deleteServerFile fr
    FGET rDhKey -> sendServerFile fr rDhKey
    FACK -> noFile =<< ackFileReception fId fr
    -- it should never get to the commands below, they are passed in other constructors of XFTPRequest
    FNEW {} -> noFile $ FRErr INTERNAL
    PING -> noFile FRPong
  XFTPReqPing -> noFile FRPong
  where
    noFile resp = pure (resp, Nothing)
    createFile :: FileInfo -> NonEmpty RcvPublicVerifyKey -> M FileResponse
    createFile file rks = do
      st <- asks store
      r <- runExceptT $ do
        sizes <- asks $ allowedChunkSizes . config
        unless (size file `elem` sizes) $ throwError SIZE
        ts <- liftIO getSystemTime
        -- TODO validate body empty
        sId <- ExceptT $ addFileRetry st file 3 ts
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        withFileLog $ \sl -> do
          logAddFile sl sId file ts
          logAddRecipients sl sId rcps
        stats <- asks serverStats
        atomically $ modifyTVar' (filesCreated stats) (+ 1)
        atomically $ modifyTVar' (fileRecipients stats) (+ length rks)
        let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
        pure $ FRSndIds sId rIds
      pure $ either FRErr id r
    addFileRetry :: FileStore -> FileInfo -> Int -> SystemTime -> M (Either XFTPErrorType XFTPFileId)
    addFileRetry st file n ts =
      retryAdd n $ \sId -> runExceptT $ do
        ExceptT $ addFile st sId file ts
        pure sId
    addRecipientRetry :: FileStore -> Int -> XFTPFileId -> RcvPublicVerifyKey -> M (Either XFTPErrorType FileRecipient)
    addRecipientRetry st n sId rpk =
      retryAdd n $ \rId -> runExceptT $ do
        let rcp = FileRecipient rId rpk
        ExceptT $ addRecipient st sId rcp
        pure rcp
    retryAdd :: Int -> (XFTPFileId -> STM (Either XFTPErrorType a)) -> M (Either XFTPErrorType a)
    retryAdd 0 _ = pure $ Left INTERNAL
    retryAdd n add = do
      fId <- getFileId
      atomically (add fId) >>= \case
        Left DUPLICATE_ -> retryAdd (n - 1) add
        r -> pure r
    addRecipients :: XFTPFileId -> NonEmpty RcvPublicVerifyKey -> M FileResponse
    addRecipients sId rks = do
      st <- asks store
      r <- runExceptT $ do
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        withFileLog $ \sl -> logAddRecipients sl sId rcps
        stats <- asks serverStats
        atomically $ modifyTVar' (fileRecipients stats) (+ length rks)
        let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
        pure $ FRRcvIds rIds
      pure $ either FRErr id r
    receiveServerFile :: FileRec -> M FileResponse
    receiveServerFile fr@FileRec {senderId, fileInfo} = case bodyPart of
      -- TODO do not allow repeated file upload
      Nothing -> pure $ FRErr SIZE
      Just getBody -> do
        -- TODO validate body size before downloading, once it's populated
        path <- asks $ filesPath . config
        let fPath = path </> B.unpack (B64.encode senderId)
            FileInfo {size, digest} = fileInfo
        withFileLog $ \sl -> logPutFile sl senderId fPath
        st <- asks store
        quota_ <- asks $ fileSizeQuota . config
        -- TODO timeout file upload, remove partially uploaded files
        stats <- asks serverStats
        liftIO $
          runExceptT (receiveFile getBody (XFTPRcvChunkSpec fPath size digest)) >>= \case
            Right () -> do
              used <- readTVarIO $ usedStorage st
              if maybe False (used + fromIntegral size >) quota_
                then remove fPath $> FRErr QUOTA
                else do
                  atomically (setFilePath' st fr fPath)
                  atomically $ modifyTVar' (filesUploaded stats) (+ 1)
                  atomically $ modifyTVar' (filesCount stats) (+ 1)
                  atomically $ modifyTVar' (filesSize stats) (+ fromIntegral size)
                  pure FROk
            Left e -> remove fPath $> FRErr e
        where
          remove fPath = whenM (doesFileExist fPath) (removeFile fPath) `catch` logFileError

    sendServerFile :: FileRec -> RcvPublicDhKey -> M (FileResponse, Maybe ServerFile)
    sendServerFile FileRec {senderId, filePath, fileInfo = FileInfo {size}} rDhKey = do
      readTVarIO filePath >>= \case
        Just path -> do
          (sDhKey, spDhKey) <- liftIO C.generateKeyPair'
          let dhSecret = C.dh' rDhKey spDhKey
          cbNonce <- liftIO C.randomCbNonce
          case LC.cbInit dhSecret cbNonce of
            Right sbState -> do
              stats <- asks serverStats
              atomically $ modifyTVar' (fileDownloads stats) (+ 1)
              atomically $ updatePeriodStats (filesDownloaded stats) senderId
              pure (FRFile sDhKey cbNonce, Just ServerFile {filePath = path, fileSize = size, sbState})
            _ -> pure (FRErr INTERNAL, Nothing)
        _ -> pure (FRErr NO_FILE, Nothing)

    deleteServerFile :: FileRec -> M FileResponse
    deleteServerFile FileRec {senderId, fileInfo, filePath} = do
      withFileLog (`logDeleteFile` senderId)
      r <- runExceptT $ do
        path <- readTVarIO filePath
        stats <- asks serverStats
        ExceptT $ first (\(_ :: SomeException) -> FILE_IO) <$> try (forM_ path $ \p -> whenM (doesFileExist p) (removeFile p >> deletedStats stats))
        st <- asks store
        void $ atomically $ deleteFile st senderId
        atomically $ modifyTVar' (filesDeleted stats) (+ 1)
        pure FROk
      either (pure . FRErr) pure r
      where
        deletedStats stats = do
          atomically $ modifyTVar' (filesCount stats) (subtract 1)
          atomically $ modifyTVar' (filesSize stats) (subtract $ fromIntegral $ size fileInfo)

    logFileError :: SomeException -> IO ()
    logFileError e = logError $ "Error deleting file: " <> tshow e

    ackFileReception :: RecipientId -> FileRec -> M FileResponse
    ackFileReception rId fr = do
      withFileLog (`logAckFile` rId)
      st <- asks store
      atomically $ deleteRecipient st rId fr
      stats <- asks serverStats
      atomically $ modifyTVar' (fileDownloadAcks stats) (+ 1)
      pure FROk

randomId :: (MonadUnliftIO m, MonadReader XFTPEnv m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)

getFileId :: M XFTPFileId
getFileId = liftIO . getRandomBytes =<< asks (fileIdSize . config)

withFileLog :: (MonadIO m, MonadReader XFTPEnv m) => (StoreLog 'WriteMode -> IO a) -> m ()
withFileLog action = liftIO . mapM_ action =<< asks storeLog

incFileStat :: (FileServerStats -> TVar Int) -> M ()
incFileStat statSel = do
  stats <- asks serverStats
  atomically $ modifyTVar (statSel stats) (+ 1)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically . getFileServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logInfo $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logInfo "server stats saved"

restoreServerStats :: M ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logInfo $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d -> do
          s <- asks serverStats
          fs <- readTVarIO . files =<< asks store
          let _filesCount = length $ M.keys fs
              _filesSize = M.foldl' (\n -> (n +) . fromIntegral . size . fileInfo) 0 fs
          atomically $ setFileServerStats s d {_filesCount, _filesSize}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
