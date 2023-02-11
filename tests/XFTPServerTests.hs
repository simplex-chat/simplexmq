{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module XFTPServerTests where

import AgentTests.FunctionalAPITests (runRight_)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Protocol (FileInfo (..))
import qualified Simplex.Messaging.Crypto as C
import Test.Hspec
import XFTPClient

xftpServerTests :: Spec
xftpServerTests = do
  describe "XFTP file chunk delivery" testFileChunkDelivery

testFileChunkDelivery :: Spec
testFileChunkDelivery =
  it "should create, upload and receive file chunk" $ do
    (sndKey, spKey) <- C.generateSignatureKeyPair C.SEd25519
    (rcvKey, rpKey) <- C.generateSignatureKeyPair C.SEd25519
    xftpTest $ \c -> runRight_ $ do
      let file = FileInfo {sndKey, size = 2 * 1024 * 1024, digest = "abc="}
      (sId, rIds) <- createXFTPChunk c spKey file [rcvKey]
      pure ()
