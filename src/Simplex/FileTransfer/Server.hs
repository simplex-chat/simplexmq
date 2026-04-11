{-# LANGUAGE CPP #-}
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
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.FileTransfer.Server
  ( runXFTPServer,
    runXFTPServerBlocking,
  ) where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime (..), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word32)
import qualified Data.X509 as X
import GHC.IO.Handle (hSetNewlineMode)
import GHC.IORef (atomicSwapIORef)
import GHC.Stats (getRTSStats)
import qualified Network.HTTP.Types as N
import Network.HPACK.Token (tokenKey)
import qualified Network.HTTP2.Server as H
import Network.Socket
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Control (ControlProtocol (..))
import Simplex.FileTransfer.Server.Env
import Simplex.FileTransfer.Server.Prometheus
import Simplex.FileTransfer.Server.Stats
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BlockingInfo, EntityId (..), RcvPublicAuthKey, RcvPublicDhKey, RecipientId, SignedTransmission, pattern NoEntity)
import Simplex.Messaging.Server (controlPortAuth, dummyVerifyCmd, verifyCmdAuthorization)
import Simplex.Messaging.Server.Control (CPClientRole (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.SystemTime
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (CertChainPubKey (..), SessionId, THandleAuth (..), THandleParams (..), TransportPeer (..), defaultSupportedParams, defaultSupportedParamsHTTPS)
import Simplex.Messaging.Transport.Buffer (trimCR)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.File (fileBlockSize)
import Simplex.Messaging.Transport.HTTP2.Server (runHTTP2Server)
import Simplex.Messaging.Transport.Server (SNICredentialUsed, TransportServerConfig (..), runLocalTCPServer)
import Simplex.Messaging.Server.Web (serveStaticPageH2)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPrint, hPutStrLn, universalNewlineMode)
#ifdef slow_servers
import System.Random (getStdRandom, randomR)
#endif
import UnliftIO
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Directory (canonicalizePath, doesFileExist, removeFile, renameFile)
import qualified UnliftIO.Exception as E

type M s a = ReaderT (XFTPEnv s) IO a

data XFTPTransportRequest = XFTPTransportRequest
  { thParams :: THandleParamsXFTP 'TServer,
    reqBody :: HTTP2Body,
    request :: H.Request,
    sendResponse :: H.Response -> IO (),
    sniUsed :: SNICredentialUsed,
    addCORS :: Bool
  }

corsHeaders :: Bool -> [N.Header]
corsHeaders addCORS
  | addCORS = [("Access-Control-Allow-Origin", "*"), ("Access-Control-Expose-Headers", "*")]
  | otherwise = []

corsPreflightHeaders :: [N.Header]
corsPreflightHeaders =
  [ ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "POST, OPTIONS"),
    ("Access-Control-Allow-Headers", "*"),
    ("Access-Control-Max-Age", "86400")
  ]

runXFTPServer :: FileStoreClass s => XFTPServerConfig s -> IO ()
runXFTPServer cfg = do
  started <- newEmptyTMVarIO
  runXFTPServerBlocking started cfg

runXFTPServerBlocking :: FileStoreClass s => TMVar Bool -> XFTPServerConfig s -> IO ()
runXFTPServerBlocking started cfg = newXFTPServerEnv cfg >>= runReaderT (xftpServer cfg started)

data Handshake
  = HandshakeSent C.PrivateKeyX25519
  | HandshakeAccepted (THandleParams XFTPVersion 'TServer)

xftpServer :: forall s. FileStoreClass s => XFTPServerConfig s -> TMVar Bool -> M s ()
xftpServer cfg@XFTPServerConfig {xftpPort, transportConfig, inactiveClientExpiration, fileExpiration, xftpServerVRange} started = do
  mapM_ (expireServerFiles Nothing) fileExpiration
  restoreServerStats
  raceAny_
    ( runServer
        : expireFilesThread_ cfg
          <> serverStatsThread_ cfg
          <> prometheusMetricsThread_ cfg
          <> controlPortThread_ cfg
    )
    `finally` stopServer
  where
    runServer :: M s ()
    runServer = do
      srvCreds@(chain, pk) <- asks tlsServerCreds
      httpCreds_ <- asks httpServerCreds
      signKey <- liftIO $ case C.x509ToPrivate' pk of
        Right pk' -> pure pk'
        Left e -> putStrLn ("Server has no valid key: " <> show e) >> exitFailure
      env <- ask
      sessions <- liftIO TM.emptyIO
      let cleanup sessionId = atomically $ TM.delete sessionId sessions
          srvParams = if isJust httpCreds_ then defaultSupportedParamsHTTPS else defaultSupportedParams
      webCanonicalRoot_ <- liftIO $ mapM canonicalizePath (webStaticPath cfg)
      liftIO . runHTTP2Server started xftpPort defaultHTTP2BufferSize srvParams srvCreds httpCreds_ transportConfig inactiveClientExpiration cleanup $ \sniUsed sessionId sessionALPN r sendResponse -> do
        let addCORS' = sniUsed && addCORSHeaders transportConfig
        case H.requestMethod r of
          Just "OPTIONS" | addCORS' -> sendResponse $ H.responseNoBody N.ok200 corsPreflightHeaders
          Just "GET" | sniUsed -> forM_ webCanonicalRoot_ $ \root -> serveStaticPageH2 root r sendResponse
          _ -> do
            reqBody <- getHTTP2Body r xftpBlockSize
            let v = VersionXFTP 1
                thServerVRange = versionToRange v
                thParams0 = THandleParams {sessionId, blockSize = xftpBlockSize, thVersion = v, thServerVRange, thAuth = Nothing, implySessId = False, encryptBlock = Nothing, batch = True, serviceAuth = False}
                req0 = XFTPTransportRequest {thParams = thParams0, request = r, reqBody, sendResponse, sniUsed, addCORS = addCORS'}
            flip runReaderT env $ case sessionALPN of
              Nothing -> processRequest req0
              Just alpn
                | alpn == xftpALPNv1 || alpn == httpALPN11 || (sniUsed && alpn == "h2") ->
                    xftpServerHandshakeV1 chain signKey sessions req0 >>= \case
                      Nothing -> pure ()
                      Just thParams -> processRequest req0 {thParams}
                | otherwise -> liftIO . sendResponse $ H.responseNoBody N.ok200 (corsHeaders addCORS')
    xftpServerHandshakeV1 :: X.CertificateChain -> C.APrivateSignKey -> TMap SessionId Handshake -> XFTPTransportRequest -> M s (Maybe (THandleParams XFTPVersion 'TServer))
    xftpServerHandshakeV1 chain serverSignKey sessions XFTPTransportRequest {thParams = thParams0@THandleParams {sessionId}, request, reqBody = HTTP2Body {bodyHead}, sendResponse, sniUsed, addCORS} = do
      s <- atomically $ TM.lookup sessionId sessions
      r <- runExceptT $ case s of
        Nothing
          | sniUsed && not webHello -> throwE SESSION
          | otherwise -> processHello Nothing
        Just (HandshakeSent pk)
          | webHello -> processHello (Just pk)
          | otherwise -> processClientHandshake pk
        Just (HandshakeAccepted thParams)
          | webHello -> processHello (serverPrivKey <$> thAuth thParams)
          | webHandshake, Just auth <- thAuth thParams -> processClientHandshake (serverPrivKey auth)
          | otherwise -> pure $ Just thParams
      either sendError pure r
      where
        webHello = sniUsed && any (\(t, _) -> tokenKey t == "xftp-web-hello") (fst $ H.requestHeaders request)
        webHandshake = sniUsed && any (\(t, _) -> tokenKey t == "xftp-handshake") (fst $ H.requestHeaders request)
        processHello pk_ = do
          challenge_ <-
            if
              | B.null bodyHead -> pure Nothing
              | sniUsed -> do
                  body <- liftHS $ C.unPad bodyHead
                  XFTPClientHello {webChallenge} <- liftHS $ first show (smpDecode body)
                  pure webChallenge
              | otherwise -> throwE HANDSHAKE
          rng <- asks random
          k <- atomically $ TM.lookup sessionId sessions >>= \case
            Just (HandshakeSent pk') -> pure $ C.publicKey pk'
            _ -> do
              kp <- maybe (C.generateKeyPair rng) (\p -> pure (C.publicKey p, p)) pk_
              fst kp <$ TM.insert sessionId (HandshakeSent $ snd kp) sessions
          let authPubKey = CertChainPubKey chain (C.signX509 serverSignKey $ C.publicToX509 k)
              webIdentityProof = C.sign serverSignKey . (<> sessionId) <$> challenge_
          let hs = XFTPServerHandshake {xftpVersionRange = xftpServerVRange, sessionId, authPubKey, webIdentityProof}
          shs <- encodeXftp hs
#ifdef slow_servers
          lift randomDelay
#endif
          liftIO . sendResponse $ H.responseBuilder N.ok200 (corsHeaders addCORS) shs
          pure Nothing
        processClientHandshake pk = do
          unless (B.length bodyHead == xftpBlockSize) $ throwE HANDSHAKE
          body <- liftHS $ C.unPad bodyHead
          XFTPClientHandshake {xftpVersion = v, keyHash} <- liftHS $ smpDecode body
          kh <- asks serverIdentity
          unless (keyHash == kh) $ throwE HANDSHAKE
          case compatibleVRange' xftpServerVRange v of
            Just (Compatible vr) -> do
              let auth = THAuthServer {serverPrivKey = pk, peerClientService = Nothing, sessSecret' = Nothing}
                  thParams = thParams0 {thAuth = Just auth, thVersion = v, thServerVRange = vr}
              atomically $ TM.insert sessionId (HandshakeAccepted thParams) sessions
#ifdef slow_servers
              lift randomDelay
#endif
              liftIO . sendResponse $ H.responseNoBody N.ok200 (corsHeaders addCORS)
              pure Nothing
            Nothing -> throwE HANDSHAKE
        sendError :: XFTPErrorType -> M s (Maybe (THandleParams XFTPVersion 'TServer))
        sendError err = do
          runExceptT (encodeXftp err) >>= \case
            Right bs -> liftIO . sendResponse $ H.responseBuilder N.ok200 (corsHeaders addCORS) bs
            Left _ -> logError $ "Error encoding handshake error: " <> tshow err
          pure Nothing
        encodeXftp :: Encoding a => a -> ExceptT XFTPErrorType (ReaderT (XFTPEnv s) IO) Builder
        encodeXftp a = byteString <$> liftHS (C.pad (smpEncode a) xftpBlockSize)
        liftHS = liftEitherWith (const HANDSHAKE)

    stopServer :: M s ()
    stopServer = do
      st <- asks store
      liftIO $ closeFileStore st
      saveServerStats
      logNote "Server stopped"

    expireFilesThread_ :: XFTPServerConfig s -> [M s ()]
    expireFilesThread_ XFTPServerConfig {fileExpiration = Just fileExp} = [expireFiles fileExp]
    expireFilesThread_ _ = []

    expireFiles :: ExpirationConfig -> M s ()
    expireFiles expCfg = do
      let interval = checkInterval expCfg * 1000000
      forever $ do
        liftIO $ threadDelay' interval
        expireServerFiles (Just 100000) expCfg

    serverStatsThread_ :: XFTPServerConfig s -> [M s ()]
    serverStatsThread_ XFTPServerConfig {logStatsInterval = Just interval, logStatsStartTime, serverStatsLogFile} =
      [logServerStats logStatsStartTime interval serverStatsLogFile]
    serverStatsThread_ _ = []

    logServerStats :: Int64 -> Int64 -> FilePath -> M s ()
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
          fromTime' <- atomicSwapIORef fromTime ts
          filesCreated' <- atomicSwapIORef filesCreated 0
          fileRecipients' <- atomicSwapIORef fileRecipients 0
          filesUploaded' <- atomicSwapIORef filesUploaded 0
          filesExpired' <- atomicSwapIORef filesExpired 0
          filesDeleted' <- atomicSwapIORef filesDeleted 0
          files <- liftIO $ periodStatCounts filesDownloaded ts
          fileDownloads' <- atomicSwapIORef fileDownloads 0
          fileDownloadAcks' <- atomicSwapIORef fileDownloadAcks 0
          filesCount' <- readIORef filesCount
          filesSize' <- readIORef filesSize
          T.hPutStrLn h $
            T.intercalate
              ","
              [ T.pack $ iso8601Show $ utctDay fromTime',
                tshow filesCreated',
                tshow fileRecipients',
                tshow filesUploaded',
                tshow filesDeleted',
                dayCount files,
                weekCount files,
                monthCount files,
                tshow fileDownloads',
                tshow fileDownloadAcks',
                tshow filesCount',
                tshow filesSize',
                tshow filesExpired'
              ]
        liftIO $ threadDelay' interval

    prometheusMetricsThread_ :: XFTPServerConfig s -> [M s ()]
    prometheusMetricsThread_ XFTPServerConfig {prometheusInterval = Just interval, prometheusMetricsFile} =
      [savePrometheusMetrics interval prometheusMetricsFile]
    prometheusMetricsThread_ _ = []

    savePrometheusMetrics :: Int -> FilePath -> M s ()
    savePrometheusMetrics saveInterval metricsFile = do
      labelMyThread "savePrometheusMetrics"
      liftIO $ putStrLn $ "Prometheus metrics saved every " <> show saveInterval <> " seconds to " <> metricsFile
      ss <- asks serverStats
      rtsOpts <- liftIO $ maybe ("set " <> rtsOptionsEnv) T.pack <$> lookupEnv (T.unpack rtsOptionsEnv)
      let interval = 1000000 * saveInterval
      liftIO $ forever $ do
        threadDelay interval
        ts <- getCurrentTime
        sm <- getFileServerMetrics ss rtsOpts
        T.writeFile metricsFile $ xftpPrometheusMetrics sm ts

    getFileServerMetrics :: FileServerStats -> T.Text -> IO FileServerMetrics
    getFileServerMetrics ss rtsOptions = do
      d <- getFileServerStatsData ss
      let fd = periodStatDataCounts $ _filesDownloaded d
      pure FileServerMetrics {statsData = d, filesDownloadedPeriods = fd, rtsOptions}

    controlPortThread_ :: XFTPServerConfig s -> [M s ()]
    controlPortThread_ XFTPServerConfig {controlPort = Just port} = [runCPServer port]
    controlPortThread_ _ = []

    runCPServer :: ServiceName -> M s ()
    runCPServer port = do
      cpStarted <- newEmptyTMVarIO
      u <- askUnliftIO
      liftIO $ do
        labelMyThread "control port server"
        runLocalTCPServer cpStarted port $ runCPClient u
      where
        runCPClient :: UnliftIO (ReaderT (XFTPEnv s) IO) -> Socket -> IO ()
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
              CPAuth auth -> controlPortAuth h user admin role auth
                where
                  XFTPServerConfig {controlPortUserAuth = user, controlPortAdminAuth = admin} = cfg
              CPStatsRTS -> E.tryAny getRTSStats >>= either (hPrint h) (hPrint h)
              CPDelete fileId -> withUserRole $ unliftIO u $ do
                fs <- asks store
                r <- runExceptT $ do
                  (fr, _) <- ExceptT $ liftIO $ getFile fs SFRecipient fileId
                  ExceptT $ deleteServerFile_ fr
                liftIO . hPutStrLn h $ either (\e -> "error: " <> show e) (\() -> "ok") r
              CPBlock fileId info -> withUserRole $ unliftIO u $ do
                fs <- asks store
                r <- runExceptT $ do
                  (fr, _) <- ExceptT $ liftIO $ getFile fs SFRecipient fileId
                  ExceptT $ blockServerFile fr info
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

processRequest :: FileStoreClass s => XFTPTransportRequest -> M s ()
processRequest XFTPTransportRequest {thParams, reqBody = body@HTTP2Body {bodyHead}, sendResponse, addCORS}
  | B.length bodyHead /= xftpBlockSize = sendXFTPResponse ("", NoEntity, FRErr BLOCK) Nothing
  | otherwise =
      case xftpDecodeTServer thParams bodyHead of
        Right (Right t@(_, _, (corrId, fId, _))) -> do
          let THandleParams {thAuth} = thParams
          verifyXFTPTransmission thAuth t >>= \case
            VRVerified req -> uncurry send =<< processXFTPRequest body req
            VRFailed e -> send (FRErr e) Nothing
          where
            send resp = sendXFTPResponse (corrId, fId, resp)
        Right (Left (corrId, fId, e)) -> sendXFTPResponse (corrId, fId, FRErr e) Nothing
        Left e -> sendXFTPResponse ("", NoEntity, FRErr e) Nothing
  where
    sendXFTPResponse t' serverFile_ = do
      let t_ = xftpEncodeTransmission thParams t'
#ifdef slow_servers
      randomDelay
#endif
      liftIO $ sendResponse $ H.responseStreaming N.ok200 (corsHeaders addCORS) $ streamBody t_
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
                withFile filePath ReadMode $ \h -> sendEncFile h send sbState fileSize
          done

#ifdef slow_servers
randomDelay :: M s ()
randomDelay = do
  d <- asks $ responseDelay . config
  when (d > 0) $ do
    pc <- getStdRandom (randomR (-200, 200))
    threadDelay $ (d * (1000 + pc)) `div` 1000
#endif

data VerificationResult = VRVerified XFTPRequest | VRFailed XFTPErrorType

verifyXFTPTransmission :: forall s. FileStoreClass s => Maybe (THandleAuth 'TServer) -> SignedTransmission FileCmd -> M s VerificationResult
verifyXFTPTransmission thAuth (tAuth, authorized, (corrId, fId, cmd)) =
  case cmd of
    FileCmd SFSender (FNEW file rcps auth') -> pure $ XFTPReqNew file rcps auth' `verifyWith` sndKey file
    FileCmd SFRecipient PING -> pure $ VRVerified XFTPReqPing
    FileCmd party _ -> verifyCmd party
  where
    verifyCmd :: SFileParty p -> M s VerificationResult
    verifyCmd party = do
      st <- asks store
      liftIO $ verify =<< getFile st party fId
      where
        verify = \case
          Right (fr, k) -> result <$> readTVarIO (fileStatus fr)
            where
              result = \case
                EntityActive -> XFTPReqCmd fId fr cmd `verifyWith` k
                EntityBlocked info -> VRFailed $ BLOCKED info
                EntityOff -> noFileAuth
          Left _ -> pure noFileAuth
        noFileAuth = dummyVerifyCmd thAuth tAuth authorized corrId `seq` VRFailed AUTH
    -- TODO verify with DH authorization
    req `verifyWith` k = if verifyCmdAuthorization thAuth tAuth authorized corrId k then VRVerified req else VRFailed AUTH

processXFTPRequest :: forall s. FileStoreClass s => HTTP2Body -> XFTPRequest -> M s (FileResponse, Maybe ServerFile)
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
    PING -> noFile $ FRErr INTERNAL
  XFTPReqPing -> noFile FRPong
  where
    noFile resp = pure (resp, Nothing)
    createFile :: FileInfo -> NonEmpty RcvPublicAuthKey -> M s FileResponse
    createFile file rks = do
      st <- asks store
      r <- runExceptT $ do
        sizes <- asks $ allowedChunkSizes . config
        unless (size file `elem` sizes) $ throwE SIZE
        ts <- liftIO getFileTime
        -- TODO validate body empty
        sId <- ExceptT $ addFileRetry st file 3 ts
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        lift $ withFileLog $ \sl -> do
          logAddFile sl sId file ts EntityActive
          logAddRecipients sl sId rcps
        stats <- asks serverStats
        lift $ incFileStat filesCreated
        liftIO $ atomicModifyIORef'_ (fileRecipients stats) (+ length rks)
        let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
        pure $ FRSndIds sId rIds
      pure $ either FRErr id r
    addFileRetry :: s -> FileInfo -> Int -> RoundedFileTime -> M s (Either XFTPErrorType XFTPFileId)
    addFileRetry st file n ts =
      retryAdd n $ \sId -> runExceptT $ do
        ExceptT $ addFile st sId file ts EntityActive
        pure sId
    addRecipientRetry :: s -> Int -> XFTPFileId -> RcvPublicAuthKey -> M s (Either XFTPErrorType FileRecipient)
    addRecipientRetry st n sId rpk =
      retryAdd n $ \rId -> runExceptT $ do
        let rcp = FileRecipient rId rpk
        ExceptT $ addRecipient st sId rcp
        pure rcp
    retryAdd :: Int -> (XFTPFileId -> IO (Either XFTPErrorType a)) -> M s (Either XFTPErrorType a)
    retryAdd 0 _ = pure $ Left INTERNAL
    retryAdd n add = do
      fId <- getFileId
      liftIO (add fId) >>= \case
        Left DUPLICATE_ -> retryAdd (n - 1) add
        r -> pure r
    addRecipients :: XFTPFileId -> NonEmpty RcvPublicAuthKey -> M s FileResponse
    addRecipients sId rks = do
      st <- asks store
      r <- runExceptT $ do
        rcps <- mapM (ExceptT . addRecipientRetry st 3 sId) rks
        lift $ withFileLog $ \sl -> logAddRecipients sl sId rcps
        stats <- asks serverStats
        liftIO $ atomicModifyIORef'_ (fileRecipients stats) (+ length rks)
        let rIds = L.map (\(FileRecipient rId _) -> rId) rcps
        pure $ FRRcvIds rIds
      pure $ either FRErr id r
    receiveServerFile :: FileRec -> M s FileResponse
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
            us <- asks usedStorage
            quota <- asks $ fromMaybe maxBound . fileSizeQuota . config
            atomically . stateTVar us $
              \used -> let used' = used + fromIntegral size in if used' <= quota then (True, used') else (False, used)
          receive = do
            path <- asks $ filesPath . config
            let fPath = path </> B.unpack (B64.encode $ unEntityId senderId)
            receiveChunk (XFTPRcvChunkSpec fPath size digest) >>= \case
              Right () -> do
                stats <- asks serverStats
                st <- asks store
                liftIO (setFilePath st senderId fPath) >>= \case
                  Right () -> do
                    withFileLog $ \sl -> logPutFile sl senderId fPath
                    incFileStat filesUploaded
                    incFileStat filesCount
                    liftIO $ atomicModifyIORef'_ (filesSize stats) (+ fromIntegral size)
                    pure FROk
                  Left _e -> do
                    us <- asks usedStorage
                    atomically $ modifyTVar' us $ subtract (fromIntegral size)
                    liftIO $ whenM (doesFileExist fPath) (removeFile fPath) `catch` logFileError
                    pure $ FRErr AUTH
              Left e -> do
                us <- asks usedStorage
                atomically $ modifyTVar' us $ subtract (fromIntegral size)
                liftIO $ whenM (doesFileExist fPath) (removeFile fPath) `catch` logFileError
                pure $ FRErr e
          receiveChunk spec = do
            t <- asks $ fileTimeout . config
            liftIO $ fromMaybe (Left TIMEOUT) <$> timeout t (runExceptT $ receiveFile getBody spec)
    sendServerFile :: FileRec -> RcvPublicDhKey -> M s (FileResponse, Maybe ServerFile)
    sendServerFile FileRec {senderId, filePath, fileInfo = FileInfo {size}} rDhKey = do
      readTVarIO filePath >>= \case
        Just path -> ifM (doesFileExist path) sendFile (pure (FRErr AUTH, Nothing))
          where
            sendFile = do
              g <- asks random
              (sDhKey, spDhKey) <- atomically $ C.generateKeyPair g
              let dhSecret = C.dh' rDhKey spDhKey
              cbNonce <- atomically $ C.randomCbNonce g
              case LC.cbInit dhSecret cbNonce of
                Right sbState -> do
                  stats <- asks serverStats
                  incFileStat fileDownloads
                  liftIO $ updatePeriodStats (filesDownloaded stats) senderId
                  pure (FRFile sDhKey cbNonce, Just ServerFile {filePath = path, fileSize = size, sbState})
                _ -> pure (FRErr INTERNAL, Nothing)
        _ -> pure (FRErr NO_FILE, Nothing)

    deleteServerFile :: FileRec -> M s FileResponse
    deleteServerFile fr = either FRErr (\() -> FROk) <$> deleteServerFile_ fr

    logFileError :: SomeException -> IO ()
    logFileError e = logError $ "Error deleting file: " <> tshow e

    ackFileReception :: RecipientId -> FileRec -> M s FileResponse
    ackFileReception rId fr = do
      withFileLog (`logAckFile` rId)
      st <- asks store
      liftIO $ deleteRecipient st rId fr
      incFileStat fileDownloadAcks
      pure FROk

deleteServerFile_ :: FileStoreClass s => FileRec -> M s (Either XFTPErrorType ())
deleteServerFile_ fr@FileRec {senderId} = do
  withFileLog (`logDeleteFile` senderId)
  deleteOrBlockServerFile_ fr filesDeleted (`deleteFile` senderId)

-- this also deletes the file from storage, but doesn't include it in delete statistics
blockServerFile :: FileStoreClass s => FileRec -> BlockingInfo -> M s (Either XFTPErrorType ())
blockServerFile fr@FileRec {senderId} info = do
  withFileLog $ \sl -> logBlockFile sl senderId info
  deleteOrBlockServerFile_ fr filesBlocked $ \st -> blockFile st senderId info True

deleteOrBlockServerFile_ :: FileStoreClass s => FileRec -> (FileServerStats -> IORef Int) -> (s -> IO (Either XFTPErrorType ())) -> M s (Either XFTPErrorType ())
deleteOrBlockServerFile_ FileRec {filePath, fileInfo} stat storeAction = runExceptT $ do
  path <- readTVarIO filePath
  stats <- asks serverStats
  ExceptT $ first (\(_ :: SomeException) -> FILE_IO) <$> try (forM_ path $ \p -> whenM (doesFileExist p) (removeFile p >> deletedStats stats))
  st <- asks store
  ExceptT $ liftIO $ storeAction st
  forM_ path $ \_ -> do
    us <- asks usedStorage
    atomically $ modifyTVar' us $ subtract (fromIntegral $ size fileInfo)
  lift $ incFileStat stat
  where
    deletedStats stats = do
      liftIO $ atomicModifyIORef'_ (filesCount stats) (subtract 1)
      liftIO $ atomicModifyIORef'_ (filesSize stats) (subtract $ fromIntegral $ size fileInfo)

getFileTime :: IO RoundedFileTime
getFileTime = getRoundedSystemTime

expireServerFiles :: FileStoreClass s => Maybe Int -> ExpirationConfig -> M s ()
expireServerFiles itemDelay expCfg = do
  st <- asks store
  us <- asks usedStorage
  usedStart <- readTVarIO us
  old <- liftIO $ expireBeforeEpoch expCfg
  filesCount <- liftIO $ getFileCount st
  logNote $ "Expiration check: " <> tshow filesCount <> " files"
  expireLoop st us old
  usedEnd <- readTVarIO us
  logNote $ "Used " <> mbs usedStart <> " -> " <> mbs usedEnd <> ", " <> mbs (usedStart - usedEnd) <> " reclaimed."
  where
    mbs bs = tshow (bs `div` 1048576) <> "mb"
    expireLoop st us old = do
      expired <- liftIO $ expiredFiles st old 10000
      forM_ expired $ \(sId, filePath_, fileSize) -> do
        mapM_ threadDelay itemDelay
        forM_ filePath_ $ \fp ->
          whenM (doesFileExist fp) $
            removeFile fp `catch` \(e :: SomeException) -> logError $ "failed to remove expired file " <> tshow fp <> ": " <> tshow e
        withFileLog (`logDeleteFile` sId)
        liftIO (deleteFile st sId) >>= \case
          Right () -> do
            forM_ filePath_ $ \_ ->
              atomically $ modifyTVar' us $ subtract (fromIntegral fileSize)
            incFileStat filesExpired
          Left _ -> pure ()
      unless (null expired) $ expireLoop st us old

randomId :: Int -> M s ByteString
randomId n = atomically . C.randomBytes n =<< asks random

getFileId :: M s XFTPFileId
getFileId = fmap EntityId . randomId =<< asks (fileIdSize . config)

withFileLog :: (StoreLog 'WriteMode -> IO a) -> M s ()
withFileLog action = liftIO . mapM_ action =<< asks storeLog

incFileStat :: (FileServerStats -> IORef Int) -> M s ()
incFileStat statSel = do
  stats <- asks serverStats
  liftIO $ atomicModifyIORef'_ (statSel stats) (+ 1)

saveServerStats :: M s ()
saveServerStats =
  asks (serverStatsBackupFile . config)
    >>= mapM_ (\f -> asks serverStats >>= liftIO . getFileServerStatsData >>= liftIO . saveStats f)
  where
    saveStats f stats = do
      logNote $ "saving server stats to file " <> T.pack f
      B.writeFile f $ strEncode stats
      logNote "server stats saved"

restoreServerStats :: FileStoreClass s => M s ()
restoreServerStats = asks (serverStatsBackupFile . config) >>= mapM_ restoreStats
  where
    restoreStats f = whenM (doesFileExist f) $ do
      logNote $ "restoring server stats from file " <> T.pack f
      liftIO (strDecode <$> B.readFile f) >>= \case
        Right d@FileServerStatsData {_filesCount = statsFilesCount, _filesSize = statsFilesSize} -> do
          s <- asks serverStats
          st <- asks store
          _filesCount <- liftIO $ getFileCount st
          _filesSize <- readTVarIO =<< asks usedStorage
          liftIO $ setFileServerStats s d {_filesCount, _filesSize}
          renameFile f $ f <> ".bak"
          logNote "server stats restored"
          when (statsFilesCount /= _filesCount) $ logWarn $ "Files count differs: stats: " <> tshow statsFilesCount <> ", store: " <> tshow _filesCount
          when (statsFilesSize /= _filesSize) $ logWarn $ "Files size differs: stats: " <> tshow statsFilesSize <> ", store: " <> tshow _filesSize
          logNote $ "Restored " <> tshow (_filesSize `div` 1048576) <> " MBs in " <> tshow _filesCount <> " files"
        Left e -> do
          logNote $ "error restoring server stats: " <> T.pack e
          liftIO exitFailure
