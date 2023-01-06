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

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Socket (ServiceName)
import Simplex.Messaging.Client (ProtocolClientError (..))
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ErrorType (..), ProtocolServer (host), SMPServer, SignedTransmission, Transmission, encodeTransmission, tGet, tPut, RecipientId, SenderId)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server
import Simplex.Messaging.Server.Stats
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TProxy, Transport (..))
import Simplex.Messaging.Transport.Server (runTransportServer)
import Simplex.Messaging.Util
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering)
import System.Mem.Weak (deRefWeak)
import UnliftIO (IOMode (..), async, uninterruptibleCancel, withFile)
import UnliftIO.Concurrent (forkIO, killThread, mkWeakThreadId, threadDelay)
import UnliftIO.Directory (doesFileExist, renameFile)
import UnliftIO.Exception
import UnliftIO.STM
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport
import Simplex.FileTransfer.Server.Env (FileServerConfig (FileServerConfig), FileEnv, newFileServerEnv)
import Simplex.FileTransfer.Server.Stats (FileServerStats(..))
import Simplex.FileTransfer.Protocol (FileCmd(..), FileResponse, SFileParty (SRecipient, SSender))
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.X509.Validation (HostName)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2Client, HTTP2ClientError, HTTP2ClientConfig, getHTTP2Client)
import Simplex.Messaging.Transport.HTTP2.Server (getHTTP2Server, HTTP2ServerConfig (..), HTTP2Server (HTTP2Server), HTTP2Request (HTTP2Request, reqBody, sendResponse))
import Simplex.Messaging.Transport.HTTP2 (http2TLSParams)
import Simplex.Messaging.Transport.HTTP2.Server (HTTP2Server(reqQ))
import qualified Network.HTTP2.Server as H
import qualified Network.HTTP.Types as N
import qualified Data.Aeson as J

startServer :: IO ()
startServer = do
  let config = HTTP2ServerConfig {
    qSize = 64,
    http2Port = "1234",
    serverSupported = http2TLSParams,
    caCertificateFile = "tests/fixtures/ca.crt",
    privateKeyFile = "tests/fixtures/server.key",
    certificateFile = "tests/fixtures/server.crt",
    logTLSErrors = True
  }
  print "Starting server"
  http2Server <- getHTTP2Server config
  qSize <- newTBQueueIO 64
  action <- async $ runServer qSize http2Server
  pure ()
  where
    runServer qSize HTTP2Server {reqQ} = forever $ do
      HTTP2Request {reqBody, sendResponse} <- atomically $ readTBQueue reqQ
      print "Sending response"
      sendResponse $ H.responseNoBody N.ok200 []

{-
runFileServer :: FileServerConfig -> IO ()
runFileServer cfg = do
  started <- newEmptyTMVarIO
  runFileServerBlocking started cfg

runFileServerBlocking :: TMVar Bool -> FileServerConfig -> IO ()
runFileServerBlocking started cfg = newFileServerEnv cfg >>= runReaderT (fileServer cfg started)

type M a = ReaderT FileEnv IO a

fileServer :: FileServerConfig -> TMVar Bool -> M ()
fileServer cfg@FileServerConfig {transports, logTLSErrors} started = do
  restoreServerStats
  raceAny_ (map runServer transports <> serverStatsThread_ cfg) `finally` stopServer
  where
    runServer :: (ServiceName, ATransport) -> M ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams logTLSErrors (runClient t)

    runClient :: Transport c => TProxy c -> c -> M ()
    runClient _ h = do
      kh <- asks serverIdentity
      liftIO (runExceptT $ fileServerHandshake h kh supportedFILEServerVRange) >>= \case
        Right th -> runFileClientTransport th
        Left _ -> pure ()

    stopServer :: M ()
    stopServer = do
      withFileLog closeStoreLog
      saveServerStats

    serverStatsThread_ :: FileServerConfig -> [M ()]
    serverStatsThread_ FileServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int -> Int -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      threadDelay $ 1_000_000 * (initialDelay + if initialDelay < 0 then 86_400 else 0)
      FileServerStats {fromTime, fileCreated, recipientAdded, fileUploaded, fileDeleted, fileDownloaded, ackCalled} <- asks serverStats
      let interval = 1_000_000 * logInterval
      withFile statsFilePath AppendMode $ \h -> liftIO $ do
        hSetBuffering h LineBuffering
        forever $ do
          ts <- getCurrentTime
          fromTime' <- atomically $ swapTVar fromTime ts
          fromTime <- newTVar ts
          fileCreated' <- atomically $ swapTVar fileCreated 0
          recipientAdded' <- atomically $ swapTVar recipientAdded 0
          fileUploaded' <- atomically $ swapTVar fileUploaded 0
          fileDeleted' <- atomically $ swapTVar fileDeleted 0
          fileDownloaded' <- atomically $ swapTVar fileDownloaded 0
          ackCalled' <- atomically $ swapTVar ackCalled 0
          hPutStrLn h $
            intercalate
              ","
              [ iso8601Show $ utctDay fromTime',
                show fileCreated',
                show recipientAdded',
                show fileUploaded',
                show fileDeleted',
                show fileDownloaded',
                show ackCalled'
              ]
          threadDelay interval

runFileClientTransport :: Transport c => THandle c -> M ()
runFileClientTransport th@THandle {sessionId} = do
  qSize <- asks $ clientQSize . config
  ts <- liftIO getSystemTime
  c <- atomically $ newFileServerClient qSize sessionId ts
  expCfg <- asks $ inactiveClientExpiration . config
  raceAny_ ([liftIO $ send th c, client c s ps, receive th c] <> disconnectThread_ c expCfg)
    `finally` liftIO (clientDisconnected c)
  where
    disconnectThread_ c expCfg = maybe [] ((: []) . liftIO . disconnectTransport th c activeAt) expCfg

clientDisconnected :: FileServerClient -> IO ()
clientDisconnected FileServerClient {connected} = atomically $ writeTVar connected False

receive :: Transport c => THandle c -> FileServerClient -> M ()
receive th FileServerClient {rcvQ, sndQ, activeAt} = forever $ do
  ts <- tGet th
  forM_ ts $ \t@(_, _, (corrId, entId, cmdOrError)) -> do
    atomically . writeTVar activeAt =<< liftIO getSystemTime
    logDebug "received transmission"
    case cmdOrError of
      Left e -> write sndQ (corrId, entId, NRErr e)
      Right cmd ->
        verifyFileTransmission t cmd >>= \case
          VRVerified req -> write rcvQ req
          VRFailed -> write sndQ (corrId, entId, NRErr AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: Transport c => THandle c -> FileServerClient -> IO ()
send h@THandle {thVersion = v} FileServerClient {sndQ, sessionId, activeAt} = forever $ do
  t <- atomically $ readTBQueue sndQ
  void . liftIO $ tPut h [(Nothing, encodeTransmission v sessionId t)]
  atomically . writeTVar activeAt =<< liftIO getSystemTime

-- instance Show a => Show (TVar a) where
--   show x = unsafePerformIO $ show <$> readTVarIO x

data VerificationResult = VRVerified FileRequest | VRFailed

{- verifyFileTransmission :: SignedTransmission FileCmd -> FileCmd -> M VerificationResult
verifyFileTransmission (sig_, signed, (corrId, entId, _)) cmd = do
  st <- asks store
  case cmd of
    FileCmd SToken c@(TNEW tkn@(NewFileTkn _ k _)) -> do
      r_ <- atomically $ getFileTokenRegistration st tkn
      pure $
        if verifyCmdSignature sig_ signed k
          then case r_ of
            Just t@FileTknData {tknVerifyKey}
              | k == tknVerifyKey -> verifiedTknCmd t c
              | otherwise -> VRFailed
            _ -> VRVerified (FileReqNew corrId (ANE SToken tkn))
          else VRFailed
    FileCmd SToken c -> do
      t_ <- atomically $ getFileToken st entId
      verifyToken t_ (`verifiedTknCmd` c)
    FileCmd SSubscription c@(SNEW sub@(NewFileSub tknId smpQueue _)) -> do
      s_ <- atomically $ findFileSubscription st smpQueue
      case s_ of
        Nothing -> do
          -- TODO move active token check here to differentiate error
          t_ <- atomically $ getActiveFileToken st tknId
          verifyToken' t_ $ VRVerified (FileReqNew corrId (ANE SSubscription sub))
        Just s@FileSubData {tokenId = subTknId} ->
          if subTknId == tknId
            then do
              -- TODO move active token check here to differentiate error
              t_ <- atomically $ getActiveFileToken st subTknId
              verifyToken' t_ $ verifiedSubCmd s c
            else pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    FileCmd SSubscription c -> do
      s_ <- atomically $ getFileSubscription st entId
      case s_ of
        Just s@FileSubData {tokenId = subTknId} -> do
          -- TODO move active token check here to differentiate error
          t_ <- atomically $ getActiveFileToken st subTknId
          verifyToken' t_ $ verifiedSubCmd s c
        _ -> pure $ maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
  where
    verifiedTknCmd t c = VRVerified (FileReqCmd SToken (FileTkn t) (corrId, entId, c))
    verifiedSubCmd s c = VRVerified (FileReqCmd SSubscription (FileSub s) (corrId, entId, c))
    verifyToken :: Maybe FileTknData -> (FileTknData -> VerificationResult) -> M VerificationResult
    verifyToken t_ positiveVerificationResult =
      pure $ case t_ of
        Just t@FileTknData {tknVerifyKey} ->
          if verifyCmdSignature sig_ signed tknVerifyKey
            then positiveVerificationResult t
            else VRFailed
        _ -> maybe False (dummyVerifyCmd signed) sig_ `seq` VRFailed
    verifyToken' :: Maybe FileTknData -> VerificationResult -> M VerificationResult
    verifyToken' t_ = verifyToken t_ . const -}

randomId :: (MonadUnliftIO m, MonadReader FileEnv m) => Int -> m ByteString
randomId n = do
  gVar <- asks idsDrg
  atomically (C.pseudoRandomBytes n gVar)

getIds :: m (RecipientId, SenderId)
getIds = do
  n <- asks $ queueIdBytes . config
  liftM2 (,) (randomId n) (randomId n)

client :: FileServerClient -> M ()
client FileServerClient {rcvQ, sndQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: FileRequest -> M (Transmission FileResponse)
    processCommand = \case
      FileReqNew newFile@(NewFileRec {senderPubKey, recipientKeys, fileSize}) -> do
        logDebug "FNEW - new file"
        let sId = randomId
        withFileLog (`logAddFile` (asks storeLog) "" senderPubKey)
        -- incFileStat tknCreated
        pure ("", NRTknId tknId srvDhPubKey)
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
    getRandomBytes :: Int -> M ByteString
    getRandomBytes n = do
      gVar <- asks idsDrg
      atomically (C.pseudoRandomBytes n gVar)

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
-}