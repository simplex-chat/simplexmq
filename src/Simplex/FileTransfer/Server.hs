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
xftpServer cfg@XFTPServerConfig {xftpPort, logTLSErrors} started = do
  restoreServerStats
  raceAny_ (runServer : expireFilesThread_ cfg <> serverStatsThread_ cfg) `finally` stopServer
  where
    runServer :: M ()
    runServer = do
      serverParams <- asks tlsServerParams
      env <- ask
      liftIO $
        runHTTP2Server started xftpPort defaultHTTP2BufferSize serverParams logTLSErrors $ \sessionId r sendResponse -> do
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
        threadDelay interval
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

    logServerStats :: Int -> Int -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      threadDelay $ 1_000_000 * (initialDelay + if initialDelay < 0 then 86_400 else 0)
      FileServerStats {fromTime, filesCreated, fileRecipients, filesUploaded, filesDeleted, filesDownloaded, fileDownloads, fileDownloadAcks} <- asks serverStats
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
                show fileDownloadAcks'
              ]
        threadDelay interval

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
              forM_ serverFile_ $ \ServerFile {filePath, fileSize, sbState} -> do
                withFile filePath ReadMode $ \h -> sendEncFile h send sbState (fromIntegral fileSize)
          done

data VerificationResult = VRVerified XFTPRequest | VRFailed

verifyXFTPTransmission :: Maybe C.ASignature -> ByteString -> XFTPFileId -> FileCmd -> M VerificationResult
verifyXFTPTransmission sig_ signed fId cmd =
  case cmd of
    FileCmd SSender (FNEW file rcps auth) -> pure $ XFTPReqNew file rcps auth `verifyWith` sndKey file
    FileCmd SRecipient PING -> pure $ VRVerified XFTPReqPing
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
  XFTPReqNew file rks auth -> do
    st <- asks store
    noFile
      =<< ifM
        allowNew
        (createFile st file rks)
        (pure $ FRErr AUTH)
    where
      allowNew = do
        XFTPServerConfig {allowNewFiles, newFileBasicAuth} <- asks config
        pure $ allowNewFiles && maybe True ((== auth) . Just) newFileBasicAuth
  XFTPReqCmd fId fr (FileCmd _ cmd) -> case cmd of
    FADD _rcps -> noFile FROk
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
    createFile :: FileStore -> FileInfo -> NonEmpty RcvPublicVerifyKey -> M FileResponse
    createFile st file rks = do
      -- TODO validate body empty
      ts <- liftIO getSystemTime
      addFileRetry 3 ts >>= \case
        Left e -> pure $ FRErr e
        Right sId -> do
          addRecipients sId >>= \case
            Left e -> pure $ FRErr e
            Right rcps -> do
              withFileLog $ \sl -> do
                logAddFile sl sId file ts
                logAddRecipients sl sId rcps
              let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
              pure $ FRSndIds sId rIds
      where
        addFileRetry :: Int -> SystemTime -> M (Either XFTPErrorType XFTPFileId)
        addFileRetry 0 _ = pure $ Left INTERNAL
        addFileRetry n ts = do
          sId <- getFileId
          atomically (addFile st sId file ts) >>= \case
            Left DUPLICATE_ -> addFileRetry (n - 1) ts
            Left e -> pure $ Left e
            Right _ -> pure $ Right sId
        addRecipients :: XFTPFileId -> M (Either XFTPErrorType (NonEmpty FileRecipient))
        addRecipients sId = do
          rcps <- traverse (addRecipientRetry 3 sId) rks
          case sequence rcps of
            Left e -> pure $ Left e
            Right rcps' -> pure $ Right rcps'
        addRecipientRetry :: Int -> XFTPFileId -> RcvPublicVerifyKey -> M (Either XFTPErrorType FileRecipient)
        addRecipientRetry 0 _ _ = pure $ Left INTERNAL
        addRecipientRetry n sId rpk = do
          rId <- getFileId
          let rcp = FileRecipient rId rpk
          atomically (addRecipient st sId rcp) >>= \case
            Left DUPLICATE_ -> addRecipientRetry (n - 1) sId rpk
            Left e -> pure $ Left e
            Right _ -> pure $ Right rcp
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
        liftIO $
          runExceptT (receiveFile getBody (XFTPRcvChunkSpec fPath size digest)) >>= \case
            Right () -> do
              used <- readTVarIO $ usedStorage st
              if maybe False (used + fromIntegral size >) quota_
                then remove fPath $> FRErr QUOTA
                else atomically (setFilePath' st fr fPath) $> FROk
            Left e -> remove fPath $> FRErr e
        where
          remove fPath = whenM (doesFileExist fPath) (removeFile fPath) `catch` logFileError

    sendServerFile :: FileRec -> RcvPublicDhKey -> M (FileResponse, Maybe ServerFile)
    sendServerFile FileRec {filePath, fileInfo = FileInfo {size}} rDhKey = do
      readTVarIO filePath >>= \case
        Just path -> do
          (sDhKey, spDhKey) <- liftIO C.generateKeyPair'
          let dhSecret = C.dh' rDhKey spDhKey
          cbNonce <- liftIO C.randomCbNonce
          pure $ case LC.cbInit dhSecret cbNonce of
            Right sbState -> (FRFile sDhKey cbNonce, Just ServerFile {filePath = path, fileSize = size, sbState})
            _ -> (FRErr INTERNAL, Nothing)
        _ -> pure (FRErr NO_FILE, Nothing)

    deleteServerFile :: FileRec -> M FileResponse
    deleteServerFile FileRec {senderId, filePath} = do
      withFileLog (`logDeleteFile` senderId)
      r <- runExceptT $ do
        path <- readTVarIO filePath
        ExceptT $ first (\(_ :: SomeException) -> FILE_IO) <$> try (forM_ path $ \p -> whenM (doesFileExist p) (removeFile p))
        st <- asks store
        void $ atomically $ deleteFile st senderId
        pure FROk
      either (pure . FRErr) pure r

    logFileError :: SomeException -> IO ()
    logFileError e = logError $ "Error deleting file: " <> tshow e

    ackFileReception :: RecipientId -> FileRec -> M FileResponse
    ackFileReception rId fr = do
      withFileLog (`logAckFile` rId)
      st <- asks store
      atomically $ deleteRecipient st rId fr
      pure FROk

randomId :: (MonadUnliftIO m, MonadReader XFTPEnv m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)

getFileId :: M XFTPFileId
getFileId = liftIO . getRandomBytes =<< asks (fileIdSize . config)

withFileLog :: (StoreLog 'WriteMode -> IO a) -> M ()
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
          atomically $ setFileServerStats s d
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
