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
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List (intercalate)
import qualified Data.List.NonEmpty as L
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CorrId, ErrorType (..))
import Simplex.Messaging.Server (dummyVerifyCmd, verifyCmdSignature)
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering)
import UnliftIO (IOMode (..), withFile)
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.STM

-- startServer :: IO ()
-- startServer = do
--   let config =
--         HTTP2ServerConfig
--           { qSize = 64,
--             http2Port = "1234",
--             bufferSize = 32768,
--             bodyHeadSize = 16384,
--             serverSupported = http2TLSParams,
--             caCertificateFile = "tests/fixtures/ca.crt",
--             privateKeyFile = "tests/fixtures/server.key",
--             certificateFile = "tests/fixtures/server.crt",
--             logTLSErrors = True
--           }
--   print "Starting server"
--   http2Server <- getHTTP2Server config
--   qSize <- newTBQueueIO 64
--   action <- async $ runServer qSize http2Server
--   pure ()
--   where
--     runServer qSize HTTP2Server {reqQ} = forever $ do
--       HTTP2Request {reqBody, sendResponse} <- atomically $ readTBQueue reqQ
--       print "Sending response"
--       sendResponse $ H.responseNoBody N.ok200 []

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

processRequest :: HTTP2Request -> M ()
processRequest HTTP2Request {sessionId, reqBody = HTTP2Body {bodyHead}, sendResponse}
  | B.length bodyHead /= xftpBlockSize = sendXFTPResponse ("", "", FRErr BLOCK)
  | otherwise = do
    case xftpDecodeTransmission sessionId bodyHead of
      Right (sig_, signed, (corrId, fId, cmdOrErr)) -> do
        case cmdOrErr of
          Right cmd -> do
            verifyXFTPTransmission sig_ signed fId cmd >>= \case
              VRVerified req -> sendXFTPResponse . (corrId,fId,) =<< processXFTPRequest req
              VRFailed -> sendXFTPResponse (corrId, fId, FRErr AUTH)
          Left e -> sendXFTPResponse (corrId, fId, FRErr e)
      Left e -> sendXFTPResponse ("", "", FRErr e)
  where
    sendXFTPResponse :: (CorrId, XFTPFileId, FileResponse) -> M ()
    sendXFTPResponse (corrId, fId, resp) =
      liftIO . sendResponse . H.responseBuilder N.ok200 [] . lazyByteString . LB.fromStrict $
        case xftpEncodeTransmission sessionId Nothing (corrId, fId, resp) of
          Right t' -> t'
          Left _ -> "padding error" -- TODO respond with BLOCK error

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

processXFTPRequest :: XFTPRequest -> M FileResponse
processXFTPRequest = \case
  XFTPReqNew file rcps -> do
    st <- asks store
    -- TODO retry on duplicate IDs?
    sId <- getFileId
    rIds <- mapM (const getFileId) rcps
    r <- runExceptT $ do
      ExceptT $ atomically $ addFile st sId file
      forM (L.zip rIds rcps) $ \rcp ->
        ExceptT $ atomically $ addRecipient st sId rcp
    pure $ either FRErr (const $ FRSndIds sId rIds) r
  XFTPReqCmd _fr (FileCmd _ cmd) -> case cmd of
    FADD _rcps -> pure FROk
    FPUT -> pure FROk
    FDEL -> pure FROk
    FGET _dhKey -> pure FROk
    FACK -> pure FROk
    -- it should never get to the options below, they are passed in other constructors of XFTPRequest
    FNEW _ _ -> pure $ FRErr INTERNAL
    PING -> pure FRPong
  XFTPReqPing -> pure FRPong

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
