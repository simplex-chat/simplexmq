{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module CoreTests.CryptoTests (cryptoTests) where

import Control.Concurrent.STM
import Control.Monad.Except
import qualified Crypto.Cipher.XSalsa as XSalsa
import qualified Crypto.Error as CE
import qualified Crypto.MAC.Poly1305 as Poly1305
import qualified Crypto.PubKey.Curve25519 as X25519
import Data.Bifunctor (bimap)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (isRight)
import Data.Int (Int64)
import Data.Memory.PtrMethods (memSet)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LE
import Data.Type.Equality
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import Foreign.C.ConstPtr (ConstPtr (..))
import qualified SMPClient
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import qualified Simplex.Messaging.Crypto.NaCl.Bindings as NaCl
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Transport.Client
import System.IO.Unsafe (unsafePerformIO)
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
  describe "X509 chains" $ do
    it "should validate certificates" testValidateX509
  describe "sntrup761" $
    it "should enc/dec key" testSNTRUP761
  describe "NaCl" $
    it "cryptobox is compatible" testNaCl

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

testNaCl :: IO ()
testNaCl = do
  drg <- C.newRandom
  (aPub :: C.PublicKeyX25519, aPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair drg
  (bPub :: C.PublicKeyX25519, bPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair drg
  let abShared@(C.DhSecretX25519 abShared') = C.dh' aPub bPriv
  let baShared@(C.DhSecretX25519 baShared') = C.dh' bPub aPriv
  abShared `shouldBe` baShared

  naclShared <- either error pure $ dhNacl aPub bPriv
  naclShared `shouldBe` abShared

  naclBeforeNm <- either error pure $ cryptoBoxBeforenm aPub bPriv
  abSharedH <- either error pure $ C.hsalsa20 abShared'
  naclBeforeNm `shouldBe` BA.convert abSharedH

  let msg = "hello long-enough world"
  nonce@(C.CbNonce nonce') <- atomically $ C.randomCbNonce drg
  naclCiphertext <- either (error . mappend "cryptoBox: " . show) pure $ cryptoBoxNaCl aPub bPriv nonce msg
  let refCiphertext = ref_cryptoBox abShared' nonce' msg
  (B.length naclCiphertext, naclCiphertext) `shouldBe` (B.length refCiphertext, refCiphertext)
  naclCiphertextAfternm <- either error pure $ C.secretBox abSharedH nonce' msg
  (B.length naclCiphertext, naclCiphertext) `shouldBe` (B.length naclCiphertextAfternm, naclCiphertextAfternm)

  refMsg <- either (error . show) pure $ ref_sbDecryptNoPad_ baShared' nonce naclCiphertext
  refMsg `shouldBe` msg

  naclMsg <- either error pure $ cryptoBoxOpenNaCl bPub aPriv nonce refCiphertext
  naclMsg `shouldBe` msg

  naclMsgAfternm <- either error pure $ C.secretBoxOpen abSharedH nonce' naclCiphertext
  naclMsgAfternm `shouldBe` msg

-- | A replica of C.dh' using NaCl (sans hsalsa20 step)
dhNacl :: C.PublicKeyX25519 -> C.PrivateKeyX25519 -> Either String (C.DhSecret 'C.X25519)
dhNacl (C.PublicKeyX25519 pub) (C.PrivateKeyX25519 priv _) = unsafePerformIO $ do
  (r, ba :: ScrubbedBytes) <- BA.withByteArray pub $ \pubPtr ->
    BA.withByteArray priv $ \privPtr ->
      BA.allocRet 32 $ \sharedPtr -> do
        memSet sharedPtr 0 32
        NaCl.crypto_scalarmult sharedPtr (ConstPtr privPtr) (ConstPtr pubPtr)
  pure $! if r /= 0 then Left "crypto_scalarmult" else bimap show C.DhSecretX25519 $ CE.eitherCryptoError (X25519.dhSecret ba)

cryptoBoxBeforenm :: C.PublicKeyX25519 -> C.PrivateKeyX25519 -> Either String ScrubbedBytes
cryptoBoxBeforenm (C.PublicKeyX25519 pub) (C.PrivateKeyX25519 priv _) = unsafePerformIO $ do
  (r, ba :: ScrubbedBytes) <- BA.withByteArray pub $ \pubPtr ->
    BA.withByteArray priv $ \privPtr ->
      BA.allocRet 32 $ \kPtr -> do
        memSet kPtr 0 32
        NaCl.c_crypto_box_beforenm kPtr (ConstPtr pubPtr) (ConstPtr privPtr)
  pure $! if r /= 0 then Left "crypto_box_beforenm" else Right ba

cryptoBoxNaCl :: BA.ByteArrayAccess msg => C.PublicKeyX25519 -> C.PrivateKeyX25519 -> C.CbNonce -> msg -> Either String ByteString
cryptoBoxNaCl (C.PublicKeyX25519 pk) (C.PrivateKeyX25519 sk _) (C.CbNonce n) msg = unsafePerformIO $ do
  (r, c) <-
    BA.withByteArray msg0 $ \mPtr ->
      BA.withByteArray n $ \nPtr ->
        BA.withByteArray pk $ \pkPtr ->
          BA.withByteArray sk $ \skPtr ->
            BA.allocRet (B.length msg0) $ \cPtr ->
              NaCl.c_crypto_box cPtr (ConstPtr mPtr) (fromIntegral $ B.length msg0) (ConstPtr nPtr) (ConstPtr pkPtr) (ConstPtr skPtr)
  pure $! if r /= 0 then Left "crypto_box" else Right (B.drop NaCl.crypto_box_BOXZEROBYTES c)
  where
    msg0 = zeroBytes <> BA.convert msg
    zeroBytes = B.replicate NaCl.crypto_box_ZEROBYTES '\0'

cryptoBoxOpenNaCl :: C.PublicKeyX25519 -> C.PrivateKeyX25519 -> C.CbNonce -> ByteString -> Either String ByteString
cryptoBoxOpenNaCl (C.PublicKeyX25519 pub) (C.PrivateKeyX25519 priv _) (C.CbNonce n) ciphertext = unsafePerformIO $ do
  (r, msg) <-
    BA.withByteArray ciphertext0 $ \cPtr ->
      BA.withByteArray n $ \nPtr ->
        BA.withByteArray pub $ \pubPtr ->
          BA.withByteArray priv $ \privPtr ->
            BA.allocRet cLen $ \mPtr ->
              NaCl.c_crypto_box_open mPtr (ConstPtr cPtr) (fromIntegral cLen) (ConstPtr nPtr) (ConstPtr pubPtr) (ConstPtr privPtr)
  pure $! if r /= 0 then Left "crypto_box_open" else Right (B.drop NaCl.crypto_box_ZEROBYTES msg)
  where
    ciphertext0 = boxZeroBytes <> ciphertext
    boxZeroBytes = B.replicate NaCl.crypto_box_BOXZEROBYTES '\0'
    cLen = B.length ciphertext0

ref_cryptoBox :: BA.ByteArrayAccess key => key -> ByteString -> ByteString -> ByteString
ref_cryptoBox secret nonce s = BA.convert tag <> c
  where
    (rs, c) = ref_xSalsa20 secret nonce s
    tag = Poly1305.auth rs c

-- | NaCl @crypto_box@ decrypt with a shared DH secret and 192-bit nonce (without unpadding).
ref_sbDecryptNoPad_ :: BA.ByteArrayAccess key => key -> C.CbNonce -> ByteString -> Either C.CryptoError ByteString
ref_sbDecryptNoPad_ secret (C.CbNonce nonce) packet
  | B.length packet < 16 = Left C.CBDecryptError
  | BA.constEq tag' tag = Right msg
  | otherwise = Left C.CBDecryptError
  where
    (tag', c) = B.splitAt 16 packet
    (rs, msg) = ref_xSalsa20 secret nonce c
    tag = Poly1305.auth rs c

ref_xSalsa20 :: BA.ByteArrayAccess key => key -> ByteString -> ByteString -> (ByteString, ByteString)
ref_xSalsa20 secret nonce msg = (rs, msg')
  where
    zero = B.replicate 16 $ toEnum 0
    (iv0, iv1) = B.splitAt 8 nonce
    state0 = XSalsa.initialize 20 secret (zero `B.append` iv0)
    state1 = XSalsa.derive state0 iv1
    (rs, state2) = XSalsa.generate state1 32
    (msg', _) = XSalsa.combine state2 msg
