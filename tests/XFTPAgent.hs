{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPAgent where

import AgentTests.FunctionalAPITests (get, rfGet, runRight, runRight_, sfGet)
import Control.Logger.Simple
import Control.Monad.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient (agentCfg, initAgentServers)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.Messaging.Agent (disconnectAgentClient, getSMPAgentClient, xftpReceiveFile, xftpSendFile)
import Simplex.Messaging.Agent.Protocol (ACommand (..), AgentErrorType (..))
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import System.Directory (doesDirectoryExist, getFileSize)
import System.FilePath ((</>))
import System.Process (readCreateProcess, shell)
import System.Timeout (timeout)
import Test.Hspec
import XFTPCLI
import XFTPClient

xftpAgentTests :: Spec
xftpAgentTests = around_ testBracket . describe "Functional API" $ do
  it "should receive file" testXFTPAgentReceive
  it "should resume receiving file after restart" testXFTPAgentReceiveRestore
  it "should cleanup tmp path after permanent error" testXFTPAgentReceiveCleanup
  it "should send file using experimental api" testXFTPAgentSendExperimental -- TODO uses default servers (remote)

testXFTPAgentReceive :: IO ()
testXFTPAgentReceive = withXFTPServer $ do
  -- send file using CLI
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- B.readFile filePath
  getFileSize filePath `shouldReturn` mb 17
  let fdRcv = filePath <> ".xftp" </> "rcv1.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-s", testXFTPServerStr, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Sender file description: " <> fdSnd,
                 "Pass file descriptions to the recipient(s):",
                 fdRcv
               ]
  -- receive file using agent
  rcp <- getSMPAgentClient agentCfg initAgentServers
  let savePath = recipientFiles </> "testfile"
  run $ "touch " <> savePath
  runRight_ $ do
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd (Just recipientFiles) savePath
    ("", fId', RFDONE) <- rfGet rcp
    liftIO $ do
      fId' `shouldBe` fId
      B.readFile savePath `shouldReturn` file

run :: String -> IO ()
run cmd = void $ readCreateProcess (shell cmd) ""

getFileDescription :: FilePath -> ExceptT AgentErrorType IO (ValidFileDescription 'FRecipient)
getFileDescription path =
  ExceptT $ first (INTERNAL . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile path

logCfgNoLogs :: LogConfig
logCfgNoLogs = LogConfig {lc_file = Nothing, lc_stderr = False}

testXFTPAgentReceiveRestore :: IO ()
testXFTPAgentReceiveRestore = withGlobalLogging logCfgNoLogs $ do
  let filePath = senderFiles </> "testfile"
      fdRcv = filePath <> ".xftp" </> "rcv1.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"

  withXFTPServerStoreLogOn $ \_ -> do
    -- send file using CLI
    xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
    getFileSize filePath `shouldReturn` mb 17
    progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-s", testXFTPServerStr, "--tmp=tests/tmp"]
    progress `shouldSatisfy` uploadProgress
    sendResult
      `shouldBe` [ "Sender file description: " <> fdSnd,
                   "Pass file descriptions to the recipient(s):",
                   fdRcv
                 ]

  -- receive file using agent - should not succeed due to server being down
  let savePath = recipientFiles </> "testfile"
  run $ "touch " <> savePath
  rcp <- getSMPAgentClient agentCfg initAgentServers
  fId <- runRight $ do
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd (Just recipientFiles) savePath
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure fId
  disconnectAgentClient rcp

  doesDirectoryExist (recipientFiles </> "xftp.encrypted") `shouldReturn` True

  rcp' <- getSMPAgentClient agentCfg initAgentServers
  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file using agent - should succeed with server up
    ("", fId', RFDONE) <- rfGet rcp'
    liftIO $ do
      fId' `shouldBe` fId
      file <- B.readFile filePath
      B.readFile savePath `shouldReturn` file

  -- tmp path should be removed after receiving file
  doesDirectoryExist (recipientFiles </> "xftp.encrypted") `shouldReturn` False

testXFTPAgentReceiveCleanup :: IO ()
testXFTPAgentReceiveCleanup = withGlobalLogging logCfgNoLogs $ do
  let filePath = senderFiles </> "testfile"
      fdRcv = filePath <> ".xftp" </> "rcv1.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"

  withXFTPServerStoreLogOn $ \_ -> do
    -- send file using CLI
    xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
    getFileSize filePath `shouldReturn` mb 17
    progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-s", testXFTPServerStr, "--tmp=tests/tmp"]
    progress `shouldSatisfy` uploadProgress
    sendResult
      `shouldBe` [ "Sender file description: " <> fdSnd,
                   "Pass file descriptions to the recipient(s):",
                   fdRcv
                 ]

  -- receive file using agent - should not succeed due to server being down
  rcp <- getSMPAgentClient agentCfg initAgentServers
  let savePath = recipientFiles </> "testfile"
  run $ "touch " <> savePath
  fId <- runRight $ do
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd (Just recipientFiles) savePath
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure fId
  disconnectAgentClient rcp

  doesDirectoryExist (recipientFiles </> "xftp.encrypted") `shouldReturn` True

  -- receive file using agent - should fail with AUTH error
  rcp' <- getSMPAgentClient agentCfg initAgentServers
  withXFTPServerThreadOn $ \_ -> do
    ("", fId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp'
    fId' `shouldBe` fId

  -- tmp path should be removed after permanent error
  doesDirectoryExist (recipientFiles </> "xftp.encrypted") `shouldReturn` False

testXFTPAgentSendExperimental :: IO ()
testXFTPAgentSendExperimental = withXFTPServer $ do
  -- create random file using cli
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- B.readFile filePath
  getFileSize filePath `shouldReturn` mb 17

  -- send file using experimental agent API
  sndr <- getSMPAgentClient agentCfg initAgentServers
  rfd <- runRight $ do
    sfId <- xftpSendFile sndr 1 filePath 2 $ Just senderFiles
    ("", sfId', SFDONE sndDescr rcvDescrs) <- sfGet sndr
    liftIO $ do
      sfId' `shouldBe` sfId
      strDecode <$> B.readFile (senderFiles </> "testfile.descr/testfile.xftp/snd.xftp.private") `shouldReturn` Right sndDescr
      Right rfd1 <- strDecode <$> B.readFile (senderFiles </> "testfile.descr/testfile.xftp/rcv1.xftp")
      Right rfd2 <- strDecode <$> B.readFile (senderFiles </> "testfile.descr/testfile.xftp/rcv2.xftp")
      rcvDescrs `shouldBe` [rfd1, rfd2]
      pure rfd1

  -- receive file using agent
  rcp <- getSMPAgentClient agentCfg initAgentServers
  let savePath = recipientFiles </> "testfile"
  run $ "touch " <> savePath
  runRight_ $ do
    rfId <- xftpReceiveFile rcp 1 rfd (Just recipientFiles) savePath
    ("", rfId', RFDONE) <- rfGet rcp
    liftIO $ do
      rfId' `shouldBe` rfId
      B.readFile savePath `shouldReturn` file
