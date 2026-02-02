{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPServerTests where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import qualified Crypto.PubKey.RSA as RSA
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Builder (byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Data.CaseInsensitive as CI
import Data.List (find, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import Network.HPACK.Token (tokenKey)
import qualified Network.HTTP2.Client as H2
import ServerTests (logSize)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Description (kb)
import Simplex.FileTransfer.Protocol (FileInfo (..), XFTPFileId, xftpBlockSize)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.FileTransfer.Transport (XFTPClientHandshake (..), XFTPClientHello (..), XFTPErrorType (..), XFTPRcvChunkSpec (..), XFTPServerHandshake (..), pattern VersionXFTP)
import Simplex.Messaging.Client (ProtocolClientError (..))
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Protocol (BasicAuth, EntityId (..), pattern NoEntity)
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import Simplex.Messaging.Transport (CertChainPubKey (..), TLS (..), TransportPeer (..), defaultSupportedParams, defaultSupportedParamsHTTPS)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), TransportHost (..), defaultTransportClientConfig, runTLSTransportClient)
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..))
import qualified Simplex.Messaging.Transport.HTTP2.Client as HC
import Simplex.Messaging.Transport.Server (loadFileFingerprint)
import Simplex.Messaging.Transport.Shared (ChainCertificates (..), chainIdCaCerts)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import Test.Hspec hiding (fit, it)
import UnliftIO.STM
import Util
import XFTPClient

xftpServerTests :: Spec
xftpServerTests =
  before_ (createDirectoryIfMissing False xftpServerFiles) . after_ (removeDirectoryRecursive xftpServerFiles) $ do
    describe "XFTP file chunk delivery" $ do
      it "should create, upload and receive file chunk (1 client)" testFileChunkDelivery
      it "should create, upload and receive file chunk (2 clients)" testFileChunkDelivery2
      it "should create, add recipients, upload and receive file chunk" testFileChunkDeliveryAddRecipients
      it "should delete file chunk (1 client)" testFileChunkDelete
      it "should delete file chunk (2 clients)" testFileChunkDelete2
      it "should acknowledge file chunk reception (1 client)" testFileChunkAck
      it "should acknowledge file chunk reception (2 clients)" testFileChunkAck2
      it "should not allow chunks of wrong size" testWrongChunkSize
      it "should expire chunks after set interval" testFileChunkExpiration
      it "should disconnect inactive clients" testInactiveClientExpiration
      it "should not allow uploading chunks after specified storage quota" testFileStorageQuota
      it "should store file records to log and restore them after server restart" testFileLog
      describe "XFTP basic auth" $ do
        --                                               allow FNEW | server auth | clnt auth | success
        it "prohibited without basic auth" $ testFileBasicAuth True (Just "pwd") Nothing False
        it "prohibited when auth is incorrect" $ testFileBasicAuth True (Just "pwd") (Just "wrong") False
        it "prohibited when FNEW disabled" $ testFileBasicAuth False (Just "pwd") (Just "pwd") False
        it "allowed with correct basic auth" $ testFileBasicAuth True (Just "pwd") (Just "pwd") True
        it "allowed with auth on server without auth" $ testFileBasicAuth True Nothing (Just "any") True
      it "should not change content for uploaded and committed files" testFileSkipCommitted
    describe "XFTP SNI and CORS" $ do
      it "should select web certificate when SNI is used" testSNICertSelection
      it "should select XFTP certificate when SNI is not used" testNoSNICertSelection
      it "should add CORS headers when SNI is used" testCORSHeaders
      it "should respond to OPTIONS preflight with CORS headers" testCORSPreflight
      it "should not add CORS headers without SNI" testNoCORSWithoutSNI
      it "should upload and receive file chunk through SNI-enabled server" testFileChunkDeliverySNI
      it "should complete web handshake with challenge-response" testWebHandshake

chSize :: Integral a => a
chSize = kb 128

testChunkPath :: FilePath
testChunkPath = "tests/tmp/chunk1"

createTestChunk :: FilePath -> IO ByteString
createTestChunk fp = do
  g <- C.newRandom
  bytes <- atomically $ C.randomBytes chSize g
  B.writeFile fp bytes
  pure bytes

readChunk :: XFTPFileId -> IO ByteString
readChunk sId = B.readFile (xftpServerFiles </> B.unpack (B64.encode $ unEntityId sId))

testFileChunkDelivery :: Expectation
testFileChunkDelivery = xftpTest $ \c -> runRight_ $ runTestFileChunkDelivery c c

testFileChunkDelivery2 :: Expectation
testFileChunkDelivery2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelivery s r

runTestFileChunkDelivery :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
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
  downloadXFTPChunk g r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize (digest <> "_wrong"))
    `catchError` (liftIO . (`shouldBe` PCEResponseError DIGEST))
  downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes

testFileChunkDeliveryAddRecipients :: Expectation
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
  testReceiveChunk r1 rpKey1 rId1 "tests/tmp/received_chunk1"
  testReceiveChunk r2 rpKey2 rId2 "tests/tmp/received_chunk2"
  testReceiveChunk r3 rpKey3 rId3 "tests/tmp/received_chunk3"

testFileChunkDelete :: Expectation
testFileChunkDelete = xftpTest $ \c -> runRight_ $ runTestFileChunkDelete c c

testFileChunkDelete2 :: Expectation
testFileChunkDelete2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelete s r

runTestFileChunkDelete :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
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

  downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
  deleteXFTPChunk s spKey sId
  liftIO $
    readChunk sId
      `shouldThrow` \(e :: SomeException) -> "does not exist" `isInfixOf` show e
  downloadXFTPChunk g r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  deleteXFTPChunk s spKey sId
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testFileChunkAck :: Expectation
testFileChunkAck = xftpTest $ \c -> runRight_ $ runTestFileChunkAck c c

testFileChunkAck2 :: Expectation
testFileChunkAck2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkAck s r

runTestFileChunkAck :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkAck s r = do
  g <- liftIO C.newRandom
  (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey] Nothing
  uploadXFTPChunk s spKey sId chunkSpec

  downloadXFTPChunk g r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
  ackXFTPChunk r rpKey rId
  liftIO $ readChunk sId `shouldReturn` bytes
  downloadXFTPChunk g r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  ackXFTPChunk r rpKey rId
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testWrongChunkSize :: Expectation
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

testFileChunkExpiration :: Expectation
testFileChunkExpiration = withXFTPServerCfg testXFTPServerConfig {fileExpiration} $
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

    downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
    liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes

    liftIO $ threadDelay 1000000
    downloadXFTPChunk g c rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  where
    fileExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}

testInactiveClientExpiration :: Expectation
testInactiveClientExpiration = withXFTPServerCfg testXFTPServerConfig {inactiveClientExpiration} $ \_ -> runRight_ $ do
  disconnected <- newEmptyTMVarIO
  ts <- liftIO getCurrentTime
  c <- ExceptT $ getXFTPClient (1, testXFTPServer, Nothing) testXFTPClientConfig [] ts (\_ -> atomically $ putTMVar disconnected ())
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

testFileStorageQuota :: Expectation
testFileStorageQuota = withXFTPServerCfg testXFTPServerConfig {fileSizeQuota = Just $ chSize * 2} $
  \_ -> testXFTPClient $ \c -> runRight_ $ do
    g <- liftIO C.newRandom
    (sndKey, spKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (rcvKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    bytes <- liftIO $ createTestChunk testChunkPath
    digest <- liftIO $ LC.sha256Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
        download rId = do
          downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
          liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
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

testFileLog :: Expectation
testFileLog = do
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
    downloadXFTPChunk g c rpKey1 rId1 (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    downloadXFTPChunk g c rpKey2 rId2 (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    rId1 <- liftIO $ readTVarIO rIdVar1
    rId2 <- liftIO $ readTVarIO rIdVar2
    -- recipient 1 can download, acknowledges - +1 to log
    download g c rpKey1 rId1 digest bytes
    ackXFTPChunk c rpKey1 rId1
    -- recipient 2 can download
    download g c rpKey2 rId2 digest bytes
  logSize testXFTPLogFile `shouldReturn` 4
  logSize testXFTPStatsBackupFile `shouldReturn` 15

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> pure () -- ack is compacted - -1 from log
  logSize testXFTPLogFile `shouldReturn` 3

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    sId <- liftIO $ readTVarIO sIdVar
    rId1 <- liftIO $ readTVarIO rIdVar1
    rId2 <- liftIO $ readTVarIO rIdVar2
    -- recipient 1 can't download due to previous acknowledgement
    download g c rpKey1 rId1 digest bytes
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    -- recipient 2 can download
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
      downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
      liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes

testFileBasicAuth :: Bool -> Maybe BasicAuth -> Maybe BasicAuth -> Bool -> IO ()
testFileBasicAuth allowNewFiles newFileBasicAuth clntAuth success =
  withXFTPServerCfg testXFTPServerConfig {allowNewFiles, newFileBasicAuth} $
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
            downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk" chSize digest
            liftIO $ B.readFile "tests/tmp/received_chunk" `shouldReturn` bytes
          else do
            void (createXFTPChunk c spKey file [rcvKey] clntAuth)
              `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testFileSkipCommitted :: IO ()
testFileSkipCommitted =
  withXFTPServerCfg testXFTPServerConfig $
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
        downloadXFTPChunk g c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk" chSize digest
        liftIO $ B.readFile "tests/tmp/received_chunk" `shouldReturn` bytes -- new chunk content got ignored

-- SNI and CORS tests

lookupResponseHeader :: B.ByteString -> H2.Response -> Maybe B.ByteString
lookupResponseHeader name resp =
  snd <$> find (\(t, _) -> tokenKey t == CI.mk name) (fst $ H2.responseHeaders resp)

getCerts :: TLS 'TClient -> [X.Certificate]
getCerts tls =
  let X.CertificateChain cc = tlsPeerCert tls
   in map (X.signedObject . X.getSigned) cc

testSNICertSelection :: Expectation
testSNICertSelection =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just caHTTP) $ \(tls :: TLS 'TClient) -> do
      tlsALPN tls `shouldBe` Just "h2"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyRSA rsa} : _ -> RSA.public_size rsa `shouldSatisfy` (> 0)
        leaf : _ -> expectationFailure $ "Expected RSA cert, got: " <> show (X.certPubKey leaf)
        [] -> expectationFailure "Empty certificate chain"

testNoSNICertSelection :: Expectation
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

testCORSHeaders :: Expectation
testCORSHeaders =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just caHTTP) $ \(tls :: TLS 'TClient) -> do
      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls
      let req = H2.requestNoBody "POST" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-expose-headers" response `shouldBe` Just "*"

testCORSPreflight :: Expectation
testCORSPreflight =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caHTTP = C.KeyHash fpHTTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just caHTTP) $ \(tls :: TLS 'TClient) -> do
      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls
      let req = H2.requestNoBody "OPTIONS" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-allow-methods" response `shouldBe` Just "POST, OPTIONS"
      lookupResponseHeader "access-control-allow-headers" response `shouldBe` Just "*"
      lookupResponseHeader "access-control-max-age" response `shouldBe` Just "86400"

testNoCORSWithoutSNI :: Expectation
testNoCORSWithoutSNI =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fpXFTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caXFTP = C.KeyHash fpXFTP
        cfg = defaultTransportClientConfig {clientALPN = Just ["xftp/1"], useSNI = False}
    runTLSTransportClient defaultSupportedParams Nothing cfg Nothing "localhost" xftpTestPort (Just caXFTP) $ \(tls :: TLS 'TClient) -> do
      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls
      let req = H2.requestNoBody "POST" "/" []
      HC.HTTP2Response {HC.response} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 5000000)
      lookupResponseHeader "access-control-allow-origin" response `shouldBe` Nothing

testFileChunkDeliverySNI :: Expectation
testFileChunkDeliverySNI =
  withXFTPServerSNI $ \_ -> testXFTPClient $ \c -> runRight_ $ runTestFileChunkDelivery c c

testWebHandshake :: Expectation
testWebHandshake =
  withXFTPServerSNI $ \_ -> do
    Fingerprint fp <- loadFileFingerprint "tests/fixtures/ca.crt"
    let keyHash = C.KeyHash fp
        cfg = defaultTransportClientConfig {clientALPN = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfg Nothing "localhost" xftpTestPort (Just keyHash) $ \(tls :: TLS 'TClient) -> do
      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 65536}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg (THDomainName "localhost") xftpTestPort mempty 65536 tls
      -- Send web challenge as XFTPClientHello
      g <- C.newRandom
      challenge <- atomically $ C.randomBytes 32 g
      let helloBody = smpEncode (XFTPClientHello {webChallenge = Just challenge})
          helloReq = H2.requestBuilder "POST" "/" [] $ byteString helloBody
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
      let clientHs = XFTPClientHandshake {xftpVersion = VersionXFTP 1, keyHash}
      clientHsPadded <- either (error . show) pure $ C.pad (smpEncode clientHs) xftpBlockSize
      let clientHsReq = H2.requestBuilder "POST" "/" [] $ byteString clientHsPadded
      resp2 <- either (error . show) pure =<< HC.sendRequest h2 clientHsReq (Just 5000000)
      let ackBody = bodyHead (HC.respBody resp2)
      B.length ackBody `shouldBe` 0
