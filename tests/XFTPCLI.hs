module XFTPCLI where

import Control.Exception (bracket_)
import qualified Data.ByteString as LB
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Simplex.FileTransfer.Client.Main (xftpClientCLI)
import Simplex.FileTransfer.Description (mb)
import System.Directory (createDirectoryIfMissing, getFileSize, listDirectory, removeDirectoryRecursive)
import System.Environment (withArgs)
import System.FilePath ((</>))
import System.IO.Silently (capture_)
import Test.Hspec
import XFTPClient (testXFTPServerStr, testXFTPServerStr2, withXFTPServer, withXFTPServer2, xftpServerFiles, xftpServerFiles2)

xftpCLITests :: Spec
xftpCLITests = around_ testBracket . describe "XFTP CLI" $ do
  it "should send and receive file" testXFTPCLISendReceive
  it "should send and receive file with 2 servers" testXFTPCLISendReceive2servers
  it "should delete file from 2 servers" testXFTPCLIDelete

testBracket :: IO () -> IO ()
testBracket =
  bracket_
    (mapM_ (createDirectoryIfMissing False) testDirs)
    (mapM_ removeDirectoryRecursive testDirs)
  where
    testDirs = [xftpServerFiles, xftpServerFiles2, senderFiles, recipientFiles]

senderFiles :: FilePath
senderFiles = "tests/tmp/xftp-sender-files"

recipientFiles :: FilePath
recipientFiles = "tests/tmp/xftp-recipient-files"

testXFTPCLISendReceive :: IO ()
testXFTPCLISendReceive = withXFTPServer $ do
  let filePath = senderFiles </> "testfile"
  xftp ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` 17 * mb
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftp ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2,
                 "Sender file description:",
                 fdSnd
               ]
  testInfoFile fdRcv1 "Recipient"
  testReceiveFile fdRcv1 "testfile" file
  testInfoFile fdRcv2 "Recipient"
  testReceiveFile fdRcv2 "testfile_1" file
  testInfoFile fdSnd "Sender"
  xftp ["recv", fdSnd, recipientFiles, "--tmp=tests/tmp"]
    `shouldThrow` anyException
  where
    xftp params = lines <$> capture_ (withArgs params xftpClientCLI)
    testInfoFile fd party = do
      xftp ["info", fd]
        `shouldReturn` [party <> " file description", "File download size: 18mb", "File server(s):", testXFTPServerStr <> ": 18mb"]
    testReceiveFile fd fileName file = do
      progress : recvResult <- xftp ["recv", fd, recipientFiles, "--tmp=tests/tmp"]
      progress `shouldSatisfy` downloadProgress fileName
      recvResult `shouldBe` ["File description can't be used again"]
      LB.readFile (recipientFiles </> fileName) `shouldReturn` file

testXFTPCLISendReceive2servers :: IO ()
testXFTPCLISendReceive2servers = withXFTPServer . withXFTPServer2 $ do
  let filePath = senderFiles </> "testfile"
  xftp ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` 17 * mb
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftp ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr <> ";" <> testXFTPServerStr2, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2,
                 "Sender file description:",
                 fdSnd
               ]
  testReceiveFile fdRcv1 "testfile" file
  testReceiveFile fdRcv2 "testfile_1" file
  where
    xftp params = lines <$> capture_ (withArgs params xftpClientCLI)
    testReceiveFile fd fileName file = do
      partyStr : sizeStr : srvStr : srvs <- xftp ["info", fd]
      partyStr `shouldContain` "Recipient file description"
      sizeStr `shouldBe` "File download size: 18mb"
      srvStr `shouldBe` "File server(s):"
      case srvs of
        [srv1] -> any (`isInfixOf` srv1) [testXFTPServerStr, testXFTPServerStr2] `shouldBe` True
        [srv1, srv2] -> do
          srv1 `shouldContain` testXFTPServerStr
          srv2 `shouldContain` testXFTPServerStr2
        _ -> print srvs >> error "more than 2 servers returned"
      progress : recvResult <- xftp ["recv", fd, recipientFiles, "--tmp=tests/tmp"]
      progress `shouldSatisfy` downloadProgress fileName
      recvResult `shouldBe` ["File description can't be used again"]
      LB.readFile (recipientFiles </> fileName) `shouldReturn` file

testXFTPCLIDelete :: IO ()
testXFTPCLIDelete = withXFTPServer . withXFTPServer2 $ do
  let filePath = senderFiles </> "testfile"
  xftp ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` 17 * mb
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftp ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr <> ";" <> testXFTPServerStr2, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2,
                 "Sender file description:",
                 fdSnd
               ]
  xftp ["del", fdRcv1]
    `shouldThrow` anyException
  progress1 : recvResult <- xftp ["recv", fdRcv1, recipientFiles, "--tmp=tests/tmp"]
  progress1 `shouldSatisfy` downloadProgress "testfile"
  recvResult `shouldBe` ["File description can't be used again"]
  LB.readFile (recipientFiles </> "testfile") `shouldReturn` file
  fs1 <- listDirectory xftpServerFiles
  fs2 <- listDirectory xftpServerFiles2
  length fs1 + length fs2 `shouldBe` 6
  xftp ["del", fdSnd]
    `shouldReturn` ["File deleted"]
  listDirectory xftpServerFiles >>= (`shouldBe` [])
  listDirectory xftpServerFiles2 >>= (`shouldBe` [])
  xftp ["recv", fdRcv2, recipientFiles, "--tmp=tests/tmp"]
    `shouldThrow` anyException
  where
    xftp params = lines <$> capture_ (withArgs params xftpClientCLI)

uploadProgress :: String -> Bool
uploadProgress s = "Uploading file..." `isPrefixOf` s && "File uploaded!" `isInfixOf` s

downloadProgress :: FilePath -> String -> Bool
downloadProgress fileName s =
  "Downloading file..." `isPrefixOf` s && ("File downloaded: " <> recipientFiles </> fileName <> "\r") `isSuffixOf` s
