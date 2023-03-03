module XFTPCLI where

import Control.Exception (bracket_)
import qualified Data.ByteString as LB
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Simplex.FileTransfer.Client.Main (prepareChunkSizes, xftpClientCLI)
import Simplex.FileTransfer.Description (kb, mb)
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
  it "prepareChunkSizes should use 2 chunk sizes" testPrepareChunkSizes

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

xftpCLI :: [String] -> IO [String]
xftpCLI params = lines <$> capture_ (withArgs params xftpClientCLI)

testXFTPCLISendReceive :: IO ()
testXFTPCLISendReceive = withXFTPServer $ do
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` mb 17
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Sender file description: " <> fdSnd,
                 "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2
               ]
  testInfoFile fdRcv1 "Recipient"
  testReceiveFile fdRcv1 "testfile" file
  testInfoFile fdRcv2 "Recipient"
  testReceiveFile fdRcv2 "testfile_1" file
  testInfoFile fdSnd "Sender"
  xftpCLI ["recv", fdSnd, recipientFiles, "--tmp=tests/tmp"]
    `shouldThrow` anyException
  where
    testInfoFile fd party = do
      xftpCLI ["info", fd]
        `shouldReturn` [party <> " file description", "File download size: 18mb", "File server(s):", testXFTPServerStr <> ": 18mb"]
    testReceiveFile fd fileName file = do
      progress : recvResult <- xftpCLI ["recv", fd, recipientFiles, "--tmp=tests/tmp", "-y"]
      progress `shouldSatisfy` downloadProgress fileName
      recvResult `shouldBe` ["File description " <> fd <> " is deleted."]
      LB.readFile (recipientFiles </> fileName) `shouldReturn` file

testXFTPCLISendReceive2servers :: IO ()
testXFTPCLISendReceive2servers = withXFTPServer . withXFTPServer2 $ do
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` mb 17
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr <> ";" <> testXFTPServerStr2, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Sender file description: " <> fdSnd,
                 "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2
               ]
  testReceiveFile fdRcv1 "testfile" file
  testReceiveFile fdRcv2 "testfile_1" file
  where
    testReceiveFile fd fileName file = do
      partyStr : sizeStr : srvStr : srvs <- xftpCLI ["info", fd]
      partyStr `shouldContain` "Recipient file description"
      sizeStr `shouldBe` "File download size: 18mb"
      srvStr `shouldBe` "File server(s):"
      case srvs of
        [srv1] -> any (`isInfixOf` srv1) [testXFTPServerStr, testXFTPServerStr2] `shouldBe` True
        [srv1, srv2] -> do
          srv1 `shouldContain` testXFTPServerStr
          srv2 `shouldContain` testXFTPServerStr2
        _ -> print srvs >> error "more than 2 servers returned"
      progress : recvResult <- xftpCLI ["recv", fd, recipientFiles, "--tmp=tests/tmp", "-y"]
      progress `shouldSatisfy` downloadProgress fileName
      recvResult `shouldBe` ["File description " <> fd <> " is deleted."]
      LB.readFile (recipientFiles </> fileName) `shouldReturn` file

testXFTPCLIDelete :: IO ()
testXFTPCLIDelete = withXFTPServer . withXFTPServer2 $ do
  let filePath = senderFiles </> "testfile"
  xftpCLI ["rand", filePath, "17mb"] `shouldReturn` ["File created: " <> filePath]
  file <- LB.readFile filePath
  getFileSize filePath `shouldReturn` mb 17
  let fdRcv1 = filePath <> ".xftp" </> "rcv1.xftp"
      fdRcv2 = filePath <> ".xftp" </> "rcv2.xftp"
      fdSnd = filePath <> ".xftp" </> "snd.xftp.private"
  progress : sendResult <- xftpCLI ["send", filePath, senderFiles, "-n", "2", "-s", testXFTPServerStr <> ";" <> testXFTPServerStr2, "--tmp=tests/tmp"]
  progress `shouldSatisfy` uploadProgress
  sendResult
    `shouldBe` [ "Sender file description: " <> fdSnd,
                 "Pass file descriptions to the recipient(s):",
                 fdRcv1,
                 fdRcv2
               ]
  xftpCLI ["del", fdRcv1]
    `shouldThrow` anyException
  progress1 : recvResult <- xftpCLI ["recv", fdRcv1, recipientFiles, "--tmp=tests/tmp", "-y"]
  progress1 `shouldSatisfy` downloadProgress "testfile"
  recvResult `shouldBe` ["File description " <> fdRcv1 <> " is deleted."]
  LB.readFile (recipientFiles </> "testfile") `shouldReturn` file
  fs1 <- listDirectory xftpServerFiles
  fs2 <- listDirectory xftpServerFiles2
  length fs1 + length fs2 `shouldBe` 6
  xftpCLI ["del", fdSnd, "-y"]
    `shouldReturn` ["File deleted!            \r", "File description " <> fdSnd <> " is deleted."]
  listDirectory xftpServerFiles >>= (`shouldBe` [])
  listDirectory xftpServerFiles2 >>= (`shouldBe` [])
  xftpCLI ["recv", fdRcv2, recipientFiles, "--tmp=tests/tmp"]
    `shouldThrow` anyException

testPrepareChunkSizes :: IO ()
testPrepareChunkSizes = do
  prepareChunkSizes (mb 9 + kb 256) `shouldBe` [mb 4, mb 4, mb 1, mb 1]
  prepareChunkSizes (mb 9) `shouldBe` [mb 4, mb 4, mb 1]
  prepareChunkSizes (mb 7 + 1) `shouldBe` [mb 4, mb 4]
  prepareChunkSizes (mb 7) `shouldBe` [mb 4] <> r3 (mb 1)
  prepareChunkSizes (mb 3 + 1) `shouldBe` [mb 4]
  prepareChunkSizes (mb 3) `shouldBe` r3 (mb 1)
  prepareChunkSizes (mb 2 + 3 * kb 256 + 1) `shouldBe` r3 (mb 1)
  prepareChunkSizes (mb 2 + 3 * kb 256) `shouldBe` [mb 1, mb 1] <> r3 (kb 256)
  prepareChunkSizes (mb 2 + 1) `shouldBe` [mb 1, mb 1, kb 256]
  prepareChunkSizes (3 * kb 256 + 1) `shouldBe` [mb 1]
  prepareChunkSizes (3 * kb 256) `shouldBe` r3 (kb 256)
  prepareChunkSizes 1 `shouldBe` [kb 256]
  where
    r3 = replicate 3

uploadProgress :: String -> Bool
uploadProgress s =
  "Encrypting file..." `isPrefixOf` s
    && "Uploading file..." `isInfixOf` s
    && "File uploaded!" `isInfixOf` s

downloadProgress :: FilePath -> String -> Bool
downloadProgress fileName s =
  "Downloading file..." `isPrefixOf` s
    && "Decrypting file..." `isInfixOf` s
    && ("File downloaded: " <> recipientFiles </> fileName <> "\r") `isSuffixOf` s
