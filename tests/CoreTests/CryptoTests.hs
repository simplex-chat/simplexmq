{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Redundant if" #-}
module CoreTests.CryptoTests (cryptoTests) where

import qualified Simplex.Messaging.Crypto as C
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as B
import Data.Text.Encoding (encodeUtf8, decodeUtf8)

cryptoTests :: Spec
cryptoTests = modifyMaxSuccess (const 10000) $ do
  describe "padding / unpadding" $ do
    it "should pad / unpad string" . property $ \(s, paddedLen) ->
      let b = encodeUtf8 $ T.pack s
          padded = C.pad b paddedLen
       in if paddedLen >= B.length b + 2
            then if B.length b < 2 ^ (16 :: Int) - 3
              then (fmap (T.unpack . decodeUtf8) . C.unPad =<< padded) == Right s
              else padded == Left C.CryptoInvalidMsgError
            else True
    it "pad should fail on large string" $ do
      C.pad "abc" 5 `shouldBe` Right "\000\003abc"
      C.pad "abc" 4 `shouldBe` Left C.CryptoLargeMsgError
    it "unpad should fail on invalid string" $ do
      C.unPad "\000\000" `shouldBe` Right ""
      C.unPad "\000" `shouldBe` Left C.CrypteInvalidMsgError
      C.unPad "" `shouldBe` Left C.CrypteInvalidMsgError
    it "unpad should fail on shorter string" $ do
      C.unPad "\000\003abc" `shouldBe` Right "abc"
      C.unPad "\000\003ab" `shouldBe` Left C.CrypteInvalidMsgError
