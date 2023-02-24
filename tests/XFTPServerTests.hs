{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPServerTests where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List (isInfixOf)
import ServerTests (logSize)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Protocol (FileInfo (..), XFTPErrorType (..))
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.Messaging.Client (ProtocolClientError (..))
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Protocol (SenderId)
import Simplex.Messaging.Server.Expiration (ExpirationConfig (..))
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import Test.Hspec
import XFTPClient

xftpServerTests :: Spec
xftpServerTests =
  before_ (createDirectoryIfMissing False xftpServerFiles)
    . after_ (removeDirectoryRecursive xftpServerFiles)
    . describe "XFTP file chunk delivery"
    $ do
      it "should create, upload and receive file chunk (1 client)" testFileChunkDelivery
      it "should create, upload and receive file chunk (2 clients)" testFileChunkDelivery2
      it "should delete file chunk (1 client)" testFileChunkDelete
      it "should delete file chunk (2 clients)" testFileChunkDelete2
      it "should acknowledge file chunk reception (1 client)" testFileChunkAck
      it "should acknowledge file chunk reception (2 clients)" testFileChunkAck2
      it "should expire chunks after set interval" testFileChunkExpiration
      it "should not allow uploading chunks after specified storage quota" testFileStorageQuota
      it "should store file records to log and restore them after server restart" testFileLog

chSize :: Num n => n
chSize = 128 * 1024

testChunkPath :: FilePath
testChunkPath = "tests/tmp/chunk1"

createTestChunk :: FilePath -> IO ByteString
createTestChunk fp = do
  bytes <- getRandomBytes chSize
  B.writeFile fp bytes
  pure bytes

readChunk :: SenderId -> IO ByteString
readChunk sId = B.readFile (xftpServerFiles </> B.unpack (B64.encode sId))

testFileChunkDelivery :: Expectation
testFileChunkDelivery = xftpTest $ \c -> runRight_ $ runTestFileChunkDelivery c c

testFileChunkDelivery2 :: Expectation
testFileChunkDelivery2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelivery s r

runTestFileChunkDelivery :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkDelivery s r = do
  (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey]
  uploadXFTPChunk s spKey sId chunkSpec
  (sId', _) <- createXFTPChunk s spKey file {digest = digest <> "_wrong"} [rcvKey]
  uploadXFTPChunk s spKey sId' chunkSpec
    `catchError` (liftIO . (`shouldBe` PCEProtocolError DIGEST))
  liftIO $ readChunk sId `shouldReturn` bytes
  downloadXFTPChunk r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize (digest <> "_wrong"))
    `catchError` (liftIO . (`shouldBe` PCEResponseError DIGEST))
  downloadXFTPChunk r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes

testFileChunkDelete :: Expectation
testFileChunkDelete = xftpTest $ \c -> runRight_ $ runTestFileChunkDelete c c

testFileChunkDelete2 :: Expectation
testFileChunkDelete2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkDelete s r

runTestFileChunkDelete :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkDelete s r = do
  (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey]
  uploadXFTPChunk s spKey sId chunkSpec

  downloadXFTPChunk r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
  deleteXFTPChunk s spKey sId
  liftIO $
    readChunk sId
      `shouldThrow` \(e :: SomeException) -> "openBinaryFile: does not exist" `isInfixOf` show e
  downloadXFTPChunk r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  deleteXFTPChunk s spKey sId
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testFileChunkAck :: Expectation
testFileChunkAck = xftpTest $ \c -> runRight_ $ runTestFileChunkAck c c

testFileChunkAck2 :: Expectation
testFileChunkAck2 = xftpTest2 $ \s r -> runRight_ $ runTestFileChunkAck s r

runTestFileChunkAck :: XFTPClient -> XFTPClient -> ExceptT XFTPClientError IO ()
runTestFileChunkAck s r = do
  (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  bytes <- liftIO $ createTestChunk testChunkPath
  digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
  let file = FileInfo {sndKey, size = chSize, digest}
      chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
  (sId, [rId]) <- createXFTPChunk s spKey file [rcvKey]
  uploadXFTPChunk s spKey sId chunkSpec

  downloadXFTPChunk r rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
  ackXFTPChunk r rpKey rId
  liftIO $ readChunk sId `shouldReturn` bytes
  downloadXFTPChunk r rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  ackXFTPChunk r rpKey rId
    `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

testFileChunkExpiration :: Expectation
testFileChunkExpiration = withXFTPServerCfg testXFTPServerConfig {fileExpiration} $
  \_ -> testXFTPClient $ \c -> runRight_ $ do
    (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
    (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
    bytes <- liftIO $ createTestChunk testChunkPath
    digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
    (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey]
    uploadXFTPChunk c spKey sId chunkSpec

    downloadXFTPChunk c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
    liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes

    liftIO $ threadDelay 1000000
    downloadXFTPChunk c rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk2" chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
  where
    fileExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}

testFileStorageQuota :: Expectation
testFileStorageQuota = withXFTPServerCfg testXFTPServerConfig {fileSizeQuota = Just $ chSize * 2} $
  \_ -> testXFTPClient $ \c -> runRight_ $ do
    (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
    (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
    bytes <- liftIO $ createTestChunk testChunkPath
    digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
        download rId = do
          downloadXFTPChunk c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
          liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
    (sId1, [rId1]) <- createXFTPChunk c spKey file [rcvKey]
    uploadXFTPChunk c spKey sId1 chunkSpec
    download rId1
    (sId2, [rId2]) <- createXFTPChunk c spKey file [rcvKey]
    uploadXFTPChunk c spKey sId2 chunkSpec
    download rId2

    (sId3, [rId3]) <- createXFTPChunk c spKey file [rcvKey]
    uploadXFTPChunk c spKey sId3 chunkSpec
      `catchError` (liftIO . (`shouldBe` PCEProtocolError QUOTA))

    deleteXFTPChunk c spKey sId1
    uploadXFTPChunk c spKey sId3 chunkSpec
    download rId3

testFileLog :: Expectation
testFileLog = do
  bytes <- liftIO $ createTestChunk testChunkPath
  (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  (rcvKey, rpKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
  digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
  sIdVar <- newTVarIO ""
  rIdVar <- newTVarIO ""

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    let file = FileInfo {sndKey, size = chSize, digest}
        chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}

    (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey]
    liftIO $ atomically $ do
      writeTVar sIdVar sId
      writeTVar rIdVar rId
    uploadXFTPChunk c spKey sId chunkSpec

    download c rpKey rId digest bytes

  logSize testXFTPLogFile `shouldReturn` 3

  withXFTPServerThreadOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    rId <- liftIO $ readTVarIO rIdVar
    sId <- liftIO $ readTVarIO rIdVar
    downloadXFTPChunk c rpKey rId (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest)
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))
    deleteXFTPChunk c spKey sId
      `catchError` (liftIO . (`shouldBe` PCEProtocolError AUTH))

  withXFTPServerStoreLogOn $ \_ -> testXFTPClient $ \c -> runRight_ $ do
    rId <- liftIO $ readTVarIO rIdVar
    sId <- liftIO $ readTVarIO rIdVar
    download c rpKey rId digest bytes
    deleteXFTPChunk c spKey sId

  logSize testXFTPLogFile `shouldReturn` 0
  removeFile testXFTPLogFile
  where
    download c rpKey rId digest bytes = do
      downloadXFTPChunk c rpKey rId $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
      liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes