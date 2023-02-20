{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module XFTPServerTests where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Protocol (FileInfo (..), XFTPErrorType (..))
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.Messaging.Client (ProtocolClientError (..))
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Protocol (SenderId)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec
import XFTPClient

xftpServerTests :: Spec
xftpServerTests =
  before_ (createDirectoryIfMissing False xftpServerFiles)
    . after_ (removeDirectoryRecursive xftpServerFiles)
    $ do
      describe "XFTP file chunk delivery" $ do
        it "should create, upload and receive file chunk" testFileChunkDelivery
        it "should create, upload and receive file chunk (2 clients)" testFileChunkDelivery2

chSize :: Num n => n
chSize = 256 * 1024

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
  (rDhKey, _rpDhKey) <- liftIO C.generateKeyPair'
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
  downloadXFTPChunk r rpKey rId rDhKey (XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize (digest <> "_wrong"))
    `catchError` (liftIO . (`shouldBe` PCEResponseError DIGEST))
  downloadXFTPChunk r rpKey rId rDhKey $ XFTPRcvChunkSpec "tests/tmp/received_chunk1" chSize digest
  liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
