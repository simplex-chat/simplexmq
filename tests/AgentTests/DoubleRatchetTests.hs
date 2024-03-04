{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module AgentTests.DoubleRatchetTests where

import Control.Concurrent.STM
import Control.Monad.Except
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON, ToJSON, (.=))
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import Simplex.Messaging.Crypto (Algorithm (..), AlgorithmI, CryptoError, DhAlgorithm)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$$>))
import Simplex.Messaging.Version
import Test.Hspec

doubleRatchetTests :: Spec
doubleRatchetTests = do
  describe "double-ratchet encryption/decryption" $ do
    it "should serialize and parse message header" testMessageHeader
    it "should encrypt and decrypt messages" $ do
      withRatchets @X25519 testEncryptDecrypt
      withRatchets @X448 testEncryptDecrypt
    it "should encrypt and decrypt skipped messages" $ do
      withRatchets @X25519 testSkippedMessages
      withRatchets @X448 testSkippedMessages
    it "should encrypt and decrypt many messages" $ do
      withRatchets @X25519 testManyMessages
    it "should allow skipped after ratchet advance" $ do
      withRatchets @X25519 testSkippedAfterRatchetAdvance
    it "should encode/decode ratchet as JSON" $ do
      testKeyJSON C.SX25519
      testKeyJSON C.SX448
      testRatchetJSON C.SX25519
      testRatchetJSON C.SX448
      testVersionJSON
    it "should agree the same ratchet parameters" $ do
      testX3dh C.SX25519
      testX3dh C.SX448
    it "should agree the same ratchet parameters with version 1" $ do
      testX3dhV1 C.SX25519
      testX3dhV1 C.SX448

paddedMsgLen :: Int
paddedMsgLen = 100

fullMsgLen :: Int
fullMsgLen = 1 + fullHeaderLen + C.authTagSize + paddedMsgLen

testMessageHeader :: Expectation
testMessageHeader = do
  (k, _) <- atomically . C.generateKeyPair @X25519 =<< C.newRandom
  let hdr = MsgHeader {msgMaxVersion = currentE2EEncryptVersion, msgDHRs = k, msgPN = 0, msgNs = 0}
  parseAll (smpP @(MsgHeader 'X25519)) (smpEncode hdr) `shouldBe` Right hdr

pattern Decrypted :: ByteString -> Either CryptoError (Either CryptoError ByteString)
pattern Decrypted msg <- Right (Right msg)

type TestRatchets a = (AlgorithmI a, DhAlgorithm a) => TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> IO ()

testEncryptDecrypt :: TestRatchets a
testEncryptDecrypt alice bob = do
  (bob, "hello alice") #> alice
  (alice, "hello bob") #> bob
  Right b1 <- encrypt bob "how are you, alice?"
  Right b2 <- encrypt bob "are you there?"
  Right b3 <- encrypt bob "hey?"
  Right a1 <- encrypt alice "how are you, bob?"
  Right a2 <- encrypt alice "are you there?"
  Right a3 <- encrypt alice "hey?"
  Decrypted "how are you, alice?" <- decrypt alice b1
  Decrypted "are you there?" <- decrypt alice b2
  Decrypted "hey?" <- decrypt alice b3
  Decrypted "how are you, bob?" <- decrypt bob a1
  Decrypted "are you there?" <- decrypt bob a2
  Decrypted "hey?" <- decrypt bob a3
  (bob, "I'm here, all good") #> alice
  (alice, "I'm here too, same") #> bob
  pure ()

testSkippedMessages :: TestRatchets a
testSkippedMessages alice bob = do
  Right msg1 <- encrypt bob "hello alice"
  Right msg2 <- encrypt bob "hello there again"
  Right msg3 <- encrypt bob "are you there?"
  Decrypted "are you there?" <- decrypt alice msg3
  Right (Left C.CERatchetDuplicateMessage) <- decrypt alice msg3
  Decrypted "hello there again" <- decrypt alice msg2
  Decrypted "hello alice" <- decrypt alice msg1
  pure ()

testManyMessages :: TestRatchets a
testManyMessages alice bob = do
  (bob, "b1") #> alice
  (bob, "b2") #> alice
  (bob, "b3") #> alice
  (bob, "b4") #> alice
  (alice, "a5") #> bob
  (alice, "a6") #> bob
  (alice, "a7") #> bob
  (bob, "b8") #> alice
  (alice, "a9") #> bob
  (alice, "a10") #> bob
  (bob, "b11") #> alice
  (bob, "b12") #> alice
  (alice, "a14") #> bob
  (bob, "b15") #> alice
  (bob, "b16") #> alice

testSkippedAfterRatchetAdvance :: TestRatchets a
testSkippedAfterRatchetAdvance alice bob = do
  (bob, "b1") #> alice
  Right b2 <- encrypt bob "b2"
  Right b3 <- encrypt bob "b3"
  Right b4 <- encrypt bob "b4"
  (alice, "a5") #> bob
  Right b5 <- encrypt bob "b5"
  Right b6 <- encrypt bob "b6"
  (bob, "b7") #> alice
  Right b8 <- encrypt bob "b8"
  Right b9 <- encrypt bob "b9"
  (alice, "a10") #> bob
  Right b11 <- encrypt bob "b11"
  Right b12 <- encrypt bob "b12"
  (alice, "a14") #> bob
  Decrypted "b12" <- decrypt alice b12
  Decrypted "b2" <- decrypt alice b2
  -- fails on duplicate message
  Left C.CERatchetHeader <- decrypt alice b2
  (alice, "a15") #> bob
  Right a16 <- encrypt bob "a16"
  Right a17 <- encrypt bob "a17"
  Decrypted "b8" <- decrypt alice b8
  Decrypted "b3" <- decrypt alice b3
  Decrypted "b4" <- decrypt alice b4
  Decrypted "b5" <- decrypt alice b5
  Decrypted "b6" <- decrypt alice b6
  (alice, "a18") #> bob
  Decrypted "a16" <- decrypt alice a16
  Decrypted "a17" <- decrypt alice a17
  Decrypted "b9" <- decrypt alice b9
  Decrypted "b11" <- decrypt alice b11
  pure ()

testKeyJSON :: forall a. AlgorithmI a => C.SAlgorithm a -> IO ()
testKeyJSON _ = do
  (k, pk) <- atomically . C.generateKeyPair @a =<< C.newRandom
  testEncodeDecode k
  testEncodeDecode pk

testRatchetJSON :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testRatchetJSON _ = do
  (alice, bob) <- initRatchets @a
  testEncodeDecode alice
  testEncodeDecode bob

testVersionJSON :: IO ()
testVersionJSON = do
  testEncodeDecode $ rv 1 1
  testEncodeDecode $ rv 1 2
  -- let bad = RVersions 2 1
  -- Left err <- pure $ J.eitherDecode' @RatchetVersions (J.encode bad)
  -- err `shouldContain` "bad version range"
  testDecodeRV $ (1 :: Int, 2 :: Int)
  testDecodeRV $ J.object ["current" .= (1 :: Int), "maxSupported" .= (2 :: Int)]
  where
    rv v1 v2 = ratchetVersions $ mkVersionRange (VersionE2E v1) (VersionE2E v2)
    testDecodeRV :: ToJSON a => a -> Expectation
    testDecodeRV a = J.eitherDecode' (J.encode a) `shouldBe` Right (rv 1 2)

testEncodeDecode :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
testEncodeDecode x = do
  let j = J.encode x
      x' = J.eitherDecode' j
  x' `shouldBe` Right x

testX3dh :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dh _ = do
  g <- C.newRandom
  (pkBob1, pkBob2, e2eBob) <- atomically $ generateE2EParams @a g currentE2EEncryptVersion
  (pkAlice1, pkAlice2, e2eAlice) <- atomically $ generateE2EParams @a g currentE2EEncryptVersion
  let paramsBob = x3dhSnd pkBob1 pkBob2 e2eAlice
      paramsAlice = x3dhRcv pkAlice1 pkAlice2 e2eBob
  paramsAlice `shouldBe` paramsBob

testX3dhV1 :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dhV1 _ = do
  g <- C.newRandom
  (pkBob1, pkBob2, e2eBob) <- atomically $ generateE2EParams @a g (VersionE2E 1)
  (pkAlice1, pkAlice2, e2eAlice) <- atomically $ generateE2EParams @a g (VersionE2E 1)
  let paramsBob = x3dhSnd pkBob1 pkBob2 e2eAlice
      paramsAlice = x3dhRcv pkAlice1 pkAlice2 e2eBob
  paramsAlice `shouldBe` paramsBob

(#>) :: (AlgorithmI a, DhAlgorithm a) => (TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys), ByteString) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> Expectation
(alice, msg) #> bob = do
  Right msg' <- encrypt alice msg
  Decrypted msg'' <- decrypt bob msg'
  msg'' `shouldBe` msg

withRatchets :: forall a. (AlgorithmI a, DhAlgorithm a) => (TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> IO ()) -> Expectation
withRatchets test = do
  ga <- C.newRandom
  gb <- C.newRandom
  (a, b) <- initRatchets @a
  alice <- newTVarIO (ga, a, M.empty)
  bob <- newTVarIO (gb, b, M.empty)
  test alice bob `shouldReturn` ()

initRatchets :: (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchets = do
  g <- C.newRandom
  (pkBob1, pkBob2, e2eBob) <- atomically $ generateE2EParams g currentE2EEncryptVersion
  (pkAlice1, pkAlice2, e2eAlice) <- atomically $ generateE2EParams g currentE2EEncryptVersion
  let paramsBob = x3dhSnd pkBob1 pkBob2 e2eAlice
      paramsAlice = x3dhRcv pkAlice1 pkAlice2 e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let bob = initSndRatchet supportedE2EEncryptVRange (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet supportedE2EEncryptVRange pkAlice2 paramsAlice
  pure (alice, bob)

encrypt_ :: AlgorithmI a => (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (ByteString, Ratchet a, SkippedMsgDiff))
encrypt_ (_, rc, _) msg =
  runExceptT (rcEncrypt rc paddedMsgLen msg)
    >>= either (pure . Left) checkLength
  where
    checkLength (msg', rc') = do
      B.length msg' `shouldBe` fullMsgLen
      pure $ Right (msg', rc', SMDNoChange)

decrypt_ :: (AlgorithmI a, DhAlgorithm a) => (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString, Ratchet a, SkippedMsgDiff))
decrypt_ (g, rc, smks) msg = runExceptT $ rcDecrypt g rc smks msg

encrypt :: AlgorithmI a => TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError ByteString)
encrypt = withTVar encrypt_

decrypt :: (AlgorithmI a, DhAlgorithm a) => TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString))
decrypt = withTVar decrypt_

withTVar ::
  AlgorithmI a =>
  ((TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either e (r, Ratchet a, SkippedMsgDiff))) ->
  TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) ->
  ByteString ->
  IO (Either e r)
withTVar op rcVar msg = do
  (g, rc, smks) <- readTVarIO rcVar
  applyDiff smks <$$> (testEncodeDecode rc >> op (g, rc, smks) msg)
    >>= \case
      Right (res, rc', smks') -> atomically (writeTVar rcVar (g, rc', smks')) >> pure (Right res)
      Left e -> pure $ Left e
  where
    applyDiff smks (res, rc', smDiff) = (res, rc', applySMDiff smks smDiff)
