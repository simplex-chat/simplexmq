{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.XFTPStoreTests (xftpStoreTests, xftpMigrationTests) where

import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.Word (Word32)
import qualified Data.Set as S
import Simplex.FileTransfer.Protocol (FileInfo (..), SFileParty (..))
import Simplex.FileTransfer.Server.Store
import Simplex.FileTransfer.Server.Store.Postgres (PostgresFileStore)
import Simplex.FileTransfer.Server.Store.Postgres.Config (PostgresFileStoreCfg)
import Simplex.FileTransfer.Server.StoreLog
import Simplex.FileTransfer.Transport (XFTPErrorType (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (BlockingInfo (..), BlockingReason (..), EntityId (..))
import Simplex.Messaging.Server.QueueStore (ServerEntityStatus (..))
import Simplex.Messaging.SystemTime (RoundedSystemTime (..))
import Simplex.FileTransfer.Server.Store.Postgres (importFileStore, exportFileStore)
import Simplex.FileTransfer.Server.StoreLog (readWriteFileStore, writeFileStore)
import Simplex.Messaging.Server.StoreLog (openWriteStoreLog)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec hiding (fit, it)
import UnliftIO.STM
import Util
import XFTPClient (testXFTPPostgresCfg)

xftpStoreTests :: Spec
xftpStoreTests = describe "PostgresFileStore operations" $ do
  it "should add and get file by sender" testAddGetFileSender
  it "should add and get file by recipient" testAddGetFileRecipient
  it "should reject duplicate file" testDuplicateFile
  it "should return AUTH for nonexistent file" testGetNonexistent
  it "should set file path with IS NULL guard" testSetFilePath
  it "should reject duplicate recipient" testDuplicateRecipient
  it "should delete file and cascade recipients" testDeleteFileCascade
  it "should block file and update status" testBlockFile
  it "should ack file reception" testAckFile
  it "should return expired files with limit" testExpiredFiles
  it "should compute used storage and file count" testStorageAndCount

xftpMigrationTests :: Spec
xftpMigrationTests = describe "XFTP migration round-trip" $ do
  it "should export to StoreLog and import back to Postgres preserving data" testMigrationRoundTrip

-- Test helpers

withPgStore :: (PostgresFileStore -> IO ()) -> IO ()
withPgStore test = do
  st <- newFileStore testXFTPPostgresCfg :: IO PostgresFileStore
  test st
  closeFileStore st

testSenderId :: EntityId
testSenderId = EntityId "sender001_______"

testRecipientId :: EntityId
testRecipientId = EntityId "recipient001____"

testRecipientId2 :: EntityId
testRecipientId2 = EntityId "recipient002____"

testFileInfo :: C.APublicAuthKey -> FileInfo
testFileInfo sndKey =
  FileInfo
    { sndKey,
      size = 128000 :: Word32,
      digest = "test_digest_bytes_here___"
    }

testCreatedAt :: RoundedFileTime
testCreatedAt = RoundedSystemTime 1000000

-- Tests

testAddGetFileSender :: Expectation
testAddGetFileSender = withPgStore $ \st -> do
  g <- C.newRandom
  (sk, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sk
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  result <- getFile st SFSender testSenderId
  case result of
    Right (FileRec {senderId, fileInfo = fi, createdAt}, key) -> do
      senderId `shouldBe` testSenderId
      sndKey fi `shouldBe` sk
      size fi `shouldBe` 128000
      createdAt `shouldBe` testCreatedAt
      key `shouldBe` sk
    Left e -> expectationFailure $ "getFile failed: " <> show e

testAddGetFileRecipient :: Expectation
testAddGetFileRecipient = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcpKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addRecipient st testSenderId (FileRecipient testRecipientId rcpKey) `shouldReturn` Right ()
  result <- getFile st SFRecipient testRecipientId
  case result of
    Right (FileRec {senderId}, key) -> do
      senderId `shouldBe` testSenderId
      key `shouldBe` rcpKey
    Left e -> expectationFailure $ "getFile failed: " <> show e

testDuplicateFile :: Expectation
testDuplicateFile = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Left DUPLICATE_

testGetNonexistent :: Expectation
testGetNonexistent = withPgStore $ \st -> do
  getFile st SFSender testSenderId >>= (`shouldBe` Left AUTH) . fmap (const ())
  getFile st SFRecipient testRecipientId >>= (`shouldBe` Left AUTH) . fmap (const ())

testSetFilePath :: Expectation
testSetFilePath = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  setFilePath st testSenderId "/tmp/test_file" `shouldReturn` Right ()
  -- Second setFilePath should fail (file_path IS NULL guard)
  setFilePath st testSenderId "/tmp/other_file" `shouldReturn` Left AUTH
  -- Verify path was set
  result <- getFile st SFSender testSenderId
  case result of
    Right (FileRec {filePath}, _) -> readTVarIO filePath `shouldReturn` Just "/tmp/test_file"
    Left e -> expectationFailure $ "getFile failed: " <> show e

testDuplicateRecipient :: Expectation
testDuplicateRecipient = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcpKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addRecipient st testSenderId (FileRecipient testRecipientId rcpKey) `shouldReturn` Right ()
  addRecipient st testSenderId (FileRecipient testRecipientId rcpKey) `shouldReturn` Left DUPLICATE_

testDeleteFileCascade :: Expectation
testDeleteFileCascade = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcpKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addRecipient st testSenderId (FileRecipient testRecipientId rcpKey) `shouldReturn` Right ()
  deleteFile st testSenderId `shouldReturn` Right ()
  -- File and recipient should both be gone
  getFile st SFSender testSenderId >>= (`shouldBe` Left AUTH) . fmap (const ())
  getFile st SFRecipient testRecipientId >>= (`shouldBe` Left AUTH) . fmap (const ())

testBlockFile :: Expectation
testBlockFile = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  let blockInfo = BlockingInfo {reason = BRContent, notice = Nothing}
  blockFile st testSenderId blockInfo False `shouldReturn` Right ()
  result <- getFile st SFSender testSenderId
  case result of
    Right (FileRec {fileStatus}, _) -> readTVarIO fileStatus `shouldReturn` EntityBlocked blockInfo
    Left e -> expectationFailure $ "getFile failed: " <> show e

testAckFile :: Expectation
testAckFile = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcpKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
  addFile st testSenderId fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addRecipient st testSenderId (FileRecipient testRecipientId rcpKey) `shouldReturn` Right ()
  ackFile st testRecipientId `shouldReturn` Right ()
  -- Recipient gone, but file still exists
  getFile st SFRecipient testRecipientId >>= (`shouldBe` Left AUTH) . fmap (const ())
  result <- getFile st SFSender testSenderId
  case result of
    Right _ -> pure ()
    Left e -> expectationFailure $ "getFile failed: " <> show e

testExpiredFiles :: Expectation
testExpiredFiles = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo = testFileInfo sndKey
      oldTime = RoundedSystemTime 100000
      newTime = RoundedSystemTime 999999999
  -- Add old and new files
  addFile st (EntityId "old_file________") fileInfo oldTime EntityActive `shouldReturn` Right ()
  void $ setFilePath st (EntityId "old_file________") "/tmp/old"
  addFile st (EntityId "new_file________") fileInfo newTime EntityActive `shouldReturn` Right ()
  -- Query expired with cutoff that only catches old file
  expired <- expiredFiles st 500000 100
  length expired `shouldBe` 1
  case expired of
    [(sId, path, sz)] -> do
      sId `shouldBe` EntityId "old_file________"
      path `shouldBe` Just "/tmp/old"
      sz `shouldBe` 128000
    _ -> expectationFailure "expected 1 expired file"

testStorageAndCount :: Expectation
testStorageAndCount = withPgStore $ \st -> do
  g <- C.newRandom
  (sndKey, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  getUsedStorage st `shouldReturn` 0
  getFileCount st `shouldReturn` 0
  let fileInfo = testFileInfo sndKey
  addFile st (EntityId "file_a__________") fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  addFile st (EntityId "file_b__________") fileInfo testCreatedAt EntityActive `shouldReturn` Right ()
  getFileCount st `shouldReturn` 2
  used <- getUsedStorage st
  used `shouldBe` 256000 -- 128000 * 2

-- Migration round-trip test

testMigrationRoundTrip :: Expectation
testMigrationRoundTrip = do
  let storeLogPath = "tests/tmp/xftp-migration-test.log"
      storeLogPath2 = "tests/tmp/xftp-migration-test2.log"
  -- 1. Create STM store with test data
  stmStore <- newFileStore () :: IO STMFileStore
  g <- C.newRandom
  (sndKey1, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (rcpKey1, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (sndKey2, _) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  let fileInfo1 = testFileInfo sndKey1
      fileInfo2 = FileInfo {sndKey = sndKey2, size = 64000, digest = "other_digest____________"}
      sId1 = EntityId "migration_file_1"
      sId2 = EntityId "migration_file_2"
      rId1 = EntityId "migration_rcp_1_"
  addFile stmStore sId1 fileInfo1 testCreatedAt EntityActive `shouldReturn` Right ()
  void $ setFilePath stmStore sId1 "/tmp/file1"
  addRecipient stmStore sId1 (FileRecipient rId1 rcpKey1) `shouldReturn` Right ()
  let testBlockInfo = BlockingInfo {reason = BRSpam, notice = Nothing}
  addFile stmStore sId2 fileInfo2 testCreatedAt (EntityBlocked testBlockInfo) `shouldReturn` Right ()
  -- 2. Write to StoreLog
  sl <- openWriteStoreLog False storeLogPath
  writeFileStore sl stmStore
  closeStoreLog sl
  -- 3. Import StoreLog to Postgres
  importFileStore storeLogPath testXFTPPostgresCfg
  -- StoreLog should be renamed to .bak
  doesFileExist storeLogPath `shouldReturn` False
  doesFileExist (storeLogPath <> ".bak") `shouldReturn` True
  -- 4. Export from Postgres back to StoreLog
  exportFileStore storeLogPath2 testXFTPPostgresCfg
  -- 5. Read exported StoreLog into a new STM store and verify
  stmStore2 <- newFileStore () :: IO STMFileStore
  sl2 <- readWriteFileStore storeLogPath2 stmStore2
  closeStoreLog sl2
  -- Verify file 1
  result1 <- getFile stmStore2 SFSender sId1
  case result1 of
    Right (FileRec {fileInfo = fi, filePath, fileStatus}, _) -> do
      size fi `shouldBe` 128000
      readTVarIO filePath `shouldReturn` Just "/tmp/file1"
      readTVarIO fileStatus `shouldReturn` EntityActive
    Left e -> expectationFailure $ "getFile sId1 failed: " <> show e
  -- Verify recipient
  result1r <- getFile stmStore2 SFRecipient rId1
  case result1r of
    Right (_, key) -> key `shouldBe` rcpKey1
    Left e -> expectationFailure $ "getFile rId1 failed: " <> show e
  -- Verify file 2 (blocked)
  result2 <- getFile stmStore2 SFSender sId2
  case result2 of
    Right (FileRec {fileInfo = fi, fileStatus}, _) -> do
      size fi `shouldBe` 64000
      readTVarIO fileStatus `shouldReturn` EntityBlocked (BlockingInfo {reason = BRSpam, notice = Nothing})
    Left e -> expectationFailure $ "getFile sId2 failed: " <> show e
  -- Cleanup
  removeFile (storeLogPath <> ".bak")
  removeFile storeLogPath2
