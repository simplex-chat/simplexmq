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
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List (intercalate)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket (ServiceName)
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Transport (ATransport (..), TProxy, Transport (..))
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering)
import UnliftIO (IOMode (..), async, withFile)
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

-- runFileClientTransport :: Transport c => THandle c -> M ()
-- runFileClientTransport th@THandle {sessionId} = do
--   qSize <- asks $ clientQSize . config
--   ts <- liftIO getSystemTime
--   c <- atomically $ newFileServerClient qSize sessionId ts
--   expCfg <- asks $ inactiveClientExpiration . config
--   raceAny_ ([liftIO $ send th c, client c s ps, receive th c] <> disconnectThread_ c expCfg)
--     `finally` liftIO (clientDisconnected c)
--   where
--     disconnectThread_ c expCfg = maybe [] ((: []) . liftIO . disconnectTransport th c activeAt) expCfg

-- clientDisconnected :: FileServerClient -> IO ()
-- clientDisconnected FileServerClient {connected} = atomically $ writeTVar connected False

-- receive :: Transport c => THandle c -> FileServerClient -> M ()
-- receive th FileServerClient {rcvQ, sndQ, activeAt} = forever $ do
--   ts <- tGet th
--   forM_ ts $ \t@(_, _, (corrId, entId, cmdOrError)) -> do
--     atomically . writeTVar activeAt =<< liftIO getSystemTime
--     logDebug "received transmission"
--     case cmdOrError of
--       Left e -> write sndQ (corrId, entId, NRErr e)
--       Right cmd ->
--         verifyFileTransmission t cmd >>= \case
--           VRVerified req -> write rcvQ req
--           VRFailed -> write sndQ (corrId, entId, NRErr AUTH)
--   where
--     write q t = atomically $ writeTBQueue q t

-- send :: Transport c => THandle c -> FileServerClient -> IO ()
-- send h@THandle {thVersion = v} FileServerClient {sndQ, sessionId, activeAt} = forever $ do
--   t <- atomically $ readTBQueue sndQ
--   void . liftIO $ tPut h [(Nothing, encodeTransmission v sessionId t)]
--   atomically . writeTVar activeAt =<< liftIO getSystemTime

-- instance Show a => Show (TVar a) where
--   show x = unsafePerformIO $ show <$> readTVarIO x

processRequest :: HTTP2Request -> M ()
processRequest _ = pure ()

data VerificationResult = VRVerified XFTPRequest | VRFailed

-- verifyFileTransmission :: SignedTransmission FileCmd -> FileCmd -> M VerificationResult
-- verifyFileTransmission (sig_, signed, (corrId, entId, _)) cmd = do
--   st <- asks store
--   case cmd of
--     FileCmd SToken c@(TNEW tkn@(NewFileTkn _ k _)) -> do
--       r_ <- atomically $ getFileTokenRegistration st tkn
--       pure $
--         if verifyCmdSignature sig_ signed k
--           then case r_ of
--             Just t@FileTknData {tknVerifyKey}
--               | k == tknVerifyKey -> verifiedTknCmd t c
--               | otherwise -> VRFailed
--             _ -> VRVerified (FileReqNew corrId (ANE SToken tkn))
--           else VRFailed
--     FileCmd SToken c -> do
--       t_ <- atomically $ getFileToken st entId
--       verifyToken t_ (`verifiedTknCmd` c)
--     FileCmd SSubscription c@(SNEW sub@(NewFileSub tknId smpQueue _)) -> do
--       s_ <- atomically $ findFileSubscription st smpQueue
--       case s_ of
--         Nothing -> do
--           -- TODO move active token check here to differentiate error
--           t_ <- atomically $ getActiveFileToken st tknId
--           verifyToken' t_ $ VRVerified (FileReqNew corrId (ANE SSubscription sub))
--         Just s@FileSubData {tokenId = subTknId} ->
--           if subTknId == tknId
--             then do
--               -- TODO move active token check here to differentiate error
--               t_ <- atomically $ getActiveFileToken st subTknId
--               verifyToken' t_ $ verifiedSubCmd s c
--             else pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
--     FileCmd SSubscription c -> do
--       s_ <- atomically $ getFileSubscription st entId
--       case s_ of
--         Just s@FileSubData {tokenId = subTknId} -> do
--           -- TODO move active token check here to differentiate error
--           t_ <- atomically $ getActiveFileToken st subTknId
--           verifyToken' t_ $ verifiedSubCmd s c
--         _ -> pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
--   where
--     verifiedTknCmd t c = VRVerified (FileReqCmd SToken (FileTkn t) (corrId, entId, c))
--     verifiedSubCmd s c = VRVerified (FileReqCmd SSubscription (FileSub s) (corrId, entId, c))
--     verifyToken :: Maybe FileTknData -> (FileTknData -> VerificationResult) -> M VerificationResult
--     verifyToken t_ positiveVerificationResult =
--       pure $ case t_ of
--         Just t@FileTknData {tknVerifyKey} ->
--           if verifyCmdSignature sig_ signed tknVerifyKey
--             then positiveVerificationResult t
--             else VRFailed
--         _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
--     verifyToken' :: Maybe FileTknData -> VerificationResult -> M VerificationResult
--     verifyToken' t_ = verifyToken t_ . const

randomId :: (MonadUnliftIO m, MonadReader XFTPEnv m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)

-- getIds :: m (RecipientId, SenderId)
-- getIds = do
--   n <- asks $ queueIdBytes . config
--   liftM2 (,) (randomId n) (randomId n)

-- client :: FileServerClient -> M ()
-- client FileServerClient {rcvQ, sndQ} =
--   forever $
--     atomically (readTBQueue rcvQ)
--       >>= processCommand
--       >>= atomically . writeTBQueue sndQ
--   where
--     processCommand :: FileRequest -> M (Transmission FileResponse)
--     processCommand = \case
--       FileReqNew newFile@(NewFileRec {senderPubKey, recipientKeys, fileSize}) -> do
--         logDebug "FNEW - new file"
--         let sId = randomId
--         withFileLog (`logAddFile` (asks storeLog) "" senderPubKey)
--         -- incFileStat tknCreated
--         pure ("", NRTknId tknId srvDhPubKey)
{- FileReqCmd SRecipient (FileTkn tkn@FileTknData {fileTknId, tknStatus, tknRegCode, tknDhSecret, tknDhKeys = (srvDhPubKey, srvDhPrivKey), tknCronInterval}) (corrId, tknId, cmd) -> do
  status <- readTVarIO tknStatus
  (corrId,tknId,) <$> case cmd of
    TNEW (NewFileTkn _ _ dhPubKey) -> do
      logDebug "TNEW - registered token"
      let dhSecret = C.dh' dhPubKey srvDhPrivKey
      -- it is required that DH secret is the same, to avoid failed verifications if notification is delaying
      if tknDhSecret == dhSecret
        then do
          atomically $ writeTBQueue pushQ (tkn, PNVerification tknRegCode)
          pure $ NRTknId fileTknId srvDhPubKey
        else pure $ NRErr AUTH
    TVFY code -- this allows repeated verification for cases when client connection dropped before server response
      | (status == NTRegistered || status == NTConfirmed || status == NTActive) && tknRegCode == code -> do
        logDebug "TVFY - token verified"
        st <- asks store
        atomically $ writeTVar tknStatus NTActive
        tIds <- atomically $ removeInactiveTokenRegistrations st tkn
        forM_ tIds cancelInvervalNotifications
        withFileLog $ \s -> logTokenStatus s tknId NTActive
        incFileStat tknVerified
        pure NROk
      | otherwise -> do
        logDebug "TVFY - incorrect code or token status"
        pure $ NRErr AUTH
    TCHK -> do
      logDebug "TCHK"
      pure $ NRTkn status
    TRPL token' -> do
      logDebug "TRPL - replace token"
      st <- asks store
      regCode <- getRegCode
      atomically $ do
        removeTokenRegistration st tkn
        writeTVar tknStatus NTRegistered
        let tkn' = tkn {token = token', tknRegCode = regCode}
        addFileToken st tknId tkn'
        writeTBQueue pushQ (tkn', PNVerification regCode)
      withFileLog $ \s -> logUpdateToken s tknId token' regCode
      incFileStat tknDeleted
      incFileStat tknCreated
      pure NROk
    TDEL -> do
      logDebug "TDEL"
      st <- asks store
      qs <- atomically $ deleteFileToken st tknId
      forM_ qs $ \SMPQueueFile {smpServer, notifierId} ->
        atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
      cancelInvervalNotifications tknId
      withFileLog (`logDeleteToken` tknId)
      incFileStat tknDeleted
      pure NROk
    TCRN 0 -> do
      logDebug "TCRN 0"
      atomically $ writeTVar tknCronInterval 0
      cancelInvervalNotifications tknId
      withFileLog $ \s -> logTokenCron s tknId 0
      pure NROk
    TCRN int
      | int < 20 -> pure $ NRErr QUOTA
      | otherwise -> do
        logDebug "TCRN"
        atomically $ writeTVar tknCronInterval int
        atomically (TM.lookup tknId intervalNotifiers) >>= \case
          Nothing -> runIntervalNotifier int
          Just IntervalNotifier {interval, action} ->
            unless (interval == int) $ do
              uninterruptibleCancel action
              runIntervalNotifier int
        withFileLog $ \s -> logTokenCron s tknId int
        pure NROk
      where
        runIntervalNotifier interval = do
          action <- async . intervalNotifier $ fromIntegral interval * 1000000 * 60
          let notifier = IntervalNotifier {action, token = tkn, interval}
          atomically $ TM.insert tknId notifier intervalNotifiers
          where
            intervalNotifier delay = forever $ do
              threadDelay delay
              atomically $ writeTBQueue pushQ (tkn, PNCheckMessages)
{- FileReqNew corrId (ANE SSubscription newSub) -> do
  logDebug "SNEW - new subscription"
  st <- asks store
  subId <- getId
  sub <- atomically $ mkFileSubData subId newSub
  resp <-
    atomically (addFileSubscription st subId sub) >>= \case
      Just _ -> atomically (writeTBQueue newSubQ $ FileSub sub) $> NRSubId subId
      _ -> pure $ NRErr AUTH
  withFileLog (`logCreateSubscription` sub)
  incFileStat subCreated
  pure (corrId, "", resp) -}
FileReqCmd SSubscription (FileSub FileSubData {smpQueue = SMPQueueFile {smpServer, notifierId}, notifierKey = registeredNKey, subStatus}) (corrId, subId, cmd) -> do
  status <- readTVarIO subStatus
  (corrId,subId,) <$> case cmd of
    SNEW (NewFileSub _ _ notifierKey) -> do
      logDebug "SNEW - existing subscription"
      -- TODO retry if subscription failed, if pending or AUTH do nothing
      pure $
        if notifierKey == registeredNKey
          then NRSubId subId
          else NRErr AUTH
    SCHK -> do
      logDebug "SCHK"
      pure $ NRSub status
    SDEL -> do
      logDebug "SDEL"
      st <- asks store
      atomically $ deleteFileSubscription st subId
      atomically $ removeSubscription ca smpServer (SPNotifier, notifierId)
      withFileLog (`logDeleteSubscription` subId)
      incFileStat subDeleted
      pure NROk
    PING -> pure NRPong -}
{- getId :: M FileEntityId
getId = getRandomBytes =<< asks (subIdBytes . config)
getRegCode :: M FileRegCode
getRegCode = FileRegCode <$> (getRandomBytes =<< asks (regCodeBytes . config)) -}
--     getRandomBytes :: Int -> M ByteString
--     getRandomBytes n = do
--       gVar <- asks idsDrg
--       atomically (C.pseudoRandomBytes n gVar)

-- -}

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
