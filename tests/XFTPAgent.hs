{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPAgent where

import AgentTests.FunctionalAPITests (get, getSMPAgentClient', rfGet, runRight, runRight_, sfGet)
import Control.Logger.Simple
import Control.Monad.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import SMPAgentClient (agentCfg, initAgentServers, testDB)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), XFTPErrorType (AUTH))
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Agent (AgentClient, disconnectAgentClient, testProtocolServer, xftpDeleteRcvFile, xftpReceiveFile, xftpSendFile, xftpStartWorkers)
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..))
import Simplex.Messaging.Agent.Protocol (ACommand (..), AgentErrorType (..), BrokerErrorType (..), noAuthSrv)
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (BasicAuth, ProtoServerWithAuth (..), ProtocolServer (..), XFTPServerWithAuth)
import System.Directory (doesDirectoryExist, getFileSize, listDirectory)
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
  -- create random file using cli
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  getFileSize filePath `shouldReturn` mb 17

  -- send file
  sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
  rfd <- runRight $ do
    xftpStartWorkers sndr (Just senderFiles)
    sfId <- xftpSendFile sndr 1 filePath 2
    sfProgress sndr $ mb 18
    ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr
    liftIO $ sfId' `shouldBe` sfId
    pure rfd1

  -- receive file
  rcp <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight_ $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd
    rfProgress rcp $ mb 18
    ("", rfId', RFDONE path) <- rfGet rcp
    liftIO $ do
      rfId' `shouldBe` rfId
      file <- B.readFile filePath
      B.readFile path `shouldReturn` file

    -- delete file
    xftpDeleteRcvFile rcp 1 rfId

getFileDescription :: FilePath -> ExceptT AgentErrorType IO (ValidFileDescription 'FRecipient)
getFileDescription path =
  ExceptT $ first (INTERNAL . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile path

logCfgNoLogs :: LogConfig
logCfgNoLogs = LogConfig {lc_file = Nothing, lc_stderr = False}

testXFTPAgentReceiveRestore :: IO ()
testXFTPAgentReceiveRestore = withGlobalLogging logCfgNoLogs $ do
  -- create random file using cli
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  getFileSize filePath `shouldReturn` mb 17

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      sfId <- xftpSendFile sndr 1 filePath 2
      sfProgress sndr $ mb 18
      ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr
      liftIO $ sfId' `shouldBe` sfId
      pure rfd1

  -- receive file - should not succeed due to server being down
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
    -- receive file - should succeed with server up
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
  -- create random file using cli
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  getFileSize filePath `shouldReturn` mb 17

  rfd <- withXFTPServerStoreLogOn $ \_ -> do
    -- send file
    sndr <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight $ do
      xftpStartWorkers sndr (Just senderFiles)
      sfId <- xftpSendFile sndr 1 filePath 2
      sfProgress sndr $ mb 18
      ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr
      liftIO $ sfId' `shouldBe` sfId
      pure rfd1

  -- receive file - should not succeed due to server being down
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

testXFTPServerTest :: Maybe BasicAuth -> XFTPServerWithAuth -> IO (Maybe ProtocolTestFailure)
testXFTPServerTest newFileBasicAuth srv =
  withXFTPServerCfg testXFTPServerConfig {newFileBasicAuth, xftpPort = xftpTestPort2} $ \_ -> do
    a <- getSMPAgentClient' agentCfg initAgentServers testDB -- initially passed server is not running
    runRight $ testProtocolServer a 1 srv
