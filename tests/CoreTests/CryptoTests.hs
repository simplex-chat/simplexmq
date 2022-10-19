{-# LANGUAGE OverloadedStrings #-}

module CoreTests.CryptoTests (cryptoTests) where

import qualified Simplex.Messaging.Crypto as C
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding (encodeUtf8)

cryptoTests :: Spec
cryptoTests = modifyMaxSuccess (const 10000) $ do
  describe "padding / unpadding" $ do
    it "should pad / unpad string" . property $ \(s, paddedLen) ->
      let b = encodeUtf8 $ T.pack s
          len = B.length b
          padded = C.pad b paddedLen
       in if len < 2 ^ (16 :: Int) - 3 && len <= paddedLen - 2
            then (padded >>= C.unPad) == Right b
            else padded == Left C.CryptoLargeMsgError
    it "pad should fail on large string" $ do
      C.pad "abc" 5 `shouldBe` Right "\000\003abc"
      C.pad "abc" 4 `shouldBe` Left C.CryptoLargeMsgError
      let s = B.replicate 65533 'a'
      (C.pad s 65535 >>= C.unPad) `shouldBe` Right s
      C.pad (B.replicate 65534 'a') 65536 `shouldBe` Left C.CryptoLargeMsgError
      C.pad (B.replicate 65535 'a') 65537 `shouldBe` Left C.CryptoLargeMsgError
    it "unpad should fail on invalid string" $ do
      C.unPad "\000\000" `shouldBe` Right ""
      C.unPad "\000" `shouldBe` Left C.CryptoInvalidMsgError
      C.unPad "" `shouldBe` Left C.CryptoInvalidMsgError
    it "unpad should fail on shorter string" $ do
      C.unPad "\000\003abc" `shouldBe` Right "abc"
      C.unPad "\000\003ab" `shouldBe` Left C.CryptoInvalidMsgError
