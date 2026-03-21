{-# LANGUAGE OverloadedStrings #-}

-- | Per-function tests for the smp-web TypeScript SMP client library.
-- Each test calls the Haskell function and the corresponding TypeScript function
-- via node, then asserts byte-identical output.
--
-- Prerequisites: cd smp-web && npm install && npm run build
-- Run: cabal test --test-option=--match="/SMP Web Client/"
module SMPWebTests (smpWebTests) where

import qualified Data.ByteString as B
import Data.Word (Word16)
import Simplex.Messaging.Encoding
import Test.Hspec hiding (it)
import Util
import XFTPWebTests (callNode_, jsOut, jsUint8)

smpWebDir :: FilePath
smpWebDir = "smp-web"

callNode :: String -> IO B.ByteString
callNode = callNode_ smpWebDir

impEnc :: String
impEnc = "import { encodeBytes, encodeWord16 } from '@simplex-chat/xftp-web/dist/protocol/encoding.js';"

smpWebTests :: SpecWith ()
smpWebTests = describe "SMP Web Client" $ do
  describe "xftp-web imports" $ do
    it "encodeBytes via xftp-web" $ do
      let val = "hello" :: B.ByteString
      actual <- callNode $ impEnc <> jsOut ("encodeBytes(" <> jsUint8 val <> ")")
      actual `shouldBe` smpEncode val
    it "encodeWord16 via xftp-web" $ do
      let val = 12345 :: Word16
      actual <- callNode $ impEnc <> jsOut ("encodeWord16(" <> show val <> ")")
      actual `shouldBe` smpEncode val
