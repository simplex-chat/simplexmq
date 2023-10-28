{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPAgent where

import AgentTests.FunctionalAPITests (get, getSMPAgentClient', rfGet, runRight, runRight_, sfGet)
import Control.Concurrent (threadDelay)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.List (find, isSuffixOf)
import Data.Maybe (fromJust)
import SMPAgentClient (agentCfg, initAgentServers, testDB, testDB2, testDB3)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), XFTPErrorType (AUTH))
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Agent (AgentClient, disconnectAgentClient, testProtocolServer, xftpDeleteRcvFile, xftpDeleteSndFileInternal, xftpDeleteSndFileRemote, xftpReceiveFile, xftpSendFile, xftpStartWorkers)
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..))
import Simplex.Messaging.Agent.Protocol (ACommand (..), AgentErrorType (..), BrokerErrorType (..), RcvFileId, SndFileId, noAuthSrv)
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs)
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (BasicAuth, ProtoServerWithAuth (..), ProtocolServer (..), XFTPServerWithAuth)
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize, listDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec
import XFTPCLI
import XFTPClient

xftpAgentTests :: Spec
xftpAgentTests = around_ testBracket . describe "agent XFTP API" $ do
  it "should send and receive file" testXFTPAgentSendReceive
  it "should send and receive with encrypted local files" testXFTPAgentSendReceiveEncrypted
  it "should resume receiving file after restart" testXFTPAgentReceiveRestore
  it "should cleanup rcv tmp path after permanent error" testXFTPAgentReceiveCleanup
  it "should resume sending file after restart" testXFTPAgentSendRestore
  it "should cleanup snd prefix path after permanent error" testXFTPAgentSendCleanup
  it "should delete sent file on server" testXFTPAgentDelete
  it "should resume deleting file after restart" testXFTPAgentDeleteRestore
  it "should request additional recipient IDs when number of recipients exceeds maximum per request" testXFTPAgentRequestAdditionalRecipientIDs
  describe "XFTP server test via agent API" $ do
    it "should pass without basic auth" $ testXFTPServerTest Nothing (noAuthSrv testXFTPServer2) `shouldReturn` Nothing
    let srv1 = testXFTPServer2 {keyHash = "1234"}
    it "should fail with incorrect fingerprint" $ do
      testXFTPServerTest Nothing (noAuthSrv srv1) `shouldReturn` Just (ProtocolTestFailure TSConnect $ BROKER (B.unpack $ strEncode srv1) NETWORK)
    describe "server with password" $ do
      let auth = Just "abcd"
          srv = ProtoServerWithAuth testXFTPServer2
          authErr = Just (ProtocolTestFailure TSCreateFile $ XFTP AUTH)
      it "should pass with correct password" $ testXFTPServerTest auth (srv auth) `shouldReturn` Nothing
      it "should fail without password" $ testXFTPServerTest auth (srv Nothing) `shouldReturn` authErr
      it "should fail with incorrect password" $ testXFTPServerTest auth (srv $ Just "wrong") `shouldReturn` authErr

rfProgress :: forall m. (HasCallStack, MonadIO m, MonadFail m) => AgentClient -> Int64 -> m ()
rfProgress c expected = loop 0
  where
    loop :: HasCallStack => Int64 -> m ()
    loop prev = do
      (_, _, RFPROG rcvd total) <- rfGet c
      checkProgress (prev, expected) (rcvd, total) loop

sfProgress :: forall m. (HasCallStack, MonadIO m, MonadFail m) => AgentClient -> Int64 -> m ()
sfProgress c expected = loop 0
  where
    loop :: HasCallStack => Int64 -> m ()
    loop prev = do
      (_, _, SFPROG sent total) <- sfGet c
      checkProgress (prev, expected) (sent, total) loop

-- checks that progress increases till it reaches total
checkProgress :: (HasCallStack, MonadIO m) => (Int64, Int64) -> (Int64, Int64) -> (Int64 -> m ()) -> m ()
checkProgress (prev, expected) (progress, total) loop
  | total /= expected = error "total /= expected"
  | progress <= prev = error "progress <= prev"
  | progress > total = error "progress > total"
  | progress < total = loop progress
  | otherwise = pure ()

testXFTPAgentSendReceive :: HasCallStack => IO ()
testXFTPAgentSendReceive = withXFTPServer $ do
  filePath <- createRandomFile
  -- send file, delete snd file internally
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  (rfd1, rfd2) <- runRight $ do
    (sfId, _, rfd1, rfd2) <- testSend sndr filePath
    xftpDeleteSndFileInternal sndr sfId
    pure (rfd1, rfd2)

  -- receive file, delete rcv file
  testReceiveDelete rfd1 filePath
  testReceiveDelete rfd2 filePath
  where
    testReceiveDelete rfd originalFilePath = do
      rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
      runRight_ $ do
        rfId <- testReceive rcp rfd originalFilePath
        xftpDeleteRcvFile rcp rfId
      disconnectAgentClient rcp

testXFTPAgentSendReceiveEncrypted :: HasCallStack => IO ()
testXFTPAgentSendReceiveEncrypted = withXFTPServer $ do
  filePath <- createRandomFile
  s <- LB.readFile filePath
  file <- CryptoFile (senderFiles </> "encrypted_testfile") . Just <$> CF.randomArgs
  runRight_ $ CF.writeFile file s
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  (rfd1, rfd2) <- runRight $ do
    (sfId, _, rfd1, rfd2) <- testSendCF sndr file
    xftpDeleteSndFileInternal sndr sfId
    pure (rfd1, rfd2)
  -- receive file, delete rcv file
  testReceiveDelete rfd1 filePath
  testReceiveDelete rfd2 filePath
  where
    testReceiveDelete rfd originalFilePath = do
      rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
      cfArgs <- Just <$> CF.randomArgs
      runRight_ $ do
        rfId <- testReceiveCF rcp rfd cfArgs originalFilePath
        xftpDeleteRcvFile rcp rfId
      disconnectAgentClient rcp

createRandomFile :: HasCallStack => IO FilePath
createRandomFile = do
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  getFileSize filePath `shouldReturn` mb 17
  pure filePath

testSend :: HasCallStack => AgentClient -> FilePath -> ExceptT AgentErrorType IO (SndFileId, ValidFileDescription 'FSender, ValidFileDescription 'FRecipient, ValidFileDescription 'FRecipient)
testSend sndr = testSendCF sndr . CF.plain

testSendCF :: HasCallStack => AgentClient -> CryptoFile -> ExceptT AgentErrorType IO (SndFileId, ValidFileDescription 'FSender, ValidFileDescription 'FRecipient, ValidFileDescription 'FRecipient)
testSendCF sndr file = do
  xftpStartWorkers sndr (Just senderFiles)
  sfId <- xftpSendFile sndr 1 file 2
  sfProgress sndr $ mb 18
  ("", sfId', SFDONE sndDescr [rfd1, rfd2]) <- sfGet sndr
  liftIO $ sfId' `shouldBe` sfId
  pure (sfId, sndDescr, rfd1, rfd2)

testReceive :: HasCallStack => AgentClient -> ValidFileDescription 'FRecipient -> FilePath -> ExceptT AgentErrorType IO RcvFileId
testReceive rcp rfd = testReceiveCF rcp rfd Nothing

testReceiveCF :: HasCallStack => AgentClient -> ValidFileDescription 'FRecipient -> Maybe CryptoFileArgs -> FilePath -> ExceptT AgentErrorType IO RcvFileId
testReceiveCF rcp rfd cfArgs originalFilePath = do
  xftpStartWorkers rcp (Just recipientFiles)
  rfId <- xftpReceiveFile rcp 1 rfd cfArgs
  rfProgress rcp $ mb 18
  ("", rfId', RFDONE path) <- rfGet rcp
  liftIO $ do
    rfId' `shouldBe` rfId
    sentFile <- LB.readFile originalFilePath
    runExceptT (CF.readFile $ CryptoFile path cfArgs) `shouldReturn` Right sentFile
  pure rfId

logCfgNoLogs :: LogConfig
logCfgNoLogs = LogConfig {lc_file = Nothing, lc_stderr = False}

testXFTPAgentReceiveRestore :: HasCallStack => IO ()
testXFTPAgentReceiveRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      (_, _, rfd, _) <- testSend sndr filePath
      pure rfd

  -- receive file - should not succeed with server down
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
  rfId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd Nothing
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure rfId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file - should start downloading with server up
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    ("", rfId', RFPROG _ _) <- rfGet rcp'
    liftIO $ rfId' `shouldBe` rfId
    disconnectAgentClient rcp'

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file - should continue downloading with server up
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    rfProgress rcp' $ mb 18
    ("", rfId', RFDONE path) <- rfGet rcp'
    liftIO $ do
      rfId' `shouldBe` rfId
      file <- B.readFile filePath
      B.readFile path `shouldReturn` file

  -- tmp path should be removed after receiving file
  doesDirectoryExist tmpPath `shouldReturn` False

testXFTPAgentReceiveCleanup :: HasCallStack => IO ()
testXFTPAgentReceiveCleanup = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      (_, _, rfd, _) <- testSend sndr filePath
      pure rfd

  -- receive file - should not succeed with server down
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
  rfId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd Nothing
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure rfId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerThreadOn $ \_ -> do
    -- receive file - should fail with AUTH error
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp'
    rfId' `shouldBe` rfId

  -- tmp path should be removed after permanent error
  doesDirectoryExist tmpPath `shouldReturn` False

testXFTPAgentSendRestore :: HasCallStack => IO ()
testXFTPAgentSendRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  -- send file - should not succeed with server down
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  sfId <- runRight $ do
    xftpStartWorkers sndr (Just senderFiles)
    sfId <- xftpSendFile sndr 1 (CF.plain filePath) 2
    liftIO $ timeout 1000000 (get sndr) `shouldReturn` Nothing -- wait for worker to encrypt and attempt to create file
    pure sfId
  disconnectAgentClient sndr

  dirEntries <- listDirectory senderFiles
  let prefixDir = fromJust $ find (isSuffixOf "_snd.xftp") dirEntries
      prefixPath = senderFiles </> prefixDir
      encPath = prefixPath </> "xftp.encrypted"
  doesDirectoryExist prefixPath `shouldReturn` True
  doesFileExist encPath `shouldReturn` True

  withXFTPServerStoreLogOn $ \_ -> do
    -- send file - should start uploading with server up
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)
    ("", sfId', SFPROG _ _) <- sfGet sndr'
    liftIO $ sfId' `shouldBe` sfId
    disconnectAgentClient sndr'

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> do
    -- send file - should continue uploading with server up
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)
    sfProgress sndr' $ mb 18
    ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr'
    liftIO $ sfId' `shouldBe` sfId

    -- prefix path should be removed after sending file
    threadDelay 100000
    doesDirectoryExist prefixPath `shouldReturn` False
    doesFileExist encPath `shouldReturn` False

    -- receive file
    rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ . void $
      testReceive rcp rfd1 filePath

testXFTPAgentSendCleanup :: HasCallStack => IO ()
testXFTPAgentSendCleanup = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  sfId <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    sfId <- runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      sfId <- xftpSendFile sndr 1 (CF.plain filePath) 2
      -- wait for progress events for 5 out of 6 chunks - at this point all chunks should be created on the server
      forM_ [1 .. 5 :: Integer] $ \_ -> do
        (_, _, SFPROG _ _) <- sfGet sndr
        pure ()
      pure sfId
    disconnectAgentClient sndr
    pure sfId

  dirEntries <- listDirectory senderFiles
  let prefixDir = fromJust $ find (isSuffixOf "_snd.xftp") dirEntries
      prefixPath = senderFiles </> prefixDir
      encPath = prefixPath </> "xftp.encrypted"
  doesDirectoryExist prefixPath `shouldReturn` True
  doesFileExist encPath `shouldReturn` True

  withXFTPServerThreadOn $ \_ -> do
    -- send file - should fail with AUTH error
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)
    ("", sfId', SFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- sfGet sndr'
    sfId' `shouldBe` sfId

    -- prefix path should be removed after permanent error
    doesDirectoryExist prefixPath `shouldReturn` False
    doesFileExist encPath `shouldReturn` False

testXFTPAgentDelete :: HasCallStack => IO ()
testXFTPAgentDelete = withGlobalLogging logCfgNoLogs $
  withXFTPServer $ do
    filePath <- createRandomFile

    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    (sfId, sndDescr, rfd1, rfd2) <- runRight $ testSend sndr filePath

    -- receive file
    rcp1 <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ . void $
      testReceive rcp1 rfd1 filePath

    length <$> listDirectory xftpServerFiles `shouldReturn` 6

    -- delete file
    runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      xftpDeleteSndFileRemote sndr 1 sfId sndDescr
      Nothing <- liftIO $ 100000 `timeout` sfGet sndr
      pure ()
    disconnectAgentClient rcp1

    threadDelay 1000000
    length <$> listDirectory xftpServerFiles `shouldReturn` 0

    -- receive file - should fail with AUTH error
    rcp2 <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight $ do
      xftpStartWorkers rcp2 (Just recipientFiles)
      rfId <- xftpReceiveFile rcp2 1 rfd2 Nothing
      ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp2
      liftIO $ rfId' `shouldBe` rfId

testXFTPAgentDeleteRestore :: HasCallStack => IO ()
testXFTPAgentDeleteRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  (sfId, sndDescr, rfd2) <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    (sfId, sndDescr, rfd1, rfd2) <- runRight $ testSend sndr filePath

    -- receive file
    rcp1 <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ . void $
      testReceive rcp1 rfd1 filePath
    disconnectAgentClient rcp1
    disconnectAgentClient sndr
    pure (sfId, sndDescr, rfd2)

  -- delete file - should not succeed with server down
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight $ do
    xftpStartWorkers sndr (Just senderFiles)
    xftpDeleteSndFileRemote sndr 1 sfId sndDescr
    liftIO $ timeout 300000 (get sndr) `shouldReturn` Nothing -- wait for worker attempt
  disconnectAgentClient sndr

  threadDelay 300000
  length <$> listDirectory xftpServerFiles `shouldReturn` 6

  withXFTPServerStoreLogOn $ \_ -> do
    -- delete file - should succeed with server up
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)

    threadDelay 1000000
    length <$> listDirectory xftpServerFiles `shouldReturn` 0

    -- receive file - should fail with AUTH error
    rcp2 <- getSMPAgentClient' agentCfg initAgentServers testDB3
    runRight $ do
      xftpStartWorkers rcp2 (Just recipientFiles)
      rfId <- xftpReceiveFile rcp2 1 rfd2 Nothing
      ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp2
      liftIO $ rfId' `shouldBe` rfId

testXFTPAgentRequestAdditionalRecipientIDs :: HasCallStack => IO ()
testXFTPAgentRequestAdditionalRecipientIDs = withXFTPServer $ do
  filePath <- createRandomFile

  -- send file
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  rfds <- runRight $ do
    xftpStartWorkers sndr (Just senderFiles)
    sfId <- xftpSendFile sndr 1 (CF.plain filePath) 500
    sfProgress sndr $ mb 18
    ("", sfId', SFDONE _sndDescr rfds) <- sfGet sndr
    liftIO $ do
      sfId' `shouldBe` sfId
      length rfds `shouldBe` 500
    pure rfds

  -- receive file using different descriptions
  -- ! revise number of recipients and indexes if xftpMaxRecipientsPerRequest is changed
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    void $ testReceive rcp (head rfds) filePath
    void $ testReceive rcp (rfds !! 99) filePath
    void $ testReceive rcp (rfds !! 299) filePath
    void $ testReceive rcp (rfds !! 499) filePath

testXFTPServerTest :: HasCallStack => Maybe BasicAuth -> XFTPServerWithAuth -> IO (Maybe ProtocolTestFailure)
testXFTPServerTest newFileBasicAuth srv =
  withXFTPServerCfg testXFTPServerConfig {newFileBasicAuth, xftpPort = xftpTestPort2} $ \_ -> do
    a <- getSMPAgentClient' agentCfg initAgentServers testDB -- initially passed server is not running
    runRight $ testProtocolServer a 1 srv
