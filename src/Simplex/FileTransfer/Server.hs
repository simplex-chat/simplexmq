{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.FileTransfer.Server where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32)
import qualified Data.X509 as X
import GHC.IO.Handle (hSetNewlineMode)
import GHC.Stats (getRTSStats)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Control
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (CorrId (..), RcvPublicAuthKey, RcvPublicDhKey, RecipientId, TransmissionAuth)
import Simplex.Messaging.Server (dummyVerifyCmd, verifyCmdAuthorization)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (SessionId, THandleAuth (..), THandleParams (..))
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.File (fileBlockSize)
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Transport.Server (runTCPServer, tlsServerCredentials)
import Simplex.Messaging.Util
import Simplex.Messaging.Version (isCompatible)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPrint, hPutStrLn, universalNewlineMode)
import UnliftIO
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Directory (doesFileExist, removeFile, renameFile)
import qualified UnliftIO.Exception as E

type M a = ReaderT XFTPEnv IO a

data XFTPTransportRequest = XFTPTransportRequest
  { thParams :: THandleParamsXFTP,
    reqBody :: HTTP2Body,
    request :: H.Request,
    sendResponse :: H.Response -> IO ()
  }

runXFTPServer :: XFTPServerConfig -> IO ()
runXFTPServer cfg = do
  started <- newEmptyTMVarIO
  runXFTPServerBlocking started cfg

runXFTPServerBlocking :: TMVar Bool -> XFTPServerConfig -> IO ()
runXFTPServerBlocking started cfg = newXFTPServerEnv cfg >>= runReaderT (xftpServer cfg started)

data Handshake
  = HandshakeSent C.PrivateKeyX25519
  | HandshakeAccepted THandleAuth VersionXFTP

xftpServer :: XFTPServerConfig -> TMVar Bool -> M ()
xftpServer cfg@XFTPServerConfig {xftpPort, transportConfig, inactiveClientExpiration, fileExpiration} started = do
  mapM_ (expireServerFiles Nothing) fileExpiration
  restoreServerStats
  raceAny_ (runServer : expireFilesThread_ cfg <> serverStatsThread_ cfg <> controlPortThread_ cfg) `finally` stopServer
  where
    runServer :: M ()
    runServer = do
      serverParams <- asks tlsServerParams
      let (chain, pk) = tlsServerCredentials serverParams
      signKey <- liftIO $ case C.x509ToPrivate (pk, []) >>= C.privKey of
        Right pk' -> pure pk'
        Left e -> putStrLn ("servers has no valid key: " <> show e) >> exitFailure
      env <- ask
      sessions <- atomically' TM.empty
      let cleanup sessionId = atomically $ TM.delete sessionId sessions
      liftIO . runHTTP2Server started xftpPort defaultHTTP2BufferSize serverParams transportConfig inactiveClientExpiration cleanup $ \sessionId sessionALPN r sendResponse -> do
        reqBody <- getHTTP2Body r xftpBlockSize
        let thParams0 = THandleParams {sessionId, blockSize = xftpBlockSize, thVersion = VersionXFTP 1, thAuth = Nothing, implySessId = False, batch = True}
            req0 = XFTPTransportRequest {thParams = thParams0, request = r, reqBody, sendResponse}
        flip runReaderT env $ case sessionALPN of
          Nothing -> processRequest req0
          Just "xftp/1" ->
            xftpServerHandshakeV1 chain signKey sessions req0 >>= \case
              Nothing -> pure () -- handshake response sent
              Just thParams -> processRequest req0 {thParams} -- proceed with new version (XXX: may as well switch the request handler here)
          _ -> liftIO . sendResponse $ H.responseNoBody N.ok200 [] -- shouldn't happen: means server picked handshake protocol it doesn't know about
    xftpServerHandshakeV1 :: X.CertificateChain -> C.APrivateSignKey -> TMap SessionId Handshake -> XFTPTransportRequest -> M (Maybe (THandleParams XFTPVersion))
    xftpServerHandshakeV1 chain serverSignKey sessions XFTPTransportRequest {thParams = thParams@THandleParams {sessionId}, reqBody = HTTP2Body {bodyHead}, sendResponse} = do
      s <- atomically $ TM.lookup sessionId sessions
      r <- runExceptT $ case s of
        Nothing -> processHello
        Just (HandshakeSent pk) -> processClientHandshake pk
        Just (HandshakeAccepted auth v) -> pure $ Just thParams {thAuth = Just auth, thVersion = v}
      either sendError pure r
      where
        processHello = do
          unless (B.null bodyHead) $ throwError HANDSHAKE
          (k, pk) <- atomically . C.generateKeyPair =<< asks random
          atomically $ TM.insert sessionId (HandshakeSent pk) sessions
          let authPubKey = (chain, C.signX509 serverSignKey $ C.publicToX509 k)
          let hs = XFTPServerHandshake {xftpVersionRange = supportedFileServerVRange, sessionId, authPubKey}
          shs <- encodeXftp hs
          liftIO . sendResponse $ H.responseBuilder N.ok200 [] shs
          pure Nothing
        processClientHandshake privKey = do
          unless (B.length bodyHead == xftpBlockSize) $ throwError HANDSHAKE
          body <- liftHS $ C.unPad bodyHead
          XFTPClientHandshake {xftpVersion, keyHash, authPubKey} <- liftHS $ smpDecode body
          kh <- asks serverIdentity
          unless (keyHash == kh) $ throwError HANDSHAKE
          unless (xftpVersion `isCompatible` supportedFileServerVRange) $ throwError HANDSHAKE
          let auth = THandleAuth {peerPubKey = authPubKey, privKey}
          atomically $ TM.insert sessionId (HandshakeAccepted auth xftpVersion) sessions
          liftIO . sendResponse $ H.responseNoBody N.ok200 []
          pure Nothing
        sendError :: XFTPErrorType -> M (Maybe (THandleParams XFTPVersion))
        sendError err = do
          runExceptT (encodeXftp err) >>= \case
            Right bs -> liftIO . sendResponse $ H.responseBuilder N.ok200 [] bs
            Left _ -> logError $ "Error encoding handshake error: " <> tshow err
          pure Nothing
        encodeXftp :: Encoding a => a -> ExceptT XFTPErrorType (ReaderT XFTPEnv IO) Builder
        encodeXftp a = byteString <$> liftHS (C.pad (smpEncode a) xftpBlockSize)
        liftHS = liftEitherWith (const HANDSHAKE)

    stopServer :: M ()
    stopServer = do
      withFileLog closeStoreLog
      saveServerStats

    expireFilesThread_ :: XFTPServerConfig -> [M ()]
    expireFilesThread_ XFTPServerConfig {fileExpiration = Just fileExp} = [expireFiles fileExp]
    expireFilesThread_ _ = []

    expireFiles :: ExpirationConfig -> M ()
    expireFiles expCfg = do
      let interval = checkInterval expCfg * 1000000
      forever $ do
        liftIO $ threadDelay' interval
        expireServerFiles (Just 100000) expCfg

    serverStatsThread_ :: XFTPServerConfig -> [M ()]
    serverStatsThread_ XFTPServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M ()
    logServerStats startAt logInterval statsFilePath = do
      initialDelay <- (startAt -) . fromIntegral . (`div` 1000000_000000) . diffTimeToPicoseconds . utctDayTime <$> liftIO getCurrentTime
      liftIO $ putStrLn $ "server stats log enabled: " <> statsFilePath
      liftIO $ threadDelay' $ 1_000_000 * (initialDelay + if initialDelay < 0 then 86_400 else 0)
      FileServerStats {fromTime, filesCreated, fileRecipients, filesUploaded, filesExpired, filesDeleted, filesDownloaded, fileDownloads, fileDownloadAcks, filesCount, filesSize} <- asks serverStats
      let interval = 1_000_000 * logInterval
      forever $ do
        withFile statsFilePath AppendMode $ \h -> liftIO $ do
          hSetBuffering h LineBuffering
          ts <- getCurrentTime
          fromTime' <- atomically' $ swapTVar fromTime ts
          filesCreated' <- atomically' $ swapTVar filesCreated 0
          fileRecipients' <- atomically' $ swapTVar fileRecipients 0
          filesUploaded' <- atomically' $ swapTVar filesUploaded 0
          filesExpired' <- atomically' $ swapTVar filesExpired 0
          filesDeleted' <- atomically' $ swapTVar filesDeleted 0
          files <- atomically' $ periodStatCounts filesDownloaded ts
          fileDownloads' <- atomically' $ swapTVar fileDownloads 0
          fileDownloadAcks' <- atomically' $ swapTVar fileDownloadAcks 0
          filesCount' <- readTVarIO filesCount
          filesSize' <- readTVarIO filesSize
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
                show filesSize',
                show filesExpired'
              ]
        liftIO $ threadDelay' interval

    controlPortThread_ :: XFTPServerConfig -> [M ()]
    controlPortThread_ XFTPServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M ()
    runCPServer port = do
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runTCPServer cpStarted port $ runCPClient u
      where
        runCPClient :: UnliftIO (ReaderT XFTPEnv IO) -> Socket -> IO ()
        runCPClient u sock = do
          labelMyThread "control port client"
          h <- socketToHandle sock ReadWriteMode
          hSetBuffering h LineBuffering
          hSetNewlineMode h universalNewlineMode
          hPutStrLn h "XFTP server control port\n'help' for supported commands"
          role <- newTVarIO CPRNone
          cpLoop h role
          where
            cpLoop h role = do
              s <- trimCR <$> B.hGetLine h
              case strDecode s of
                Right CPQuit -> hClose h
                Right cmd -> logCmd s cmd >> processCP h role cmd >> cpLoop h role
                Left err -> hPutStrLn h ("error: " <> err) >> cpLoop h role
            logCmd s cmd = when shouldLog $ logWarn $ "ControlPort: " <> tshow s
              where
                shouldLog = case cmd of
                  CPAuth _ -> False
                  CPHelp -> False
                  CPQuit -> False
                  CPSkip -> False
                  _ -> True
            processCP h role = \case
              CPAuth auth -> atomically $ writeTVar role $! newRole cfg
                where
                  newRole XFTPServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin}
                    | Just auth == admin = CPRAdmin
                    | Just auth == user = CPRUser
                    | otherwise = CPRNone
              CPStatsRTS -> E.tryAny getRTSStats >>= either (hPrint h) (hPrint h)
              CPDelete fileId -> withUserRole $ unliftIO u $ do
                fs <- asks store
                r <- runExceptT $ do
                  let asSender = ExceptT . atomically' $ getFile fs SFSender fileId
                  let asRecipient = ExceptT . atomically' $ getFile fs SFRecipient fileId
                  (fr, _) <- asSender `catchError` const asRecipient
                  ExceptT $ deleteServerFile_ fr
                liftIO . hPutStrLn h $ either (\e -> "error: " <> show e) (\() -> "ok") r
              CPHelp -> hPutStrLn h "commands: stats-rts, delete, help, quit"
              CPQuit -> pure ()
              CPSkip -> pure ()
              where
                withUserRole action =
                  readTVarIO role >>= \case
                    CPRAdmin -> action
                    CPRUser -> action
                    _ -> do
                      logError "Unauthorized control port command"
                      hPutStrLn h "AUTH"

data ServerFile = ServerFile
  { filePath :: FilePath,
    fileSize :: Word32,
    sbState :: LC.SbState
  }

processRequest :: XFTPTransportRequest -> M ()
processRequest XFTPTransportRequest {thParams, reqBody = body@HTTP2Body {bodyHead}, sendResponse}
  | B.length bodyHead /= xftpBlockSize = sendXFTPResponse ("", "", FRErr BLOCK) Nothing
  | otherwise = do
      case xftpDecodeTransmission thParams bodyHead of
        Right (sig_, signed, (corrId, fId, cmdOrErr)) ->
          case cmdOrErr of
            Right cmd -> do
              let THandleParams {thAuth} = thParams
              verifyXFTPTransmission ((,C.cbNonce (bs corrId)) <$> thAuth) sig_ signed fId cmd >>= \case
                VRVerified req -> uncurry send =<< processXFTPRequest body req
                VRFailed -> send (FRErr AUTH) Nothing
            Left e -> send (FRErr e) Nothing
          where
            send resp = sendXFTPResponse (corrId, fId, resp)
        Left e -> sendXFTPResponse ("", "", FRErr e) Nothing
  where
    sendXFTPResponse (corrId, fId, resp) serverFile_ = do
      let t_ = xftpEncodeTransmission thParams (corrId, fId, resp)
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

verifyXFTPTransmission :: Maybe (THandleAuth, C.CbNonce) -> Maybe TransmissionAuth -> ByteString -> XFTPFileId -> FileCmd -> M VerificationResult
verifyXFTPTransmission auth_ tAuth authorized fId cmd =
  case cmd of
    FileCmd SFSender (FNEW file rcps auth') -> pure $ XFTPReqNew file rcps auth' `verifyWith` sndKey file
    FileCmd SFRecipient PING -> pure $ VRVerified XFTPReqPing
    FileCmd party _ -> verifyCmd party
  where
    verifyCmd :: SFileParty p -> M VerificationResult
    verifyCmd party = do
      st <- asks store
      atomically' $ verify <$> getFile st party fId
      where
        verify = \case
          Right (fr, k) -> XFTPReqCmd fId fr cmd `verifyWith` k
          _ -> maybe False (dummyVerifyCmd Nothing authorized) tAuth `seq` VRFailed
    -- TODO verify with DH authorization
    req `verifyWith` k = if verifyCmdAuthorization auth_ tAuth authorized k then VRVerified req else VRFailed

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
    createFile :: FileInfo -> NonEmpty RcvPublicAuthKey -> M FileResponse
    createFile file rks = do
      st <- asks store
      r <- runExceptT $ do
        sizes <- asks $ allowedChunkSizes . config
        unless (size file `elem` sizes) $ throwError SIZE
        ts <- liftIO getSystemTime
        -- TODO validate body empty
        sId <- ExceptT $ addFileRetry st file 3 ts
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        lift $ withFileLog $ \sl -> do
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
    addRecipientRetry :: FileStore -> Int -> XFTPFileId -> RcvPublicAuthKey -> M (Either XFTPErrorType FileRecipient)
    addRecipientRetry st n sId rpk =
      retryAdd n $ \rId -> runExceptT $ do
        let rcp = FileRecipient rId rpk
        ExceptT $ addRecipient st sId rcp
        pure rcp
    retryAdd :: Int -> (XFTPFileId -> STM (Either XFTPErrorType a)) -> M (Either XFTPErrorType a)
    retryAdd 0 _ = pure $ Left INTERNAL
    retryAdd n add = do
      fId <- getFileId
      atomically' (add fId) >>= \case
        Left DUPLICATE_ -> retryAdd (n - 1) add
        r -> pure r
    addRecipients :: XFTPFileId -> NonEmpty RcvPublicAuthKey -> M FileResponse
    addRecipients sId rks = do
      st <- asks store
      r <- runExceptT $ do
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        lift $ withFileLog $ \sl -> logAddRecipients sl sId rcps
        stats <- asks serverStats
        atomically $ modifyTVar' (fileRecipients stats) (+ length rks)
        let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
        pure $ FRRcvIds rIds
      pure $ either FRErr id r
    receiveServerFile :: FileRec -> M FileResponse
    receiveServerFile FileRec {senderId, fileInfo = FileInfo {size, digest}, filePath} = case bodyPart of
      Nothing -> pure $ FRErr SIZE
      -- TODO validate body size from request before downloading, once it's populated
      Just getBody -> skipCommitted $ ifM reserve receive (pure $ FRErr QUOTA)
        where
          -- having a filePath means the file is already uploaded and committed, must not change anything
          skipCommitted = ifM (isJust <$> readTVarIO filePath) (liftIO $ drain $ fromIntegral size)
            where
              -- can't send FROk without reading the request body or a client will block on sending it
              -- can't send any old error as the client would fail or restart indefinitely
              drain s = do
                bs <- B.length <$> getBody fileBlockSize
                if
                  | bs == s -> pure FROk
                  | bs == 0 || bs > s -> pure $ FRErr SIZE
                  | otherwise -> drain (s - bs)
          reserve = do
            us <- asks $ usedStorage . store
            quota <- asks $ fromMaybe maxBound . fileSizeQuota . config
            atomically . stateTVar us $
              \used -> let used' = used + fromIntegral size in if used' <= quota then (True, used') else (False, used)
          receive = do
            path <- asks $ filesPath . config
            let fPath = path </> B.unpack (B64.encode senderId)
            receiveChunk (XFTPRcvChunkSpec fPath size digest) >>= \case
              Right () -> do
                stats <- asks serverStats
                withFileLog $ \sl -> logPutFile sl senderId fPath
                atomically $ writeTVar filePath (Just fPath)
                atomically $ modifyTVar' (filesUploaded stats) (+ 1)
                atomically $ modifyTVar' (filesCount stats) (+ 1)
                atomically $ modifyTVar' (filesSize stats) (+ fromIntegral size)
                pure FROk
              Left e -> do
                us <- asks $ usedStorage . store
                atomically' . modifyTVar' us $ subtract (fromIntegral size)
                liftIO $ whenM (doesFileExist fPath) (removeFile fPath) `catch` logFileError
                pure $ FRErr e
          receiveChunk spec = do
            t <- asks $ fileTimeout . config
            liftIO $ fromMaybe (Left TIMEOUT) <$> timeout t (runExceptT (receiveFile getBody spec) `catchAll_` pure (Left FILE_IO))
    sendServerFile :: FileRec -> RcvPublicDhKey -> M (FileResponse, Maybe ServerFile)
    sendServerFile FileRec {senderId, filePath, fileInfo = FileInfo {size}} rDhKey = do
      readTVarIO filePath >>= \case
        Just path -> do
          g <- asks random
          (sDhKey, spDhKey) <- atomically $ C.generateKeyPair g
          let dhSecret = C.dh' rDhKey spDhKey
          cbNonce <- atomically $ C.randomCbNonce g
          case LC.cbInit dhSecret cbNonce of
            Right sbState -> do
              stats <- asks serverStats
              atomically $ modifyTVar' (fileDownloads stats) (+ 1)
              atomically' $ updatePeriodStats (filesDownloaded stats) senderId
              pure (FRFile sDhKey cbNonce, Just ServerFile {filePath = path, fileSize = size, sbState})
            _ -> pure (FRErr INTERNAL, Nothing)
        _ -> pure (FRErr NO_FILE, Nothing)

    deleteServerFile :: FileRec -> M FileResponse
    deleteServerFile fr = either FRErr (\() -> FROk) <$> deleteServerFile_ fr

    logFileError :: SomeException -> IO ()
    logFileError e = logError $ "Error deleting file: " <> tshow e

    ackFileReception :: RecipientId -> FileRec -> M FileResponse
    ackFileReception rId fr = do
      withFileLog (`logAckFile` rId)
      st <- asks store
      atomically' $ deleteRecipient st rId fr
      stats <- asks serverStats
      atomically $ modifyTVar' (fileDownloadAcks stats) (+ 1)
      pure FROk

deleteServerFile_ :: FileRec -> M (Either XFTPErrorType ())
deleteServerFile_ FileRec {senderId, fileInfo, filePath} = do
  withFileLog (`logDeleteFile` senderId)
  runExceptT $ do
    path <- readTVarIO filePath
    stats <- asks serverStats
    ExceptT $ first (\(_ :: SomeException) -> FILE_IO) <$> try (forM_ path $ \p -> whenM (doesFileExist p) (removeFile p >> deletedStats stats))
    st <- asks store
    void $ atomically' $ deleteFile st senderId
    atomically $ modifyTVar' (filesDeleted stats) (+ 1)
  where
    deletedStats stats = do
      atomically $ modifyTVar' (filesCount stats) (subtract 1)
      atomically $ modifyTVar' (filesSize stats) (subtract $ fromIntegral $ size fileInfo)

expireServerFiles :: Maybe Int -> ExpirationConfig -> M ()
expireServerFiles itemDelay expCfg = do
  st <- asks store
  usedStart <- readTVarIO $ usedStorage st
  old <- liftIO $ expireBeforeEpoch expCfg
  files' <- readTVarIO (files st)
  logInfo $ "Expiration check: " <> tshow (M.size files') <> " files"
  forM_ (M.keys files') $ \sId -> do
    mapM_ threadDelay itemDelay
    atomically' (expiredFilePath st sId old)
      >>= mapM_ (maybeRemove $ delete st sId)
  usedEnd <- readTVarIO $ usedStorage st
  logInfo $ "Used " <> mbs usedStart <> " -> " <> mbs usedEnd <> ", " <> mbs (usedStart - usedEnd) <> " reclaimed."
  where
    mbs bs = tshow (bs `div` 1048576) <> "mb"
    maybeRemove del = maybe del (remove del)
    remove del filePath =
      ifM
        (doesFileExist filePath)
        ((removeFile filePath >> del) `catch` \(e :: SomeException) -> logError $ "failed to remove expired file " <> tshow filePath <> ": " <> tshow e)
        del
    delete st sId = do
      withFileLog (`logDeleteFile` sId)
      void . atomically' $ deleteFile st sId -- will not update usedStorage if sId isn't in store
      FileServerStats {filesExpired} <- asks serverStats
      atomically $ modifyTVar' filesExpired (+ 1)

randomId :: Int -> M ByteString
randomId n = atomically . C.randomBytes n =<< asks random

getFileId :: M XFTPFileId
getFileId = do
  size <- asks (fileIdSize . config)
  atomically . C.randomBytes size =<< asks random

withFileLog :: (StoreLog 'WriteMode -> IO a) -> M ()
withFileLog action = liftIO . mapM_ action =<< asks storeLog

incFileStat :: (FileServerStats -> TVar Int) -> M ()
incFileStat statSel = do
  stats <- asks serverStats
  atomically $ modifyTVar (statSel stats) (+ 1)

saveServerStats :: M ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= atomically' . getFileServerStatsData >>= liftIO . saveStats f)
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
        Right d@FileServerStatsData {_filesCount = statsFilesCount, _filesSize = statsFilesSize} -> do
          s <- asks serverStats
          FileStore {files, usedStorage} <- asks store
          _filesCount <- M.size <$> readTVarIO files
          _filesSize <- readTVarIO usedStorage
          atomically' $ setFileServerStats s d {_filesCount, _filesSize}
          renameFile f $ f <> ".bak"
          logInfo "server stats restored"
          when (statsFilesCount /= _filesCount) $ logWarn $ "Files count differs: stats: " <> tshow statsFilesCount <> ", store: " <> tshow _filesCount
          when (statsFilesSize /= _filesSize) $ logWarn $ "Files size differs: stats: " <> tshow statsFilesSize <> ", store: " <> tshow _filesSize
          logInfo $ "Restored " <> tshow (_filesSize `div` 1048576) <> " MBs in " <> tshow _filesCount <> " files"
        Left e -> do
          logInfo $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
