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
import Data.Int (Int64)
import SMPAgentClient (agentCfg, initAgentServers)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.Messaging.Agent (AgentClient, disconnectAgentClient, getSMPAgentClient, xftpDeleteRcvFile, xftpReceiveFile, xftpSendFile, xftpStartWorkers)
import Simplex.Messaging.Agent.Protocol (ACommand (..), AgentErrorType (..))
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import System.Directory (doesDirectoryExist, getFileSize, listDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec
import XFTPCLI
import XFTPClient

xftpAgentTests :: Spec
xftpAgentTests = around_ testBracket . describe "Functional API" $ do
  it "should receive file" testXFTPAgentReceive
  it "should resume receiving file after restart" testXFTPAgentReceiveRestore
  it "should cleanup tmp path after permanent error" testXFTPAgentReceiveCleanup
  it "should send file using experimental api" testXFTPAgentSendExperimental

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
  runRight_ $ do
    xftpStartWorkers rcp (Just recipientFiles)
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd
    rfProgress rcp $ mb 18
    ("", fId', RFDONE path) <- rfGet rcp
    liftIO $ do
      fId' `shouldBe` fId
      B.readFile path `shouldReturn` file

    -- delete file
    xftpDeleteRcvFile rcp 1 fId

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
  rcp <- getSMPAgentClient agentCfg initAgentServers
  fId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure fId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerStoreLogOn $ \_ -> do
    -- receive file using agent - should succeed with server up
    rcp' <- getSMPAgentClient agentCfg initAgentServers
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    rfProgress rcp' $ mb 18
    ("", fId', RFDONE path) <- rfGet rcp'
    liftIO $ do
      fId' `shouldBe` fId
      file <- B.readFile filePath
      B.readFile path `shouldReturn` file

  -- tmp path should be removed after receiving file
  doesDirectoryExist tmpPath `shouldReturn` False

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
  fId <- runRight $ do
    xftpStartWorkers rcp (Just recipientFiles)
    fd :: ValidFileDescription 'FRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd
    liftIO $ timeout 300000 (get rcp) `shouldReturn` Nothing -- wait for worker attempt
    pure fId
  disconnectAgentClient rcp

  [prefixDir] <- listDirectory recipientFiles
  let tmpPath = recipientFiles </> prefixDir </> "xftp.encrypted"
  doesDirectoryExist tmpPath `shouldReturn` True

  withXFTPServerThreadOn $ \_ -> do
    -- receive file using agent - should fail with AUTH error
    rcp' <- getSMPAgentClient agentCfg initAgentServers
    runRight_ $ xftpStartWorkers rcp' (Just recipientFiles)
    ("", fId', RFERR (INTERNAL "XFTP {xftpErr = AUTH}")) <- rfGet rcp'
    fId' `shouldBe` fId

  -- tmp path should be removed after permanent error
  doesDirectoryExist tmpPath `shouldReturn` False

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
    xftpStartWorkers sndr (Just senderFiles)
    sfId <- xftpSendFile sndr 1 filePath 2
    sfProgress sndr $ mb 18
    ("", sfId', SFDONE _sndDescr [rfd1, _rfd2]) <- sfGet sndr
    liftIO $ sfId' `shouldBe` sfId
    pure rfd1

  -- receive file using agent
  rcp <- getSMPAgentClient agentCfg initAgentServers
  runRight_ $ do
    xftpStartWorkers rcp (Just recipientFiles)
    rfId <- xftpReceiveFile rcp 1 rfd
    rfProgress rcp $ mb 18
    ("", rfId', RFDONE path) <- rfGet rcp
    liftIO $ do
      rfId' `shouldBe` rfId
      B.readFile path `shouldReturn` file
