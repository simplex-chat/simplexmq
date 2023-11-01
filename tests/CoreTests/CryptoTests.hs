{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.CryptoTests (cryptoTests) where

import Control.Concurrent.STM
import Control.Monad.Except
import Crypto.Random (drgNew, getRandomBytes)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (isRight)
import Data.Int (Int64)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LE
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
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
  modifyMaxSuccess (const 10000) . describe "lazy padding / unpadding" $ do
    it "should pad / unpad lazy bytestrings" . property $ \(s, paddedLen) ->
      let b = LE.encodeUtf8 $ LT.pack s
          len = LB.length b
          padded = LC.pad b len paddedLen
       in if len <= paddedLen - 8
            then (padded >>= LC.unPad) == Right b
            else padded == Left C.CryptoLargeMsgError
    it "pad should support large string" $ do
      LC.pad "abc" 3 11 `shouldBe` Right "\000\000\000\000\000\000\000\003abc"
      LC.pad "abc" 3 10 `shouldBe` Left C.CryptoLargeMsgError
      let s = LB.replicate 100000 'a'
      (LC.pad s 100000 100100 >>= LC.unPad) `shouldBe` Right s
      (LC.pad s 100000 100008 >>= LC.unPad) `shouldBe` Right s
      (LC.pad s 100000 100007 >>= LC.unPad) `shouldBe` Left C.CryptoLargeMsgError
    it "pad should truncate string if a shorter length is passed and unpad incorrectly when longer length is passed" $ do
      let s = LB.replicate 10000 'a'
      (LC.pad s 9000 10100 >>= LC.unPad) `shouldBe` Right (LB.take 9000 s)
      (LC.pad s 11000 11100 >>= LC.unPad) `shouldBe` Right (s <> LB.replicate 92 '#') -- 92 = pad size, it is not truncated in this case
    it "unpad should fail on invalid string" $ do
      LC.unPad "\000\000\000\000\000\000\000\000" `shouldBe` Right ""
      LC.unPad "\000\000" `shouldBe` Left C.CryptoInvalidMsgError
      LC.unPad "" `shouldBe` Left C.CryptoInvalidMsgError
    it "unpad won't fail on shorter string" $ do
      LC.unPad "\000\000\000\000\000\000\000\003abc" `shouldBe` Right "abc"
      LC.unPad "\000\000\000\000\000\000\000\003ab" `shouldBe` Right "ab"
    it "should pad / unpad file" testPadUnpadFile
  describe "Ed signatures" $ do
    describe "Ed25519" $ testSignature C.SEd25519
    describe "Ed448" $ testSignature C.SEd448
  describe "DH X25519 + cryptobox" testDHCryptoBox
  describe "secretbox" testSecretBox
  describe "lazy secretbox" $ do
    testLazySecretBox
    testLazySecretBoxFile
    testLazySecretBoxTailTag
    testLazySecretBoxFileTailTag
  describe "AES GCM" $ do
    testAESGCM
  describe "X509 key encoding" $ do
    describe "Ed25519" $ testEncoding C.SEd25519
    describe "Ed448" $ testEncoding C.SEd448
    describe "X25519" $ testEncoding C.SX25519
    describe "X448" $ testEncoding C.SX448
  describe "sntrup761" $
    it "should enc/dec key" testSNTRUP761

testPadUnpadFile :: IO ()
testPadUnpadFile = do
  let f = "tests/tmp/testpad"
      paddedLen = 1024 * 1024
      len = 1000000
      s = LB.replicate len 'a'
  Right s' <- pure $ LC.pad s len paddedLen
  LB.writeFile (f <> ".padded") s'
  Right s'' <- LC.unPad <$> LB.readFile (f <> ".padded")
  s'' `shouldBe` s

testSignature :: (C.AlgorithmI a, C.SignatureAlgorithm a) => C.SAlgorithm a -> Spec
testSignature alg = it "should sign / verify string" . ioProperty $ do
  (k, pk) <- C.generateSignatureKeyPair alg
  pure $ \s -> let b = encodeUtf8 $ T.pack s in C.verify k (C.sign pk b) b

testDHCryptoBox :: Spec
testDHCryptoBox = it "should encrypt / decrypt string with asymmetric DH keys" . ioProperty $ do
  (sk, spk) <- C.generateKeyPair'
  (rk, rpk) <- C.generateKeyPair'
  nonce <- C.randomCbNonce
  pure $ \(s, pad) ->
    let b = encodeUtf8 $ T.pack s
        paddedLen = B.length b + abs pad + 2
        cipher = C.cbEncrypt (C.dh' rk spk) nonce b paddedLen
        plain = C.cbDecrypt (C.dh' sk rpk) nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testSecretBox :: Spec
testSecretBox = it "should encrypt / decrypt string with a random symmetric key" . ioProperty $ do
  k <- C.randomSbKey
  nonce <- C.randomCbNonce
  pure $ \(s, pad) ->
    let b = encodeUtf8 $ T.pack s
        pad' = min (abs pad) 100000
        paddedLen = B.length b + pad' + 2
        cipher = C.sbEncrypt k nonce b paddedLen
        plain = C.sbDecrypt k nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testLazySecretBox :: Spec
testLazySecretBox = it "should lazily encrypt / decrypt string with a random symmetric key" . ioProperty $ do
  k <- C.randomSbKey
  nonce <- C.randomCbNonce
  pure $ \(s, pad) ->
    let b = LE.encodeUtf8 $ LT.pack s
        len = LB.length b
        pad' = min (abs pad) 100000
        paddedLen = len + pad' + 8
        cipher = LC.sbEncrypt k nonce b len paddedLen
        plain = LC.sbDecrypt k nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testLazySecretBoxFile :: Spec
testLazySecretBoxFile = it "should lazily encrypt / decrypt file with a random symmetric key" $ do
  k <- C.randomSbKey
  nonce <- C.randomCbNonce
  let f = "tests/tmp/testsecretbox"
      paddedLen = 4 * 1024 * 1024
      len = 4 * 1000 * 1000 :: Int64
      s = LC.fastReplicate len 'a'
  Right s' <- pure $ LC.sbEncrypt k nonce s len paddedLen
  LB.writeFile (f <> ".encrypted") s'
  Right s'' <- LC.sbDecrypt k nonce <$> LB.readFile (f <> ".encrypted")
  s'' `shouldBe` s

testLazySecretBoxTailTag :: Spec
testLazySecretBoxTailTag = it "should lazily encrypt / decrypt string with a random symmetric key (tail tag)" . ioProperty $ do
  k <- C.randomSbKey
  nonce <- C.randomCbNonce
  pure $ \(s, pad) ->
    let b = LE.encodeUtf8 $ LT.pack s
        len = LB.length b
        pad' = min (abs pad) 100000
        paddedLen = len + pad' + 8
        cipher = LC.sbEncryptTailTag k nonce b len paddedLen
        plain = LC.sbDecryptTailTag k nonce paddedLen =<< cipher
     in isRight cipher && cipher /= (snd <$> plain) && Right (True, b) == plain

testLazySecretBoxFileTailTag :: Spec
testLazySecretBoxFileTailTag = it "should lazily encrypt / decrypt file with a random symmetric key (tail tag)" $ do
  k <- C.randomSbKey
  nonce <- C.randomCbNonce
  let f = "tests/tmp/testsecretbox"
      paddedLen = 4 * 1024 * 1024
      len = 4 * 1000 * 1000 :: Int64
      s = LC.fastReplicate len 'a'
  Right s' <- pure $ LC.sbEncryptTailTag k nonce s len paddedLen
  LB.writeFile (f <> ".encrypted") s'
  Right (auth, s'') <- LC.sbDecryptTailTag k nonce paddedLen <$> LB.readFile (f <> ".encrypted")
  s'' `shouldBe` s
  auth `shouldBe` True

testAESGCM :: Spec
testAESGCM = it "should encrypt / decrypt string with a random symmetric key" $ do
  k <- C.randomAesKey
  iv <- C.randomGCMIV
  s <- getRandomBytes 100
  Right (tag, cipher) <- runExceptT $ C.encryptAESNoPad k iv s
  Right plain <- runExceptT $ C.decryptAESNoPad k iv cipher tag
  cipher `shouldNotBe` plain
  s `shouldBe` plain

testEncoding :: C.AlgorithmI a => C.SAlgorithm a -> Spec
testEncoding alg = it "should encode / decode key" . ioProperty $ do
  (k, pk) <- C.generateKeyPair alg
  pure $ \(_ :: Int) ->
    C.decodePubKey (C.encodePubKey k) == Right k
      && C.decodePrivKey (C.encodePrivKey pk) == Right pk

testSNTRUP761 :: IO ()
testSNTRUP761 = do
  drg <- newTVarIO =<< drgNew
  (pk, sk) <- sntrup761Keypair drg
  (c, KEMSharedKey k) <- sntrup761Enc drg pk
  KEMSharedKey k' <- sntrup761Dec c sk
  k' `shouldBe` k
