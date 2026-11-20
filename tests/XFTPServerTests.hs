{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module XFTPServerTests (xftpServerTests) where

import AgentTests.FunctionalAPITests (runRight, runRight_)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, bracket, catch)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import qualified Crypto.PubKey.RSA as RSA
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Data.CaseInsensitive as CI
import Data.Either (isLeft)
import Data.List (find, isInfixOf)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime (..), getCurrentTime)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.HPACK.Token (tokenKey)
import qualified Network.HTTP2.Client as H2
import qualified Network.TLS as T
import SMPClient (copyWebCredential, testCredentialCheckInterval, testWebCredentialReload, testWebCredentialReplaced, testWebCredentials, withStallingServerOn')
import ServerTests (logSize)
import Simplex.FileTransfer.Client hiding (createXFTPChunk)
import qualified Simplex.FileTransfer.Client as A
import Simplex.FileTransfer.Description (kb, mb)
import Simplex.FileTransfer.Protocol (FileCmd (..), FileCommand (..), FileInfo (..), FileResponse (..), SFileParty (..), XFTPFileId, xftpBlockSize, xftpDecodeTClient, xftpEncodeAuthTransmission)
import Simplex.FileTransfer.Server.Env (AFStoreType, XFTPServerConfig (..), XFTPStoreConfig (..), defaultInactiveClientExpiration)
import Simplex.FileTransfer.Server.StoreLog (closeStoreLog, logAddFile, logPutFile, serverFileName)
import Simplex.FileTransfer.Transport (XFTPClientHandshake (..), XFTPClientHello (..), XFTPErrorType (..), XFTPRcvChunkSpec (..), XFTPServerHandshake (..), alpnSupportedXFTPhandshakes, receiveEncFile, receiveFile, pattern VersionXFTP)
import Simplex.Messaging.Client (NetworkConfig (..), NetworkTimeout (..), ProtocolClientError (..), defaultNetworkConfig)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Protocol (BasicAuth, EntityId (..), RecipientId, SenderId, pattern NoEntity)
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.Server.StoreLog (openWriteStoreLog)
import Simplex.Messaging.SystemTime (RoundedSystemTime (..), getSystemSeconds)
import Simplex.Messaging.Transport (CertChainPubKey (..), TLS (..), Transport (cGet), TransportPeer (..), defaultSupportedParams, defaultSupportedParamsHTTPS)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost (..), defaultTransportClientConfig, runTLSTransportClient)
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..))
import Simplex.Messaging.Transport.HTTP2.File (fileBlockSize)
import qualified Simplex.Messaging.Transport.HTTP2.Client as HC
import Simplex.Messaging.Transport.Server (TransportServerConfig (..), loadFileFingerprint, loadServerCredential)
import Simplex.Messaging.Transport.Shared (ChainCertificates (..), chainIdCaCerts)
import Simplex.Messaging.Version (mkVersionRange)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getSymbolicLinkTarget, listDirectory, removeFile)
import System.FilePath (takeExtension, (</>))
import Test.Hspec hiding (fit, it)
import UnliftIO.Async (async, cancel, pooledReplicateConcurrentlyN, race_, wait, withAsync)
import UnliftIO.Exception (tryAny)
import UnliftIO.STM
import UnliftIO.Timeout (timeout)
import Util
import XFTPClient

xftpServerTests :: SpecWith AFStoreType
xftpServerTests = do
    describe "XFTP file chunk delivery" $ do
      it "should create, upload and receive file chunk (1 client)" testFileChunkDelivery
      it "should create, upload and receive file chunk (2 clients)" testFileChunkDelivery2
      it "should create, add recipients, upload and receive file chunk" testFileChunkDeliveryAddRecipients
      it "should delete file chunk (1 client)" testFileChunkDelete
      it "should delete file chunk (2 clients)" testFileChunkDelete2
      it "should not allow chunks of wrong size" testWrongChunkSize
      it "should expire chunks after set interval" testFileChunkExpiration
      it "should expire chunks that were never uploaded without delays" testExpireNotUploadedFiles
      it "should disconnect inactive clients" testInactiveClientExpiration
      it "should not disconnect clients during downloads longer than inactivity ttl" testLongDownloadExpiration
      it "should close connection when connecting client is cancelled" $ \_ -> testCancelledClientConnect
      it "should not allow uploading chunks after specified storage quota" testFileStorageQuota
      it "should release storage of interrupted uploads" testInterruptedUploadStorage
      it "should store file records to log and restore them after server restart" testFileLog
      it "should reset daily download stats without stats log" testPeriodStatsReset
      it "should export socket counts in Prometheus metrics" testSocketMetrics
      it "should count stored files after restart without stats backup" $ testFileStatsRestart False
      it "should count stored files after restart with stats backup" $ testFileStatsRestart True
      it "should count stored files after deletion" testFileStatsDelete
      describe "XFTP basic auth" $ do
        --                                               allow FNEW | server auth | clnt auth | success
        it "prohibited without basic auth" $ testFileBasicAuth True (Just "pwd") Nothing False
        it "prohibited when auth is incorrect" $ testFileBasicAuth True (Just "pwd") (Just "wrong") False
        it "prohibited when FNEW disabled" $ testFileBasicAuth False (Just "pwd") (Just "pwd") False
        it "allowed with correct basic auth" $ testFileBasicAuth True (Just "pwd") (Just "pwd") True
        it "allowed with auth on server without auth" $ testFileBasicAuth True Nothing (Just "any") True
      it "should not change content for uploaded and committed files" testFileSkipCommitted
      it "should close connection and file when download stalls" testStalledDownload
      it "should close connection when the end of a download stalls" testStalledDownloadEnd
      it "should close connection when request body stalls" testStalledRequestBody
      it "should time out a stalled upload of a committed chunk" testStalledCommittedUpload
      it "should accept a repeated upload of a chunk while its first upload is stalled" testRepeatedUploadDuringStalledUpload
      it "should return OK to an upload completed after another upload of the chunk" testUploadAfterCommittedUpload
      it "should remove unfinished uploads at start" testRemoveTmpUploads
      it "should close connections without requests" testNoRequestTimeout
      it "should close connection when handshake times out" testHandshakeTimeout
      it "should close connection when cancelled during handshake" testCancelledHandshake
      it "should decode handshake of servers before v6.5.0 and refuse an invalid signature" testOldServerHandshake
    describe "XFTP chunk receiving" $ beforeWith (const (pure ())) $ do
      it "should verify digest of received chunk without reading the file back" testReceiveChunkDigest
      it "should verify digest of received encrypted chunk without reading the file back" testReceiveEncChunkDigest
    describe "XFTP SNI and CORS" $ beforeWith (const (pure ())) $ do
      it "should select web certificate when SNI is used" testSNICertSelection
      it "should select XFTP certificate when SNI is not used" testNoSNICertSelection
      it "should serve the replaced RSA and ECDSA web certificates without restart when SNI is used" testSNICertReload
      it "should add CORS headers when SNI is used" testCORSHeaders
      it "should respond to OPTIONS preflight with CORS headers" testCORSPreflight
      it "should not add CORS headers without SNI" testNoCORSWithoutSNI
      it "should upload and receive file chunk through SNI-enabled server" testFileChunkDeliverySNI
      it "should complete web handshake with challenge-response" testWebHandshake
      it "should re-handshake on same connection with xftp-web-hello header" testWebReHandshake
      it "should return padded SESSION error for stale web session" testStaleWebSession

chSize :: Integral a => a
chSize = kb 128

testChunkPath :: HasTestEnv => FilePath
testChunkPath = testPath "chunk1"

createTestChunk :: FilePath -> IO ByteString
createTestChunk fp = do
  g <- C.newRandom
  bytes <- atomically $ C.randomBytes chSize g
  B.writeFile fp bytes
  pure bytes

createXFTPChunk :: XFTPClient -> C.APrivateAuthKey -> FileInfo -> NonEmpty C.APublicAuthKey -> Maybe BasicAuth -> ExceptT XFTPClientError IO (SenderId, NonEmpty RecipientId)
createXFTPChunk c spKey file rcps auth = (\(sId, rIds, _) -> (sId, rIds)) <$> A.createXFTPChunk c spKey file rcps auth Nothing

readChunk :: HasTestEnv => XFTPFileId -> IO ByteString
readChunk sId = B.readFile (xftpServerFiles </> B.unpack (B64.encode $ unEntityId sId))

testFileChunkDelivery :: HasTestEnv => AFStoreType -> Expectation
testFileChunkDelivery = xftpTest $ \c -> runRight_ $ runTestFileChunkDelivery c c

testFileChunkDelivery2 :: HasTestEnv => AFStoreType -> Expectation
testFileChunkDelivery2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelivery s r

runTestFileChunkDelivery :: HasTestEnv => XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkDelivery s r = do
  g <- liftIO C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey] Nothing
  uploadXFTPChunk s spKey sId chunkSpec
  (sId', _) <- createXFTPChunk s spKey file {digest = digest <> "_wrong"} [rcvKey] Nothing
  uploadXFTPChunk s spKey sId' chunkSpec
    `catchError` (liftIO . (`shouldBe` PCEProtocolError DIGEST))
  liftIO $ readChunk sId `shouldReturn` bytes
  downloadXFTPChunk g r rpKey rId (XFTPRcvChunkSpec (testPath "received_chunk1") chSize (digest <> "_wrong"))
    `catchError` (liftIO . (`shouldBe` PCEResponseError DIGEST))
  downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest
  liftIO $ B.readFile (testPath "received_chunk1") `shouldReturn` bytes

testFileChunkDeliveryAddRecipients :: HasTestEnv => AFStoreType -> Expectation
testFileChunkDeliveryAddRecipients = xftpTest4 $ \s r1 r2 r3 -> runRight_ $ do
  g <- liftIO C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey1, rpKey1) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey2, rpKey2) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey3, rpKey3) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId1]) <- createXFTPChunk s spKey file [rcvKey1] Nothing
  [rId2, rId3] <- addXFTPRecipients s spKey sId [rcvKey2, rcvKey3]
  uploadXFTPChunk s spKey sId chunkSpec
  let testReceiveChunk r rpKey rId fPath = do
        downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec fPath chSize digest
        liftIO $ B.readFile fPath `shouldReturn` bytes
  testReceiveChunk r1 rpKey1 rId1 (testPath "received_chunk1")
  testReceiveChunk r2 rpKey2 rId2 (testPath "received_chunk2")
  testReceiveChunk r3 rpKey3 rId3 (testPath "received_chunk3")

testFileChunkDelete :: HasTestEnv => AFStoreType -> Expectation
testFileChunkDelete = xftpTest $ \c -> runRight_ $ runTestFileChunkDelete c c

testFileChunkDelete2 :: HasTestEnv => AFStoreType -> Expectation
testFileChunkDelete2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelete s r

runTestFileChunkDelete :: HasTestEnv => XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkDelete s r = do
  g <- liftIO C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey] Nothing
  uploadXFTPChunk s spKey sId chunkSpec

  downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest
  liftIO $ B.readFile (testPath "received_chunk1") `shouldReturn` bytes
  deleteXFTPChunk s spKey sId
  liftIO $
    readChunk sId
      `shouldThrow` \(e :: SomeException) -> "does not exist" `isInfixOf` show e
  downloadXFTPChunk g r rpKey rId (XFTPRcvChunkSpec (testPath "received_chunk2") chSize digest)
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  deleteXFTPChunk s spKey sId
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testWrongChunkSize :: HasTestEnv => AFStoreType -> Expectation
testWrongChunkSize = xftpTest $ \c -> do
  g <- C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, _rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  B.writeFile testChunkPath =<< atomically (C.randomBytes (kb 96) g)
  digest <- LC.sha256Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = kb 96, digest}
  runRight_ $
    void (createXFTPChunk c spKey file [rcvKey] Nothing)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError SIZE))

testFileChunkExpiration :: HasTestEnv => AFStoreType -> Expectation
testFileChunkExpiration fsType = withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileExpiration}) $
  \_ -> testXFTPClient $ \c -> runRight_ $ do
    g <- liftIO C.newRandom
    (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    bytes <- liftIO $ createTestChunk testChunkPath
    digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
    (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey] Nothing
    uploadXFTPChunk c spKey sId chunkSpec

    downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest
    liftIO $ B.readFile (testPath "received_chunk1") `shouldReturn` bytes

    liftIO $ threadDelay 1000000
    downloadXFTPChunk g c rpKey rId (XFTPRcvChunkSpec (testPath "received_chunk2") chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  where
    fileExpiration = ExpirationConfig {ttl = 1, checkInterval = 1}

testExpireNotUploadedFiles :: HasTestEnv => AFStoreType -> Expectation
testExpireNotUploadedFiles _ = do
  g <- C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  now <- getSystemSeconds
  let sIds = map (\i -> EntityId $ "never_uploaded" <> B.pack (show i)) [10 .. 59 :: Int]
      fileInfo = FileInfo {sndKey, size = chSize, digest = "digest"}
      createdAt = RoundedSystemTime $ roundedSeconds now
      expiresAt = RoundedSystemTime $ roundedSeconds now + 2
  sl <- openWriteStoreLog False testXFTPLogFile
  forM_ sIds $ \sId -> logAddFile sl sId fileInfo createdAt (Just expiresAt) EntityActive
  closeStoreLog sl
  withXFTPServerCfg testXFTPServerConfig {serverStoreCfg = XSCMemory (Just testXFTPLogFile), storeLogFile = Just testXFTPLogFile, fileExpiration} $ \_ -> do
    threadDelay 6000000
    testXFTPClient $ \c -> forM_ sIds $ \sId ->
      runExceptT (addXFTPRecipients c spKey sId [rcvKey]) `shouldReturn` Left (PCEProtocolError AUTH)
  where
    fileExpiration = ExpirationConfig {ttl = 86400, checkInterval = 1}

testInactiveClientExpiration :: HasTestEnv => AFStoreType -> Expectation
testInactiveClientExpiration fsType = withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {inactiveClientExpiration}) $ \_ -> runRight_ $ do
  (c, disconnected) <- liftIO connectXFTPClient
  pingXFTP c
  liftIO $ do
    threadDelay 100000
    atomically (tryReadTMVar disconnected) `shouldReturn` Nothing
  pingXFTP c
  liftIO $ do
    threadDelay 3000000
    atomically (tryTakeTMVar disconnected) `shouldReturn` Just ()
  where
    inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}

testLongDownloadExpiration :: HasTestEnv => AFStoreType -> Expectation
testLongDownloadExpiration fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {inactiveClientExpiration}) $ \_ -> do
    (c, disconnected, rId, rpKey) <- uploadLargeChunk
    HC.HTTP2Response {HC.respBody = HTTP2Body {bodyPart}} <- sendFGET c rpKey rId
    getPart <- maybe (error "no response body") pure bodyPart
    slowBytes <- readBody getPart (mb 2) 25000
    restBytes <- timeout 15000000 (readBody getPart maxBound 0) >>= maybe (error "body not read within 15 seconds") pure
    slowBytes + restBytes `shouldBe` mb 4 + C.authTagSize
    runRight_ $ pingXFTP c
    expectDisconnected disconnected
  where
    inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}

readBody :: (Int -> IO ByteString) -> Int -> Int -> IO Int
readBody getPart limit delay = go 0
  where
    go n
      | n >= limit = pure n
      | otherwise = do
          threadDelay delay
          len <- B.length <$> getPart fileBlockSize
          if len == 0 then pure n else go (n + len)

testCancelledClientConnect :: HasTestEnv => Expectation
testCancelledClientConnect =
  withStallingServerOn' xftpTestPort $ \accepted closed -> do
    ts <- getCurrentTime
    a <- async $ getXFTPClient (1, testXFTPServer, Nothing) testXFTPClientConfig [] ts (\_ -> pure Nothing) (\_ -> pure ())
    timeout 5000000 (atomically $ takeTMVar accepted) `shouldReturn` Just ()
    cancel a
    timeout 1000000 (atomically $ takeTMVar closed) `shouldReturn` Just ()

testFileStorageQuota :: HasTestEnv => AFStoreType -> Expectation
testFileStorageQuota fsType = withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileSizeQuota = Just $ chSize * 2}) $
  \_ -> testXFTPClient $ \c -> runRight_ $ do
    g <- liftIO C.newRandom
    (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    bytes <- liftIO $ createTestChunk testChunkPath
    digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
        download rId = do
          downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest
          liftIO $ B.readFile (testPath "received_chunk1") `shouldReturn` bytes
    (sId1, [rId1]) <- createXFTPChunk c spKey file [rcvKey] Nothing
    uploadXFTPChunk c spKey sId1 chunkSpec
    download rId1
    (sId2, [rId2]) <- createXFTPChunk c spKey file [rcvKey] Nothing
    uploadXFTPChunk c spKey sId2 chunkSpec
    download rId2

    (sId3, [rId3]) <- createXFTPChunk c spKey file [rcvKey] Nothing
    uploadXFTPChunk c spKey sId3 chunkSpec
      `catchError` (liftIO . (`shouldBe` PCEProtocolError QUOTA))

    deleteXFTPChunk c spKey sId1
    uploadXFTPChunk c spKey sId3 chunkSpec
    download rId3

testInterruptedUploadStorage :: HasTestEnv => AFStoreType -> Expectation
testInterruptedUploadStorage fsType = withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileSizeQuota = Just $ chSize * 10}) $
  \_ -> do
    g <- C.newRandom
    (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (rcvKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    void $ createTestChunk testChunkPath
    digest <- LC.sha256Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
        interruptUpload = testXFTPClient $ \c@XFTPClient {http2Client, thParams} -> do
          (sId, _) <- runRight $ createXFTPChunk c spKey file [rcvKey] Nothing
          t <- either (error . show) pure $ xftpEncodeAuthTransmission thParams spKey ("", sId, FileCmd SFSender FPUT)
          let req = H2.requestStreaming "POST" "/" [] $ \send flush -> do
                send $ byteString t
                send $ byteString $ B.replicate 1024 'x'
                flush
                threadDelay maxBound
          race_ (HC.sendRequest http2Client req Nothing) (threadDelay 20000)
          sId <$ closeXFTPClient c
    sIds <- pooledReplicateConcurrentlyN 10 300 interruptUpload
    threadDelay 1000000
    listDirectory xftpServerFiles `shouldReturn` []
    testXFTPClient $ \c -> runRight_ $ forM_ (take 10 sIds) $ \sId -> uploadXFTPChunk c spKey sId chunkSpec

testFileLog :: HasTestEnv => AFStoreType -> Expectation
testFileLog _ = do
  g <- C.newRandom
  bytes <- liftIO $ createTestChunk testChunkPath
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey1, rpKey1) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey2, rpKey2) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
  sIdVar <- newTVarIO NoEntity
  rIdVar1 <- newTVarIO NoEntity
  rIdVar2 <- newTVarIO NoEntity

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
    (sId, [rId1, rId2]) <- createXFTPChunk c spKey file [rcvKey1, rcvKey2] Nothing
    liftIO $
      atomically $ do
        writeTVar sIdVar sId
        writeTVar rIdVar1 rId1
        writeTVar rIdVar2 rId2
    uploadXFTPChunk c spKey sId chunkSpec
    download g c rpKey1 rId1 digest bytes
    download g c rpKey2 rId2 digest bytes
  logSize testXFTPLogFile `shouldReturn` 3
  logSize testXFTPStatsBackupFile `shouldReturn` 15

  threadDelay 100000

  withXFTPServerThreadOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    sId <- liftIO $ readTVarIO sIdVar
    rId1 <- liftIO $ readTVarIO rIdVar1
    rId2 <- liftIO $ readTVarIO rIdVar2
    -- recipients and sender get AUTH error because server restarted without log
    downloadXFTPChunk g c rpKey1 rId1 (XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    downloadXFTPChunk g c rpKey2 rId2 (XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    sId <- liftIO $ readTVarIO sIdVar
    rId1 <- liftIO $ readTVarIO rIdVar1
    rId2 <- liftIO $ readTVarIO rIdVar2
    -- recipients can download
    download g c rpKey1 rId1 digest bytes
    download g c rpKey2 rId2 digest bytes
    -- sender can delete - +1 to log
    deleteXFTPChunk c spKey sId
  logSize testXFTPLogFile `shouldReturn` 4
  logSize testXFTPStatsBackupFile `shouldReturn` 15

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> pure () -- compacts on start
  logSize testXFTPLogFile `shouldReturn` 0
  logSize testXFTPStatsBackupFile `shouldReturn` 15

  threadDelay 100000

  removeFile testXFTPLogFile
  removeFile testXFTPStatsBackupFile
  where
    download g c rpKey rId digest bytes = do
      downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk1") chSize digest
      liftIO $ B.readFile (testPath "received_chunk1") `shouldReturn` bytes

testPeriodStatsReset :: HasTestEnv => AFStoreType -> Expectation
testPeriodStatsReset fsType = do
  ts <- getCurrentTime
  let resetTime = floor (utctDayTime ts) + 10
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {logStatsInterval = Nothing, logStatsStartTime = resetTime, prometheusInterval = Just 1}) $ \_ -> do
    testXFTPClient $ \c -> runRight_ $ runTestFileChunkDelivery c c
    threadDelay 1500000
    dailyDownloads `shouldReturn` Just "1"
    threadDelay 10000000
    dailyDownloads `shouldReturn` Just "0"
  where
    dailyDownloads = do
      metrics <- T.lines <$> T.readFile xftpTestPrometheusMetricsFile
      pure $ listToMaybe [n | l <- metrics, ["simplex_xftp_files_count_daily", n, _] <- [T.words l]]

testSocketMetrics :: HasTestEnv => AFStoreType -> Expectation
testSocketMetrics fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {prometheusInterval = Just 1}) $ \_ -> do
    testXFTPClient $ \c -> do
      runRight_ $ pingXFTP c
      threadDelay 1500000
      socketMetrics `shouldReturn` [("accepted", "1"), ("closed", "0"), ("active", "1"), ("leaked", "0")]
      closeXFTPClient c
    threadDelay 2500000
    socketMetrics `shouldReturn` [("accepted", "1"), ("closed", "1"), ("active", "0"), ("leaked", "0")]
  where
    socketMetrics = do
      metrics <- T.lines <$> T.readFile xftpTestPrometheusMetricsFile
      pure
        [ (name, n)
          | l <- metrics,
            [metric, n, _] <- [T.words l],
            Just name <- [T.stripPrefix "simplex_xftp_sockets_" =<< T.stripSuffix portLabel metric]
        ]
    portLabel = "{port=\"" <> T.pack xftpTestPort <> "\"}"

testFileStatsRestart :: HasTestEnv => Bool -> AFStoreType -> Expectation
testFileStatsRestart statsBackup _ = do
  when statsBackup $ do
    withXFTPServerCfg cfg $ \_ -> pure ()
    doesFileExist testXFTPStatsBackupFile `shouldReturn` True
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  createDirectoryIfMissing True xftpServerFiles
  sl <- openWriteStoreLog False testXFTPLogFile
  let fileInfo = FileInfo {sndKey, size = chSize, digest = "digest"}
      addTestFile sId expiresAt = logAddFile sl sId fileInfo (RoundedSystemTime 0) (Just $ RoundedSystemTime expiresAt) EntityActive
      putTestFile sId = do
        let path = xftpServerFiles </> serverFileName sId
        void $ createTestChunk path
        logPutFile sl sId path
      expiredId = EntityId "expired_file____"
      storedId = EntityId "stored_file_____"
  addTestFile expiredId 3600
  putTestFile expiredId
  addTestFile storedId 4102444800
  putTestFile storedId
  addTestFile (EntityId "new_file________") 4102444800
  closeStoreLog sl
  withXFTPServerCfg cfg $ \_ -> threadDelay 2500000
  fileMetrics `shouldReturn` [("expired", "1"), ("deleted", "0"), ("count_total", "1"), ("size", "131072")]
  where
    cfg =
      testXFTPServerConfig
        { serverStoreCfg = XSCMemory (Just testXFTPLogFile),
          storeLogFile = Just testXFTPLogFile,
          serverStatsBackupFile = if statsBackup then Just testXFTPStatsBackupFile else Nothing,
          prometheusInterval = Just 1
        }

testFileStatsDelete :: HasTestEnv => AFStoreType -> Expectation
testFileStatsDelete fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {prometheusInterval = Just 1}) $ \_ ->
    testXFTPClient $ \c -> runRight_ $ do
      g <- liftIO C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      void $ liftIO $ createTestChunk testChunkPath
      digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
      let file = FileInfo {sndKey, size = chSize, digest}
          chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      (sId1, _) <- createXFTPChunk c spKey file [rcvKey] Nothing
      uploadXFTPChunk c spKey sId1 chunkSpec
      (sId2, _) <- createXFTPChunk c spKey file [rcvKey] Nothing
      uploadXFTPChunk c spKey sId2 chunkSpec
      liftIO $ do
        threadDelay 1500000
        fileMetrics `shouldReturn` [("expired", "0"), ("deleted", "0"), ("count_total", "2"), ("size", "262144")]
        removeFile $ xftpServerFiles </> serverFileName sId2
      deleteXFTPChunk c spKey sId1
      deleteXFTPChunk c spKey sId2
      liftIO $ do
        threadDelay 1500000
        fileMetrics `shouldReturn` [("expired", "0"), ("deleted", "2"), ("count_total", "0"), ("size", "0")]

fileMetrics :: HasTestEnv => IO [(T.Text, T.Text)]
fileMetrics = do
  metrics <- T.lines <$> T.readFile xftpTestPrometheusMetricsFile
  pure
    [ (name, n)
      | l <- metrics,
        [metric, n, _] <- [T.words l],
        Just name <- [T.stripPrefix "simplex_xftp_files_" metric],
        name `elem` (["expired", "deleted", "count_total", "size"] :: [T.Text])
    ]

testFileBasicAuth :: HasTestEnv => Bool -> Maybe BasicAuth -> Maybe BasicAuth -> Bool -> AFStoreType -> IO ()
testFileBasicAuth allowNewFiles newFileBasicAuth clntAuth success fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {allowNewFiles, newFileBasicAuth}) $
    \_ -> testXFTPClient $ \c -> do
      g <- C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      bytes <- createTestChunk testChunkPath
      digest <- LC.sha256Hash <$> LB.readFile testChunkPath
      let file = FileInfo {sndKey, size = chSize, digest}
          chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      runRight_ $
        if success
          then do
            (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey] clntAuth
            uploadXFTPChunk c spKey sId chunkSpec
            downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk") chSize digest
            liftIO $ B.readFile (testPath "received_chunk") `shouldReturn` bytes
          else do
            void (createXFTPChunk c spKey file [rcvKey] clntAuth)
              `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testFileSkipCommitted :: HasTestEnv => AFStoreType -> IO ()
testFileSkipCommitted fsType =
  withXFTPServerConfigOn (cfgFS fsType) $
    \_ -> testXFTPClient $ \c -> do
      g <- C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      bytes <- createTestChunk testChunkPath
      digest <- LC.sha256Hash <$> LB.readFile testChunkPath
      let file = FileInfo {sndKey, size = chSize, digest}
          chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      runRight_ $ do
        (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey] Nothing
        uploadXFTPChunk c spKey sId chunkSpec
        void . liftIO $ createTestChunk testChunkPath -- trash chunk contents
        uploadXFTPChunk c spKey sId chunkSpec -- upload again to get FROk without getting stuck
        downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk") chSize digest
        liftIO $ B.readFile (testPath "received_chunk") `shouldReturn` bytes -- new chunk content got ignored

testStalledDownload :: HasTestEnv => AFStoreType -> Expectation
testStalledDownload fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileTimeout = 2000000, inactiveClientExpiration = Nothing}) $ \_ -> do
    (c, disconnected, rId, rpKey) <- uploadLargeChunk
    void $ sendFGET c rpKey rId
    expectDisconnected disconnected
    filesClosed (20 :: Int) `shouldReturn` True
  where
    filesClosed n = do
      closed <- all (maybe True (== 0)) <$> (mapM (openDescriptors . (xftpServerFiles </>)) =<< listDirectory xftpServerFiles)
      if closed || n <= 0 then pure closed else threadDelay 100000 >> filesClosed (n - 1)

testStalledDownloadEnd :: HasTestEnv => AFStoreType -> Expectation
testStalledDownloadEnd fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileTimeout = 2000000, inactiveClientExpiration}) $ \_ ->
    forM_ [mb 1 + kb k | k <- [0, 64 .. 320]] $ \unread -> do
      (c, disconnected, rId, rpKey) <- uploadLargeChunk
      HC.HTTP2Response {HC.respBody = HTTP2Body {bodyPart}} <- sendFGET c rpKey rId
      getPart <- maybe (error "no response body") pure bodyPart
      void $ readBody getPart (mb 4 + C.authTagSize - unread) 0
      expectDisconnected disconnected
  where
    inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}

testStalledRequestBody :: HasTestEnv => AFStoreType -> Expectation
testStalledRequestBody fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileTimeout = 2000000, inactiveClientExpiration = Nothing}) $ \_ -> do
    (XFTPClient {http2Client}, disconnected) <- connectXFTPClient
    let req = H2.requestStreaming "POST" "/" [] $ \send flush -> send "x" >> flush >> threadDelay maxBound
    withAsync (HC.sendRequest http2Client req Nothing) $ \_ -> expectDisconnected disconnected

testStalledCommittedUpload :: HasTestEnv => AFStoreType -> Expectation
testStalledCommittedUpload fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileTimeout = 2000000}) $ \_ ->
    testXFTPClient $ \c@XFTPClient {http2Client, thParams} -> do
      g <- C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      void $ createTestChunk testChunkPath
      digest <- LC.sha256Hash <$> LB.readFile testChunkPath
      let chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      sId <- runRight $ do
        (sId, _) <- createXFTPChunk c spKey FileInfo {sndKey, size = chSize, digest} [rcvKey] Nothing
        sId <$ uploadXFTPChunk c spKey sId chunkSpec
      t <- either (error . show) pure $ xftpEncodeAuthTransmission thParams spKey ("", sId, FileCmd SFSender FPUT)
      let req = H2.requestStreaming "POST" "/" [] $ \send flush -> send (byteString t) >> flush >> threadDelay maxBound
      timeout 5000000 (HC.sendRequest http2Client req Nothing) >>= \case
        Just (Right HC.HTTP2Response {HC.respBody = HTTP2Body {bodyHead}}) -> case xftpDecodeTClient thParams bodyHead of
          Right (_, _, Right (FRErr e)) -> e `shouldBe` TIMEOUT
          r -> expectationFailure $ "unexpected response: " <> show r
        Just (Left e) -> expectationFailure $ "request error: " <> show e
        Nothing -> expectationFailure "no response within 5 seconds"

testRepeatedUploadDuringStalledUpload :: HasTestEnv => AFStoreType -> Expectation
testRepeatedUploadDuringStalledUpload fsType =
  withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c -> c {fileTimeout = 2000000}) $ \_ ->
    testXFTPClient $ \c@XFTPClient {http2Client, thParams} -> do
      g <- C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      bytes <- createTestChunk testChunkPath
      digest <- LC.sha256Hash <$> LB.readFile testChunkPath
      let chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      (sId, [rId]) <- runRight $ createXFTPChunk c spKey FileInfo {sndKey, size = chSize, digest} [rcvKey] Nothing
      t <- either (error . show) pure $ xftpEncodeAuthTransmission thParams spKey ("", sId, FileCmd SFSender FPUT)
      let req = H2.requestStreaming "POST" "/" [] $ \send flush -> send (byteString t) >> flush >> threadDelay maxBound
          download c' = do
            runRight_ $ downloadXFTPChunk g c' rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk") chSize digest
            B.readFile (testPath "received_chunk") `shouldReturn` bytes
      withAsync (HC.sendRequest http2Client req Nothing) $ \_ -> do
        threadDelay 500000
        testXFTPClient $ \c' -> do
          runRight_ $ uploadXFTPChunk c' spKey sId chunkSpec
          download c'
          threadDelay 2500000
          download c'
        filter ((".tmp" ==) . takeExtension) <$> listDirectory xftpServerFiles `shouldReturn` []

testUploadAfterCommittedUpload :: HasTestEnv => AFStoreType -> Expectation
testUploadAfterCommittedUpload fsType =
  withXFTPServerConfigOn (cfgFS fsType) $ \_ ->
    testXFTPClient $ \c@XFTPClient {http2Client, thParams} -> do
      g <- C.newRandom
      (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
      bytes <- createTestChunk testChunkPath
      digest <- LC.sha256Hash <$> LB.readFile testChunkPath
      let chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      (sId, [rId]) <- runRight $ createXFTPChunk c spKey FileInfo {sndKey, size = chSize, digest} [rcvKey] Nothing
      t <- either (error . show) pure $ xftpEncodeAuthTransmission thParams spKey ("", sId, FileCmd SFSender FPUT)
      bodyAllowed <- newEmptyTMVarIO
      let req = H2.requestStreaming "POST" "/" [] $ \send flush -> do
            send (byteString t) >> flush
            atomically $ takeTMVar bodyAllowed
            send (byteString bytes) >> flush
      withAsync (HC.sendRequest http2Client req Nothing) $ \firstUpload -> do
        threadDelay 500000
        testXFTPClient $ \c' -> runRight_ $ uploadXFTPChunk c' spKey sId chunkSpec
        atomically $ putTMVar bodyAllowed ()
        wait firstUpload >>= \case
          Right HC.HTTP2Response {HC.respBody = HTTP2Body {bodyHead}} -> case xftpDecodeTClient thParams bodyHead of
            Right (_, _, Right FROk) -> pure ()
            r -> expectationFailure $ "unexpected response: " <> show r
          Left e -> expectationFailure $ "request error: " <> show e
      runRight_ $ downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec (testPath "received_chunk") chSize digest
      B.readFile (testPath "received_chunk") `shouldReturn` bytes

testRemoveTmpUploads :: HasTestEnv => AFStoreType -> Expectation
testRemoveTmpUploads _ = do
  createDirectoryIfMissing True xftpServerFiles
  writeFile (xftpServerFiles </> "chunk") "chunk"
  writeFile (xftpServerFiles </> "chunk.upload.tmp") "partial upload"
  withXFTPServerThreadOn $ \_ -> listDirectory xftpServerFiles `shouldReturn` ["chunk"]

testNoRequestTimeout :: HasTestEnv => AFStoreType -> Expectation
testNoRequestTimeout fsType =
  forM_ ([Nothing, Just defaultInactiveClientExpiration] :: [Maybe ExpirationConfig]) $ \inactiveClientExpiration ->
    withXFTPServerConfigOn (updateXFTPCfg (cfgFS fsType) $ \c@XFTPServerConfig {transportConfig = tc} -> c {inactiveClientExpiration, transportConfig = tc {firstRequestTimeout = 1000000}}) $ \_ -> do
      Fingerprint fp <- loadFileFingerprint "tests/fixtures/ca.crt"
      let cfg = defaultTransportClientConfig {clientALPN = Just alpnSupportedXFTPhandshakes} :: TransportClientConfig
      runTLSTransportClient defaultSupportedParams Nothing cfg Nothing "localhost" xftpTestPort (Just $ C.KeyHash fp) $ \(tls :: TLS 'TClient) ->
        timeout 5000000 (tryAny $ cGet tls 1) >>= (`shouldSatisfy` maybe False (either (const True) B.null))
      (c, disconnected) <- connectXFTPClient
      threadDelay 2000000
      atomically (tryReadTMVar disconnected) `shouldReturn` Nothing
      runRight_ $ pingXFTP c

connectXFTPClient :: HasTestEnv => IO (XFTPClient, TMVar ())
connectXFTPClient = do
  disconnected <- newEmptyTMVarIO
  ts <- getCurrentTime
  c <- either (error . show) pure =<< getXFTPClient (1, testXFTPServer, Nothing) testXFTPClientConfig [] ts (\_ -> pure Nothing) (\_ -> atomically $ putTMVar disconnected ())
  pure (c, disconnected)

uploadLargeChunk :: HasTestEnv => IO (XFTPClient, TMVar (), RecipientId, C.APrivateAuthKey)
uploadLargeChunk = do
  g <- C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let size = mb 4
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = size}
  B.writeFile testChunkPath =<< atomically (C.randomBytes (fromIntegral size) g)
  digest <- LC.sha256Hash <$> LB.readFile testChunkPath
  (c, disconnected) <- connectXFTPClient
  rId <- runRight $ do
    (sId, [rId]) <- createXFTPChunk c spKey FileInfo {sndKey, size, digest} [rcvKey] Nothing
    uploadXFTPChunk c spKey sId chunkSpec
    pure rId
  pure (c, disconnected, rId, rpKey)

expectDisconnected :: TMVar () -> Expectation
expectDisconnected disconnected = timeout 5000000 (atomically $ takeTMVar disconnected) `shouldReturn` Just ()

sendFGET :: XFTPClient -> C.APrivateAuthKey -> RecipientId -> IO HC.HTTP2Response
sendFGET XFTPClient {http2Client, thParams} rpKey rId = do
  (rDhKey, _) <- atomically . C.generateKeyPair =<< C.newRandom
  t <- either (error . show) pure $ xftpEncodeAuthTransmission thParams rpKey ("", rId, FileCmd SFRecipient $ FGET rDhKey)
  either (error . show) pure =<< HC.sendRequest http2Client (H2.requestBuilder "POST" "/" [] $ byteString t) Nothing

openDescriptors :: FilePath -> IO (Maybe Int)
openDescriptors path =
  doesDirectoryExist fdDir >>= \case
    False -> pure Nothing
    True -> do
      target <- canonicalizePath path
      fds <- listDirectory fdDir
      Just . length . filter (== target) <$> mapM linkTarget fds
  where
    fdDir = "/proc/self/fd"
    linkTarget fd = getSymbolicLinkTarget (fdDir </> fd) `catch` \(_ :: IOException) -> pure ""

testHandshakeTimeout :: HasTestEnv => AFStoreType -> Expectation
testHandshakeTimeout _ =
  withStallingXFTPServer $ \_ closed -> do
    ts <- getCurrentTime
    (void <$> getXFTPClient (1, testXFTPServer, Nothing) cfg [] ts (\_ -> pure Nothing) (\_ -> pure ())) `shouldReturn` Left PCEResponseTimeout
    timeout 1000000 (atomically $ takeTMVar closed) `shouldReturn` Just ()
  where
    cfg = testXFTPClientConfig {xftpNetworkConfig = defaultNetworkConfig {tcpConnectTimeout = NetworkTimeout 2000000 2000000}}

testCancelledHandshake :: HasTestEnv => AFStoreType -> Expectation
testCancelledHandshake _ =
  withStallingXFTPServer $ \requested closed -> do
    ts <- getCurrentTime
    a <- async $ getXFTPClient (1, testXFTPServer, Nothing) testXFTPClientConfig [] ts (\_ -> pure Nothing) (\_ -> pure ())
    timeout 5000000 (atomically $ takeTMVar requested) `shouldReturn` Just ()
    cancel a
    timeout 1000000 (atomically $ takeTMVar closed) `shouldReturn` Just ()

testOldServerHandshake :: HasTestEnv => AFStoreType -> Expectation
testOldServerHandshake _ = do
  (chain, pk) <- loadServerCredential xftpCredentials
  signKey <- either error pure $ C.x509ToPrivate' pk
  (k, _) :: C.KeyPairX25519 <- atomically . C.generateKeyPair =<< C.newRandom
  let vr = mkVersionRange (VersionXFTP 1) (VersionXFTP 3)
      key = CertChainPubKey chain (C.signX509 signKey $ C.publicToX509 k)
      decode :: ByteString -> Either String XFTPServerHandshake
      decode sig = smpDecode =<< first show (C.unPad =<< C.pad (smpEncode (vr, "session" :: ByteString, key) <> sig) xftpBlockSize)
  XFTPServerHandshake {xftpVersionRange, sessionId, authPubKey, serverInfoBytes} <- either error pure $ decode ""
  (xftpVersionRange, sessionId, authPubKey, serverInfoBytes) `shouldBe` (vr, "session", key, Nothing)
  isLeft (decode $ smpEncode ("invalid" :: ByteString)) `shouldBe` True
  where
    XFTPServerConfig {xftpCredentials} = testXFTPServerConfig

testReceiveChunkDigest :: Expectation
testReceiveChunkDigest = do
  bytes <- atomically . C.randomBytes chSize =<< C.newRandom
  let digest = LC.sha256Hash $ LB.fromStrict bytes
      receive d = bodyReader bytes >>= \getBody -> runExceptT $ receiveFile getBody $ XFTPRcvChunkSpec "/dev/null" chSize d
  receive digest `shouldReturn` Right ()
  receive (digest <> "_wrong") `shouldReturn` Left DIGEST

testReceiveEncChunkDigest :: Expectation
testReceiveEncChunkDigest = do
  g <- C.newRandom
  bytes <- atomically $ C.randomBytes chSize g
  key <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
  sbState <- either (error . show) pure $ LC.sbInit key nonce
  let (encrypted, sbState') = LC.sbEncryptChunk sbState bytes
      body = encrypted <> BA.convert (LC.sbAuth sbState')
      digest = LC.sha256Hash $ LB.fromStrict bytes
      receive d = bodyReader body >>= \getBody -> runExceptT $ receiveEncFile getBody sbState $ XFTPRcvChunkSpec "/dev/null" chSize d
  receive digest `shouldReturn` Right ()
  receive (digest <> "_wrong") `shouldReturn` Left DIGEST

bodyReader :: ByteString -> IO (Int -> IO ByteString)
bodyReader bytes = do
  rest <- newTVarIO bytes
  pure $ \n -> atomically $ stateTVar rest $ B.splitAt n

-- SNI and CORS tests

lookupResponseHeader :: B.ByteString -> H2.Response -> Maybe B.ByteString
lookupResponseHeader name resp =
  snd <$> find (\(t, _) -> tokenKey t == CI.mk name) (fst $ H2.responseHeaders resp)

getCerts :: TLS 'TClient -> [X.Certificate]
getCerts tls =
  let X.CertificateChain cc = tlsPeerCert tls
   in map (X.signedObject . X.getSigned) cc

withH2Client :: HasTestEnv => T.Supported -> TransportClientConfig -> C.KeyHash -> (HC.HTTP2Client -> IO a) -> IO a
withH2Client tlsParams cfg caHash action =
  runTLSTransportClient tlsParams Nothing cfg Nothing "localhost" xftpTestPort (Just caHash) $ \(tls :: TLS 'TClient) ->
    bracket (either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls) HC.closeHTTP2Client action
  where
    h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}

testSNICertSelection :: HasTestEnv => Expectation
testSNICertSelection =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just caHTTP) $ \(tls :: TLS 'TClient) -> do
      tlsALPN tls `shouldBe` Just "h2"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyRSA rsa} : _ -> RSA.public_size rsa `shouldSatisfy` (> 0)
        leaf : _ -> expectationFailure $ "Expected RSA cert, got: " <> show (X.certPubKey leaf)
        [] -> expectationFailure "Empty certificate chain"

testNoSNICertSelection :: HasTestEnv => Expectation
testNoSNICertSelection =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpXFTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caXFTP = C.KeyHash fpXFTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["xftp/1"], useSNI = False}
    runTLSTransportClient defaultSupportedParams Nothing cfg Nothing "localhost" xftpTestPort (Just caXFTP) $ \(tls :: TLS 'TClient) -> do
      tlsALPN tls `shouldBe` Just "xftp/1"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyEd448 _} : _ -> pure ()
        leaf : _ -> expectationFailure $ "Expected Ed448 cert, got: " <> show (X.certPubKey leaf)
        [] -> expectationFailure "Empty certificate chain"

testSNICertReload :: HasTestEnv => Expectation
testSNICertReload = do
  copyWebCredential "web"
  withXFTPServerCfg cfg $ \_ -> do
    testWebCredentialReload xftpTestPort
    testWebCredentialReplaced xftpTestPort "web_ecdsa" "web_ecdsa"
    testWebCredentialReplaced xftpTestPort "web_ecdsa384" "web_ecdsa"
  where
    XFTPServerConfig {transportConfig} = testXFTPServerConfigSNI
    cfg =
      testXFTPServerConfigSNI
        { httpCredentials = Just testWebCredentials,
          transportConfig = transportConfig {credentialCheckInterval = testCredentialCheckInterval}
        }

testCORSHeaders :: HasTestEnv => Expectation
testCORSHeaders =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    withH2Client defaultSupportedParamsHTTPS cfg caHTTP $ \h2 -> do
      let req = H2.requestNoBody "POST" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-expose-headers" response `shouldBe` Just "*"

testCORSPreflight :: HasTestEnv => Expectation
testCORSPreflight =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    withH2Client defaultSupportedParamsHTTPS cfg caHTTP $ \h2 -> do
      let req = H2.requestNoBody "OPTIONS" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-allow-methods" response `shouldBe` Just "POST, OPTIONS"
      lookupResponseHeader "access-control-allow-headers" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-max-age" response `shouldBe` Just "86400"

testNoCORSWithoutSNI :: HasTestEnv => Expectation
testNoCORSWithoutSNI =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpXFTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caXFTP = C.KeyHash fpXFTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["xftp/1"], useSNI = False}
    withH2Client defaultSupportedParams cfg caXFTP $ \h2 -> do
      let req = H2.requestNoBody "POST" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Nothing

testFileChunkDeliverySNI :: HasTestEnv => Expectation
testFileChunkDeliverySNI =
  withXFTPServerSNI $ \_ -> testXFTPClient $ \c -> runRight_ $ runTestFileChunkDelivery c c

testWebHandshake :: HasTestEnv => Expectation
testWebHandshake =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpWeb <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    Fingerprint fpXFTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let webCaHash = C.KeyHash fpWeb
        keyHash = C.KeyHash fpXFTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    withH2Client defaultSupportedParamsHTTPS cfg webCaHash $ \h2 -> do
      -- Send web challenge as XFTPClientHello
      g <- C.newRandom
      challenge <- atomically $ C.randomBytes 32 g
      helloBody <- either (error . show) pure $ C.pad (smpEncode (XFTPClientHello {webChallenge = Just challenge})) xftpBlockSize
      let helloReq = H2.requestBuilder "POST" "/" [("xftp-web-hello", "1")] $ byteString helloBody
      resp1 <- either (error . show) pure =<< HC.sendRequest h2 helloReq (Just 5000000)
      let serverHsBody = bodyHead (HC.respBody resp1)
      -- Decode server handshake
      serverHsDecoded <- either (error . show) pure $ C.unPad serverHsBody
      XFTPServerHandshake {sessionId, authPubKey = CertChainPubKey {certChain, signedPubKey}, webIdentityProof} <-
        either error pure $ smpDecode serverHsDecoded
      sig <- maybe (error "expected webIdentityProof") pure webIdentityProof
      -- Verify cert chain identity
      (leafCert, idCert) <- case chainIdCaCerts certChain of
        CCValid {leafCert, idCert} -> pure (leafCert, idCert)
        _ -> error "expected CCValid chain"
      let Fingerprint idCertFP = getFingerprint idCert X.HashSHA256
      C.KeyHash idCertFP `shouldBe` keyHash
      -- Verify challenge signature (identity proof)
      leafPubKey <- either error pure $ C.x509ToPublic' $ X.certPubKey $ X.signedObject $ X.getSigned leafCert
      C.verify leafPubKey sig (challenge <> sessionId) `shouldBe` True
      -- Verify signedPubKey (DH key auth)
      void $ either error pure $ C.verifyX509 leafPubKey signedPubKey
      -- Send client handshake with echoed challenge
      let clientHs = XFTPClientHandshake {xftpVersion = VersionXFTP 1, keyHash, entitlementProof = Nothing}
      clientHsPadded <- either (error . show) pure $ C.pad (smpEncode clientHs) xftpBlockSize
      let clientHsReq = H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded
      resp2 <- either (error . show) pure =<< HC.sendRequest h2 clientHsReq (Just 5000000)
      let ackBody = bodyHead (HC.respBody resp2)
      B.length ackBody `shouldBe` 0

testWebReHandshake :: HasTestEnv => Expectation
testWebReHandshake =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpWeb <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    Fingerprint fpXFTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let webCaHash = C.KeyHash fpWeb
        keyHash = C.KeyHash fpXFTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    withH2Client defaultSupportedParamsHTTPS cfg webCaHash $ \h2 -> do
      g <- C.newRandom
      -- First handshake
      challenge1 <- atomically $ C.randomBytes 32 g
      helloBody1 <- either (error . show) pure $ C.pad (smpEncode (XFTPClientHello {webChallenge = Just challenge1})) xftpBlockSize
      let helloReq1 = H2.requestBuilder "POST" "/" [("xftp-web-hello", "1")] $ byteString helloBody1
      resp1 <- either (error . show) pure =<< HC.sendRequest h2 helloReq1 (Just 5000000)
      serverHs1 <- either (error . show) pure $ C.unPad (bodyHead (HC.respBody resp1))
      XFTPServerHandshake {sessionId = sid1} <- either error pure $ smpDecode serverHs1
      clientHsPadded <- either (error . show) pure $ C.pad (smpEncode (XFTPClientHandshake {xftpVersion = VersionXFTP 1, keyHash, entitlementProof = Nothing})) xftpBlockSize
      resp1b <- either (error . show) pure =<< HC.sendRequest h2 (H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded) (Just 5000000)
      B.length (bodyHead (HC.respBody resp1b)) `shouldBe` 0
      -- Re-handshake on same connection with xftp-web-hello header
      challenge2 <- atomically $ C.randomBytes 32 g
      helloBody2 <- either (error . show) pure $ C.pad (smpEncode (XFTPClientHello {webChallenge = Just challenge2})) xftpBlockSize
      let helloReq2 = H2.requestBuilder "POST" "/" [("xftp-web-hello", "1")] $ byteString helloBody2
      resp2 <- either (error . show) pure =<< HC.sendRequest h2 helloReq2 (Just 5000000)
      serverHs2 <- either (error . show) pure $ C.unPad (bodyHead (HC.respBody resp2))
      XFTPServerHandshake {sessionId = sid2} <- either error pure $ smpDecode serverHs2
      sid2 `shouldBe` sid1
      -- Complete re-handshake
      resp2b <- either (error . show) pure =<< HC.sendRequest h2 (H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded) (Just 5000000)
      B.length (bodyHead (HC.respBody resp2b)) `shouldBe` 0

testStaleWebSession :: HasTestEnv => Expectation
testStaleWebSession =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpWeb <- loadFileFingerprint "tests/fixtures/web_ca.crt"
    let webCaHash = C.KeyHash fpWeb
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    withH2Client defaultSupportedParamsHTTPS cfg webCaHash $ \h2 -> do
      -- Send a command on web connection without doing hello (no xftp-web-hello header)
      dummyBody <- either (error . show) pure $ C.pad "PING" xftpBlockSize
      let req = H2.requestBuilder "POST" "/" [] $ byteString dummyBody
      resp <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      let respBody = bodyHead (HC.respBody resp)
      -- Server should return padded SESSION error
      B.length respBody `shouldBe` xftpBlockSize
      decoded <- either (error . show) pure $ C.unPad respBody
      decoded `shouldBe` smpEncode SESSION


