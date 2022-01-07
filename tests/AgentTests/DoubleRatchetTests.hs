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
import Crypto.Random (getRandomBytes)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import Simplex.Messaging.Crypto (Algorithm (..), AlgorithmI, CryptoError, DhAlgorithm)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
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

paddedMsgLen :: Int
paddedMsgLen = 100

fullMsgLen :: Int
fullMsgLen = 1 + fullHeaderLen + 1 + paddedMsgLen + C.authTagSize

testMessageHeader :: Expectation
testMessageHeader = do
  (k, _) <- C.generateKeyPair' @X25519
  let hdr = MsgHeader {msgMaxVersion = e2eEncryptVersion, msgDHRs = k, msgPN = 0, msgNs = 0}
  parseAll (smpP @(MsgHeader 'X25519)) (smpEncode hdr) `shouldBe` Right hdr

pattern Decrypted :: ByteString -> Either CryptoError (Either CryptoError ByteString)
pattern Decrypted msg <- Right (Right msg)

type TestRatchets a = (AlgorithmI a, DhAlgorithm a) => TVar (Ratchet a, SkippedMsgKeys) -> TVar (Ratchet a, SkippedMsgKeys) -> IO ()

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

(#>) :: (AlgorithmI a, DhAlgorithm a) => (TVar (Ratchet a, SkippedMsgKeys), ByteString) -> TVar (Ratchet a, SkippedMsgKeys) -> Expectation
(alice, msg) #> bob = do
  Right msg' <- encrypt alice msg
  Decrypted msg'' <- decrypt bob msg'
  msg'' `shouldBe` msg

withRatchets :: forall a. (AlgorithmI a, DhAlgorithm a) => (TVar (Ratchet a, SkippedMsgKeys) -> TVar (Ratchet a, SkippedMsgKeys) -> IO ()) -> Expectation
withRatchets test = do
  (a, b) <- initRatchets @a
  alice <- newTVarIO (a, M.empty)
  bob <- newTVarIO (b, M.empty)
  test alice bob `shouldReturn` ()

initRatchets :: (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchets = do
  salt <- getRandomBytes 16
  (ak, apk) <- C.generateKeyPair'
  (bk, bpk) <- C.generateKeyPair'
  bob <- initSndRatchet' ak bpk salt "bob -> alice"
  alice <- initRcvRatchet' bk (ak, apk) salt "bob -> alice"
  pure (alice, bob)

encrypt_ :: AlgorithmI a => (Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (ByteString, Ratchet a, SkippedMsgKeys))
encrypt_ (rc, smks) msg =
  runExceptT (rcEncrypt' rc paddedMsgLen msg)
    >>= either (pure . Left) checkLength
  where
    checkLength (msg', rc') = do
      B.length msg' `shouldBe` fullMsgLen
      pure $ Right (msg', rc', smks)

decrypt_ :: (AlgorithmI a, DhAlgorithm a) => (Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString, Ratchet a, SkippedMsgKeys))
decrypt_ (rc, smks) msg = runExceptT $ rcDecrypt' rc smks msg

encrypt :: AlgorithmI a => TVar (Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError ByteString)
encrypt = withTVar encrypt_

decrypt :: (AlgorithmI a, DhAlgorithm a) => TVar (Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString))
decrypt = withTVar decrypt_

withTVar ::
  ((Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either e (r, Ratchet a, SkippedMsgKeys))) ->
  TVar (Ratchet a, SkippedMsgKeys) ->
  ByteString ->
  IO (Either e r)
withTVar op rcVar msg =
  readTVarIO rcVar
    >>= (`op` msg)
    >>= \case
      Right (res, rc', smks') -> atomically (writeTVar rcVar (rc', smks')) >> pure (Right res)
      Left e -> pure $ Left e
