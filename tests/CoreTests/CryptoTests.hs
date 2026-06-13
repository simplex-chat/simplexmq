{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.CryptoTests (cryptoTests) where

import Control.Concurrent.STM
import Control.Monad.Except
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (isRight)
import Data.Int (Int64)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LE
import Data.Type.Equality
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import qualified SMPClient
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Crypto.BBS
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Transport.Client
import Test.Hspec hiding (fit, it)
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck
import Util

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
  describe "X509 chains" $ do
    it "should validate certificates" testValidateX509
  describe "sntrup761" $
    it "should enc/dec key" testSNTRUP761
  describe "BBS+" $ do
    it "should sign and verify" testBBSSignVerify
    it "should derive public key from secret key" testBBSPublicKeyDerivation
    it "should generate and verify proof" testBBSProofRoundtrip
    it "should reject tampered proof" testBBSTamperedProof
    it "should reject wrong disclosed message" testBBSWrongMessage
    it "should reject wrong public key" testBBSWrongKey
    it "should produce unlinkable proofs" testBBSUnlinkable
    it "should produce proof of expected size" testBBSProofSize

instance Eq C.APublicKey where
  C.APublicKey a k == C.APublicKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

instance Eq C.APrivateKey where
  C.APrivateKey a k == C.APrivateKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

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
  g <- C.newRandom
  (k, pk) <- atomically $ C.generateSignatureKeyPair alg g
  pure $ \s -> let b = encodeUtf8 $ T.pack s in C.verify k (C.sign pk b) b

testDHCryptoBox :: Spec
testDHCryptoBox = it "should encrypt / decrypt string with asymmetric DH keys" . ioProperty $ do
  g <- C.newRandom
  (sk, spk) <- atomically $ C.generateKeyPair g
  (rk, rpk) <- atomically $ C.generateKeyPair g
  nonce <- atomically $ C.randomCbNonce g
  pure $ \(s, pad) ->
    let b = encodeUtf8 $ T.pack s
        paddedLen = B.length b + abs pad + 2
        cipher = C.cbEncrypt (C.dh' rk spk) nonce b paddedLen
        plain = C.cbDecrypt (C.dh' sk rpk) nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testSecretBox :: Spec
testSecretBox = it "should encrypt / decrypt string with a random symmetric key" . ioProperty $ do
  g <- C.newRandom
  k <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
  pure $ \(s, pad) ->
    let b = encodeUtf8 $ T.pack s
        pad' = min (abs pad) 100000
        paddedLen = B.length b + pad' + 2
        cipher = C.sbEncrypt k nonce b paddedLen
        plain = C.sbDecrypt k nonce =<< cipher
     in isRight cipher && cipher /= plain && Right b == plain

testLazySecretBox :: Spec
testLazySecretBox = it "should lazily encrypt / decrypt string with a random symmetric key" . ioProperty $ do
  g <- C.newRandom
  k <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
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
  g <- C.newRandom
  k <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
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
  g <- C.newRandom
  k <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
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
  g <- C.newRandom
  k <- atomically $ C.randomSbKey g
  nonce <- atomically $ C.randomCbNonce g
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
  g <- C.newRandom
  k <- atomically $ C.randomAesKey g
  iv <- atomically $ C.randomGCMIV g
  s <- atomically $ C.randomBytes 100 g
  Right (tag, cipher) <- runExceptT $ C.encryptAESNoPad k iv s
  Right plain <- runExceptT $ C.decryptAESNoPad k iv cipher tag
  cipher `shouldNotBe` plain
  s `shouldBe` plain

testEncoding :: C.AlgorithmI a => C.SAlgorithm a -> Spec
testEncoding alg = it "should encode / decode key" . ioProperty $ do
  g <- C.newRandom
  (k, pk) <- atomically $ C.generateAKeyPair alg g
  pure $ \(_ :: Int) ->
    C.decodePubKey (C.encodePubKey k) == Right k
      && C.decodePrivKey (C.encodePrivKey pk) == Right pk

testValidateX509 :: IO ()
testValidateX509 = do
  let checkChain = validateCertificateChain SMPClient.testKeyHash "localhost" "5223" . X.CertificateChain
  checkChain [] `shouldReturn` [XV.EmptyChain]

  caCreds <- XS.readCertificates "tests/fixtures/ca.crt"
  caCreds `shouldNotBe` []
  let ca = head caCreds

  serverCreds <- XS.readCertificates "tests/fixtures/server.crt"
  serverCreds `shouldNotBe` []
  let server = head serverCreds
  checkChain [server, ca] `shouldReturn` []

  ca2Creds <- XS.readCertificates "tests/fixtures/ca2.crt"
  ca2Creds `shouldNotBe` []
  let ca2 = head ca2Creds

  -- signed by another CA
  server2Creds <- XS.readCertificates "tests/fixtures/server2.crt"
  server2Creds `shouldNotBe` []
  let server2 = head server2Creds
  checkChain [server2, ca2] `shouldReturn` [XV.UnknownCA]

  -- messed up key rotation or other configuration problems
  checkChain [server2, ca] `shouldReturn` [XV.InvalidSignature XV.SignatureInvalid]

  -- self-signed, unrelated to CA
  ssCreds <- XS.readCertificates "tests/fixtures/ss.crt"
  ssCreds `shouldNotBe` []
  let ss = head ssCreds
  checkChain [ss, ca] `shouldReturn` [XV.SelfSigned]

testSNTRUP761 :: IO ()
testSNTRUP761 = do
  drg <- C.newRandom
  (pk, sk) <- sntrup761Keypair drg
  (c, KEMSharedKey k) <- sntrup761Enc drg pk
  KEMSharedKey k' <- sntrup761Dec c sk
  k' `shouldBe` k

-- BBS+ tests

bbsHeader :: BBSHeader
bbsHeader = BBSHeader "SimpleX"

bbsMessages :: [B.ByteString]
bbsMessages = ["secret_master_key", "2026-07-31", "supporter"]

bbsDisclosedIdxs :: [Int]
bbsDisclosedIdxs = [1, 2]

bbsDisclosedMsgs :: [B.ByteString]
bbsDisclosedMsgs = ["2026-07-31", "supporter"]

testBBSSignVerify :: IO ()
testBBSSignVerify = do
  Right (pk, sk) <- bbsKeyGen
  let BBSSecretKey skBs = sk
      BBSPublicKey pkBs = pk
  B.length skBs `shouldBe` 32
  B.length pkBs `shouldBe` 96
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let BBSSignature sigBs = sig
  B.length sigBs `shouldBe` 80
  bbsVerify pk sig bbsHeader bbsMessages >>= (`shouldBe` True)
  bbsVerify pk sig bbsHeader ["wrong", "2026-07-31", "supporter"] >>= (`shouldBe` False)

testBBSPublicKeyDerivation :: IO ()
testBBSPublicKeyDerivation = do
  Right (pk, sk) <- bbsKeyGen
  -- the public key derived from the secret key matches the one keygen returned
  bbsPublicKey sk >>= (`shouldBe` Right pk)

testBBSProofRoundtrip :: IO ()
testBBSProofRoundtrip = do
  Right (pk, sk) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph = BBSPresHeader "test-nonce-1"
  Right proof <- bbsProofGen pk sig bbsHeader ph bbsDisclosedIdxs bbsMessages
  result <- bbsProofVerify pk proof bbsHeader ph bbsDisclosedIdxs 3 bbsDisclosedMsgs
  result `shouldBe` True

testBBSTamperedProof :: IO ()
testBBSTamperedProof = do
  Right (pk, sk) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph = BBSPresHeader "test-nonce-2"
  Right (BBSProof proofBs) <- bbsProofGen pk sig bbsHeader ph bbsDisclosedIdxs bbsMessages
  let tampered = BBSProof $ B.take 10 proofBs <> "\xff" <> B.drop 11 proofBs
  result <- bbsProofVerify pk tampered bbsHeader ph bbsDisclosedIdxs 3 bbsDisclosedMsgs
  result `shouldBe` False

testBBSWrongMessage :: IO ()
testBBSWrongMessage = do
  Right (pk, sk) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph = BBSPresHeader "test-nonce-3"
  Right proof <- bbsProofGen pk sig bbsHeader ph bbsDisclosedIdxs bbsMessages
  result <- bbsProofVerify pk proof bbsHeader ph bbsDisclosedIdxs 3 ["2026-07-31", "business"]
  result `shouldBe` False

testBBSWrongKey :: IO ()
testBBSWrongKey = do
  Right (pk, sk) <- bbsKeyGen
  Right (pk2, _) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph = BBSPresHeader "test-nonce-4"
  Right proof <- bbsProofGen pk sig bbsHeader ph bbsDisclosedIdxs bbsMessages
  result <- bbsProofVerify pk2 proof bbsHeader ph bbsDisclosedIdxs 3 bbsDisclosedMsgs
  result `shouldBe` False

testBBSUnlinkable :: IO ()
testBBSUnlinkable = do
  Right (pk, sk) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph1 = BBSPresHeader "nonce-contact-1"
      ph2 = BBSPresHeader "nonce-contact-2"
  Right (BBSProof proof1) <- bbsProofGen pk sig bbsHeader ph1 bbsDisclosedIdxs bbsMessages
  Right (BBSProof proof2) <- bbsProofGen pk sig bbsHeader ph2 bbsDisclosedIdxs bbsMessages
  proof1 `shouldNotBe` proof2
  bbsProofVerify pk (BBSProof proof1) bbsHeader ph1 bbsDisclosedIdxs 3 bbsDisclosedMsgs >>= (`shouldBe` True)
  bbsProofVerify pk (BBSProof proof2) bbsHeader ph2 bbsDisclosedIdxs 3 bbsDisclosedMsgs >>= (`shouldBe` True)

testBBSProofSize :: IO ()
testBBSProofSize = do
  Right (pk, sk) <- bbsKeyGen
  Right sig <- bbsSign sk bbsHeader bbsMessages
  let ph = BBSPresHeader "test-nonce-size"
  Right (BBSProof proofBs) <- bbsProofGen pk sig bbsHeader ph bbsDisclosedIdxs bbsMessages
  B.length proofBs `shouldBe` 304 -- 272 + 32 * 1 undisclosed
