{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.CryptoTests (cryptoTests) where

import qualified Data.ByteString.Char8 as B
import Data.Either (isRight)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Simplex.Messaging.Crypto as C
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

cryptoTests :: Spec
cryptoTests = do
  modifyMaxSuccess (const 10000) . describe "padding / unpadding" $ do
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
  describe "Ed signatures" $ do
    describe "Ed25519" $ testSignature C.SEd25519
    describe "Ed448" $ testSignature C.SEd448
  describe "DH X25519 + cryptobox" $
    testDHCryptoBox
  describe "X509 key encoding" $ do
    describe "Ed25519" $ testEncoding C.SEd25519
    describe "Ed448" $ testEncoding C.SEd448
    describe "X25519" $ testEncoding C.SX25519
    describe "X448" $ testEncoding C.SX448

testSignature :: (C.AlgorithmI a, C.SignatureAlgorithm a) => C.SAlgorithm a -> Spec
testSignature alg = it "should sign / verify string" . ioProperty $ do
  (k, pk) <- C.generateSignatureKeyPair alg
  pure $ \s -> let b = encodeUtf8 $ T.pack s in C.verify k (C.sign pk b) b

testDHCryptoBox :: Spec
testDHCryptoBox = it "should encrypt / decrypt string" . ioProperty $ do
  (sk, spk) <- C.generateKeyPair'
  (rk, rpk) <- C.generateKeyPair'
  nonce <- C.randomCbNonce
  pure $ \(s, pad) ->
    let b = encodeUtf8 $ T.pack s
        paddedLen = B.length b + abs pad + 2
        cipher = C.cbEncrypt (C.dh' rk spk) nonce b paddedLen
        plain = C.cbDecrypt (C.dh' sk rpk) nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testEncoding :: (C.AlgorithmI a) => C.SAlgorithm a -> Spec
testEncoding alg = it "should encode / decode key" . ioProperty $ do
  (k, pk) <- C.generateKeyPair alg
  pure $ \(_ :: Int) ->
    C.decodePubKey (C.encodePubKey k) == Right k
      && C.decodePrivKey (C.encodePrivKey pk) == Right pk
