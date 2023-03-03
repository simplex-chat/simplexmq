{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPAgent where

import AgentTests.FunctionalAPITests (get, runRight_)
import Control.Monad.Except
import Data.Bifunctor (first)
import qualified Data.ByteString as LB
import SMPAgentClient (agentCfg, initAgentServers)
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileParty (..), checkParty)
import Simplex.Messaging.Agent (getSMPAgentClient, xftpReceiveFile)
import Simplex.Messaging.Agent.Protocol (ACommand (FRCVD), AgentErrorType (..))
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import System.Directory (getFileSize)
import System.FilePath ((</>))
import Test.Hspec
import XFTPCLI
import XFTPClient

xftpAgentTests :: Spec
xftpAgentTests = around_ testBracket . describe "Functional API" $ do
  it "should receive file" testXFTPAgentReceive

testXFTPAgentReceive :: IO ()
testXFTPAgentReceive = withXFTPServer $ do
  -- send file using CLI
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
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
    fd :: ValidFileDescription 'FPRecipient <- getFileDescription fdRcv
    fId <- xftpReceiveFile rcp 1 fd recipientFiles
    ("", "", FRCVD fId' path) <- get rcp
    liftIO $ do
      fId' `shouldBe` fId
      LB.readFile path `shouldReturn` file
  where
    getFileDescription :: FilePath -> ExceptT AgentErrorType IO (ValidFileDescription 'FPRecipient)
    getFileDescription path = do
      fd :: AFileDescription <- ExceptT $ first (INTERNAL . ("Failed to parse file description: " <>)) . strDecode <$> LB.readFile path
      vfd <- liftEither . first INTERNAL $ validateFileDescription fd
      case vfd of
        AVFD fd' -> either (throwError . INTERNAL) pure $ checkParty fd'
