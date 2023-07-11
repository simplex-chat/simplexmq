{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPAgent where

import AgentTests.FunctionalAPITests (get, getSMPAgentClient', rfGet, runRight, runRight_, sfGet)
import Control.Concurrent (threadDelay)
import Control.Logger.Simple
import Control.Monad.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List (find, isSuffixOf)
import Data.Maybe (fromJust)
import SMPAgentClient (agentCfg, initAgentServers, testDB)
import SMPClient (xit'')
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), XFTPErrorType (AUTH))
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Agent (AgentClient, disconnectAgentClient, testProtocolServer, xftpDeleteRcvFile, xftpDeleteSndFileInternal, xftpDeleteSndFileRemote, xftpReceiveFile, xftpSendFile, xftpStartWorkers)
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..))
import Simplex.Messaging.Agent.Protocol (ACommand (..), AgentErrorType (..), BrokerErrorType (..), RcvFileId, SndFileId, noAuthSrv)
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (BasicAuth, ProtoServerWithAuth (..), ProtocolServer (..), XFTPServerWithAuth)
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize, listDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec
import XFTPCLI
import XFTPClient

xftpAgentTests :: Spec
xftpAgentTests = around_ testBracket . describe "Functional API" $ do
  it "should send and receive file" testXFTPAgentSendReceive
  it "should resume receiving file after restart" testXFTPAgentReceiveRestore
  it "should cleanup rcv tmp path after permanent error" testXFTPAgentReceiveCleanup
  -- xit'' "should resume sending file after restart" testXFTPAgentSendRestore
  fit "should resume sending file after restart" testXFTPAgentSendRestore
  it "should cleanup snd prefix path after permanent error" testXFTPAgentSendCleanup
  fit "should delete sent file on server" testXFTPAgentDelete
  fit "should resume deleting file after restart" testXFTPAgentDeleteRestore
  fit "should request additional recipient IDs when number of recipients exceeds maximum per request" testXFTPAgentRequestAdditionalRecipientIDs
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

rfProgress :: (MonadIO m, MonadFail m) => AgentClient -> Int64 -> m ()
rfProgress c expected = loop 0
  where
    loop prev = do
      (_, _, RFPROG rcvd total) <- rfGet c
      checkProgress (prev, expected) (rcvd, total) loop

sfProgress :: (MonadIO m, MonadFail m) => AgentClient -> Int64 -> m ()
sfProgress c expected = loop 0
  where
    loop prev = do
      (_, _, SFPROG sent total) <- sfGet c
      checkProgress (prev, expected) (sent, total) loop

-- checks that progress increases till it reaches total
checkProgress :: MonadIO m => (Int64, Int64) -> (Int64, Int64) -> (Int64 -> m ()) -> m ()
checkProgress (prev, expected) (progress, total) loop
  | total /= expected = error "total /= expected"
  | progress <= prev = error "progress <= prev"
  | progress > total = error "progress > total"
  | progress < total = loop progress
  | otherwise = pure ()

testXFTPAgentSendReceive :: IO ()
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
      rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
      runRight_ $ do
        rfId <- testReceive rcp rfd originalFilePath
        xftpDeleteRcvFile rcp rfId

createRandomFile :: IO FilePath
createRandomFile = do
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  getFileSize filePath `shouldReturn` mb 17
  pure filePath

testSend :: AgentClient -> FilePath -> ExceptT AgentErrorType IO (SndFileId, ValidFileDescription 'FSender, ValidFileDescription 'FRecipient, ValidFileDescription 'FRecipient)
testSend sndr filePath = do
  xftpStartWorkers sndr (Just senderFiles)
  sfId <- xftpSendFile sndr 1 filePath 2
  sfProgress sndr $ mb 18
  ("", sfId', SFDONE sndDescr [rfd1, rfd2]) <- sfGet sndr
  liftIO $ sfId' `shouldBe` sfId
  pure (sfId, sndDescr, rfd1, rfd2)

testReceive :: AgentClient -> ValidFileDescription 'FRecipient -> FilePath -> ExceptT AgentErrorType IO RcvFileId
testReceive rcp rfd originalFilePath = do
  xftpStartWorkers rcp (Just recipientFiles)
  rfId <- xftpReceiveFile rcp 1 rfd
  rfProgress rcp $ mb 18
  ("", rfId', RFDONE path) <- rfGet rcp
  liftIO $ do
    rfId' `shouldBe` rfId
    file <- B.readFile originalFilePath
    B.readFile path `shouldReturn` file
  pure rfId

getFileDescription :: FilePath -> ExceptT AgentErrorType IO (ValidFileDescription 'FRecipient)
getFileDescription path =
  ExceptT $ first (INTERNAL . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile path

logCfgNoLogs :: LogConfig
logCfgNoLogs = LogConfig {lc_file = Nothing, lc_stderr = False}

testXFTPAgentReceiveRestore :: IO ()
testXFTPAgentReceiveRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      (_, _, rfd, _) <- testSend sndr filePath
      pure rfd

  -- receive file - should not succeed with server down
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
  rfId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure rfId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file - should start downloading with server up
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    ("", rfId', RFPROG _ _) <- rfGet rcp'
    liftIO $ rfId' `shouldBe` rfId
    disconnectAgentClient rcp'

  threadDelay 100000

  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file - should continue downloading with server up
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    rfProgress rcp' $ mb 18
    ("", rfId', RFDONE path) <- rfGet rcp'
    liftIO $ do
      rfId' `shouldBe` rfId
      file <- B.readFile filePath
      B.readFile path `shouldReturn` file

  -- tmp path should be removed after receiving file
  doesDirectoryExist tmpPath `shouldReturn` False

testXFTPAgentReceiveCleanup :: IO ()
testXFTPAgentReceiveCleanup = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      (_, _, rfd, _) <- testSend sndr filePath
      pure rfd

  -- receive file - should not succeed with server down
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
  rfId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure rfId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerThreadOn $ \_ -> do
    -- receive file - should fail with AUTH error
    rcp' <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp'
    rfId' `shouldBe` rfId

  -- tmp path should be removed after permanent error
  doesDirectoryExist tmpPath `shouldReturn` False

testXFTPAgentSendRestore :: IO ()
testXFTPAgentSendRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  -- send file - should not succeed with server down
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  liftIO $ print 2
  sfId <- runRight $ do
    xftpStartWorkers sndr (Just senderFiles)
    liftIO $ print 3
    sfId <- xftpSendFile sndr 1 filePath 2
    liftIO $ print 4
    liftIO $ timeout 1000000 (get sndr) `shouldReturn` Nothing -- wait for worker to encrypt and attempt to create file
    pure sfId
  liftIO $ print 5
  disconnectAgentClient sndr

  liftIO $ print 6
  dirEntries <- listDirectory senderFiles
  liftIO $ print 7
  let prefixDir = fromJust $ find (isSuffixOf "_snd.xftp") dirEntries
      prefixPath = senderFiles </> prefixDir
      encPath = prefixPath </> "xftp.encrypted"
  doesDirectoryExist prefixPath `shouldReturn` True
  doesFileExist encPath `shouldReturn` True

  liftIO $ print 8
  withXFTPServerStoreLogOn $ \_ -> do
    -- send file - should start uploading with server up
    liftIO $ print 9
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 10
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)
    liftIO $ print 11
    ("", sfId', SFPROG _ _) <- sfGet sndr'
    liftIO $ print 12
    liftIO $ sfId' `shouldBe` sfId
    liftIO $ print 13
    disconnectAgentClient sndr'

  threadDelay 100000

  liftIO $ print 14
  withXFTPServerStoreLogOn $ \_ -> do
    -- send file - should continue uploading with server up
    liftIO $ print 15
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 16
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)
    liftIO $ print 17
    sfProgress sndr' $ mb 18
    liftIO $ print 18
    ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr'
    liftIO $ print 19
    liftIO $ sfId' `shouldBe` sfId

    -- prefix path should be removed after sending file
    doesDirectoryExist prefixPath `shouldReturn` False
    doesFileExist encPath `shouldReturn` False

    -- receive file
    liftIO $ print 20
    rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 21
    runRight_ $
      void $ testReceive rcp rfd1 filePath

testXFTPAgentSendCleanup :: IO ()
testXFTPAgentSendCleanup = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  sfId <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    sfId <- runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      sfId <- xftpSendFile sndr 1 filePath 2
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

testXFTPAgentDelete :: IO ()
testXFTPAgentDelete = withGlobalLogging logCfgNoLogs $ do
  withXFTPServer $ do
    filePath <- createRandomFile

    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 4
    (sfId, sndDescr, rfd1, rfd2) <- runRight $ testSend sndr filePath

    -- receive file
    liftIO $ print 5
    rcp1 <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 6
    runRight_ $
      void $ testReceive rcp1 rfd1 filePath

    length <$> listDirectory xftpServerFiles `shouldReturn` 6

    -- delete file
    liftIO $ print 7
    runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      liftIO $ print 8
      xftpDeleteSndFileRemote sndr 1 sfId sndDescr
      liftIO $ print 9
      Nothing <- liftIO $ 100000 `timeout` sfGet sndr
      pure ()

    threadDelay 1000000
    length <$> listDirectory xftpServerFiles `shouldReturn` 0

    -- receive file - should fail with AUTH error
    liftIO $ print 10
    rcp2 <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 11
    runRight $ do
      xftpStartWorkers rcp2 (Just recipientFiles)
      liftIO $ print 12
      rfId <- xftpReceiveFile rcp2 1 rfd2
      liftIO $ print 13
      ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp2
      liftIO $ print 14
      liftIO $ rfId' `shouldBe` rfId

testXFTPAgentDeleteRestore :: IO ()
testXFTPAgentDeleteRestore = withGlobalLogging logCfgNoLogs $ do
  filePath <- createRandomFile

  (sfId, sndDescr, rfd2) <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 3
    (sfId, sndDescr, rfd1, rfd2) <- runRight $ testSend sndr filePath

    -- receive file
    liftIO $ print 4
    rcp1 <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 5
    runRight_ $
      void $ testReceive rcp1 rfd1 filePath

    pure (sfId, sndDescr, rfd2)

  -- delete file - should not succeed with server down
  liftIO $ print 6
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight $ do
    liftIO $ print 7
    xftpStartWorkers sndr (Just senderFiles)
    liftIO $ print 8
    xftpDeleteSndFileRemote sndr 1 sfId sndDescr
    liftIO $ print 9
    liftIO $ timeout 300000 (get sndr) `shouldReturn` Nothing -- wait for worker attempt
  liftIO $ print 10
  disconnectAgentClient sndr

  threadDelay 300000
  length <$> listDirectory xftpServerFiles `shouldReturn` 6

  liftIO $ print 11
  withXFTPServerStoreLogOn $ \_ -> do
    -- delete file - should succeed with server up
    liftIO $ print 12
    sndr' <- getSMPAgentClient' agentCfg initAgentServers testDB
    liftIO $ print 13
    runRight_ $ xftpStartWorkers sndr' (Just senderFiles)

    threadDelay 1000000
    length <$> listDirectory xftpServerFiles `shouldReturn` 0

    -- receive file - should fail with AUTH error
    liftIO $ print 14
    rcp2 <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      liftIO $ print 15
      xftpStartWorkers rcp2 (Just recipientFiles)
      liftIO $ print 16
      rfId <- xftpReceiveFile rcp2 1 rfd2
      liftIO $ print 17
      ("", rfId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp2
      liftIO $ rfId' `shouldBe` rfId

testXFTPAgentRequestAdditionalRecipientIDs :: IO ()
testXFTPAgentRequestAdditionalRecipientIDs = withXFTPServer $ do
  filePath <- createRandomFile

  -- send file
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  liftIO $ print 3
  rfds <- runRight $ do
    liftIO $ print 4
    xftpStartWorkers sndr (Just senderFiles)
    liftIO $ print 5
    sfId <- xftpSendFile sndr 1 filePath 500
    liftIO $ print 6
    sfProgress sndr $ mb 18
    liftIO $ print 7
    ("", sfId', SFDONE _sndDescr rfds) <- sfGet sndr
    liftIO $ print 8
    liftIO $ do
      sfId' `shouldBe` sfId
      length rfds `shouldBe` 500
    liftIO $ print 9
    pure rfds

  -- receive file using different descriptions
  -- ! revise number of recipients and indexes if xftpMaxRecipientsPerRequest is changed
  liftIO $ print 10
  testReceive' (head rfds) filePath
  liftIO $ print 11
  testReceive' (rfds !! 99) filePath
  liftIO $ print 12
  testReceive' (rfds !! 299) filePath
  liftIO $ print 13
  testReceive' (rfds !! 499) filePath
  where
    testReceive' rfd originalFilePath = do
      rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
      runRight_ $
        void $ testReceive rcp rfd originalFilePath

testXFTPServerTest :: Maybe BasicAuth -> XFTPServerWithAuth -> IO (Maybe ProtocolTestFailure)
testXFTPServerTest newFileBasicAuth srv =
  withXFTPServerCfg testXFTPServerConfig {newFileBasicAuth, xftpPort = xftpTestPort2} $ \_ -> do
    a <- getSMPAgentClient' agentCfg initAgentServers testDB -- initially passed server is not running
    runRight $ testProtocolServer a 1 srv
