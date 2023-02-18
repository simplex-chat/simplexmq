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
{-# LANGUAGE TupleSections #-}

module Simplex.FileTransfer.Server where

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List (intercalate)
import qualified Data.List.NonEmpty as L
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Transport
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CorrId, RcvPublicDhKey)
import Simplex.Messaging.Server (dummyVerifyCmd, verifyCmdSignature)
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog (StoreLog, closeStoreLog)
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
  raceAny_ (runServer : serverStatsThread_ cfg) `finally` stopServer
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

-- TODO add client DH secret
data ServerFile = ServerFile
  { filePath :: FilePath,
    fileSize :: Word32,
    fileDhSecret :: C.DhSecretX25519
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
            Left _ -> send "padding error" -- TODO respond with BLOCK error?
            Right t -> do
              send $ byteString t
              -- TODO chunk encryption
              forM_ serverFile_ $ \ServerFile {filePath, fileSize, fileDhSecret} ->
                withFile filePath ReadMode $ \h -> sendFile h send $ fromIntegral fileSize
          done

data VerificationResult = VRVerified XFTPRequest | VRFailed

verifyXFTPTransmission :: Maybe C.ASignature -> ByteString -> XFTPFileId -> FileCmd -> M VerificationResult
verifyXFTPTransmission sig_ signed fId cmd =
  case cmd of
    FileCmd SSender (FNEW file rcps) -> pure $ XFTPReqNew file rcps `verifyWith` sndKey file
    FileCmd SRecipient PING -> pure $ VRVerified XFTPReqPing
    FileCmd party _ -> verifyCmd party
  where
    verifyCmd :: SFileParty p -> M VerificationResult
    verifyCmd party = do
      st <- asks store
      atomically $ verify <$> getFile st party fId
      where
        verify = \case
          Right (fr, k) -> XFTPReqCmd fr cmd `verifyWith` k
          _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    req `verifyWith` k = if verifyCmdSignature sig_ signed k then VRVerified req else VRFailed

processXFTPRequest :: HTTP2Body -> XFTPRequest -> M (FileResponse, Maybe ServerFile)
processXFTPRequest HTTP2Body {bodyPart} = \case
  XFTPReqNew file rcps -> do
    st <- asks store
    -- TODO validate body empty
    -- TODO retry on duplicate IDs?
    sId <- getFileId
    rIds <- mapM (const getFileId) rcps
    r <- runExceptT $ do
      ExceptT $ atomically $ addFile st sId file
      forM (L.zip rIds rcps) $ \rcp ->
        ExceptT $ atomically $ addRecipient st sId rcp
    noFile $ either FRErr (const $ FRSndIds sId rIds) r
  XFTPReqCmd fr (FileCmd _ cmd) -> case cmd of
    FADD _rcps -> noFile FROk
    FPUT -> (,Nothing) <$> receiveServerFile fr
    FDEL -> noFile FROk
    FGET dhKey -> sendServerFile fr dhKey
    FACK -> noFile FROk
    -- it should never get to the options below, they are passed in other constructors of XFTPRequest
    FNEW _ _ -> noFile $ FRErr INTERNAL
    PING -> noFile FRPong
  XFTPReqPing -> noFile FRPong
  where
    noFile resp = pure (resp, Nothing)
    receiveServerFile :: FileRec -> M FileResponse
    receiveServerFile FileRec {senderId, fileInfo, filePath} = case bodyPart of
      -- TODO do not allow repeated file upload
      Nothing -> pure $ FRErr SIZE
      Just getBody -> do
        -- TODO validate body size before downloading, once it's populated
        path <- asks $ filesPath . config
        let fPath = path </> B.unpack (B64.encode senderId)
            FileInfo {size, digest} = fileInfo
        liftIO $
          runExceptT (receiveFile getBody (XFTPRcvChunkSpec fPath size digest)) >>= \case
            Right () -> atomically $ writeTVar filePath (Just fPath) $> FROk
            Left e -> whenM (doesFileExist fPath) (removeFile fPath) $> FRErr e

    sendServerFile :: FileRec -> RcvPublicDhKey -> M (FileResponse, Maybe ServerFile)
    sendServerFile FileRec {filePath, fileInfo = FileInfo {size}} rKey = do
      readTVarIO filePath >>= \case
        Just path -> do
          (sKey, spKey) <- liftIO C.generateKeyPair'
          let fileDhSecret = C.dh' rKey spKey
          pure (FRFile sKey, Just ServerFile {filePath = path, fileSize = size, fileDhSecret})
        _ -> pure (FRErr AUTH, Nothing) -- TODO file-specific errors?

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
