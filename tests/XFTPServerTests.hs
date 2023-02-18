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
      describe "XFTP file chunk delivery" testFileChunkDelivery

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

testFileChunkDelivery :: Spec
testFileChunkDelivery =
  it "should create, upload and receive file chunk" $ do
    (sndKey, spKey) <- C.generateSignatureKeyPair C.SEd25519
    (rcvKey, rpKey) <- C.generateSignatureKeyPair C.SEd25519
    (rDhKey, _rpDhKey) <- C.generateKeyPair'
    bytes <- createTestChunk testChunkPath
    xftpTest $ \c -> runRight_ $ do
      digest <- liftIO $ LC.sha512Hash <$> LB.readFile testChunkPath
      let file = FileInfo {sndKey, size = chSize, digest}
          chunkSpec = XFTPChunkSpec {filePath = testChunkPath, chunkOffset = 0, chunkSize = chSize}
      (sId, [rId]) <- createXFTPChunk c spKey file [rcvKey]
      uploadXFTPChunk c spKey sId chunkSpec
      (sId', _) <- createXFTPChunk c spKey file {digest = digest <> "_wrong"} [rcvKey]
      uploadXFTPChunk c spKey sId' chunkSpec
        `catchError` (liftIO . (`shouldBe` PCEProtocolError DIGEST))
      liftIO $ readChunk sId `shouldReturn` bytes
      (_sDhKey, chunkBody) <- downloadXFTPChunk c rpKey rId rDhKey
      receiveXFTPChunk chunkBody "tests/tmp/received_chunk1" chSize (digest <> "_wrong")
        `catchError` (liftIO . (`shouldBe` PCEResponseError DIGEST))
      (_sDhKey, chunkBody') <- downloadXFTPChunk c rpKey rId rDhKey
      receiveXFTPChunk chunkBody' "tests/tmp/received_chunk1" chSize digest
      liftIO $ B.readFile "tests/tmp/received_chunk1" `shouldReturn` bytes
      pure ()
