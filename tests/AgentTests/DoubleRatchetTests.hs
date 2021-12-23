{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module AgentTests.DoubleRatchetTests where

import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Simplex.Messaging.Crypto (Algorithm (..), AlgorithmI, CryptoError, DhAlgorithm)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Parsers (parseAll)
import Test.Hspec

doubleRatchetTests :: Spec
doubleRatchetTests = do
  describe "double-ratchet encryption/decryption" $ do
    it "should serialize and parse message header" $
      testMessageHeader `shouldReturn` ()
    it "should encrypt and decrypt messages" $
      testEncryptDecrypt `shouldReturn` ()
    it "should encrypt and decrypt skipped messages" $
      testSkippedMessages `shouldReturn` ()

paddedMsgLen :: Int
paddedMsgLen = 100

fullMsgLen :: Int
fullMsgLen = fullHeaderLen + paddedMsgLen + C.authTagSize

testMessageHeader :: IO ()
testMessageHeader = do
  (k, _) <- C.generateKeyPair' @X25519 0
  let hdr = MsgHeader {msgVersion = 1, msgLatestVersion = 1, msgDHRs = k, msgPN = 0, msgNs = 0, msgLen = 11}
  parseAll (msgHeaderP' @X25519) (serializeMsgHeader' hdr) `shouldBe` Right hdr

pattern Decrypted :: ByteString -> Ratchet a -> Either CryptoError (Either CryptoError ByteString, Ratchet a)
pattern Decrypted msg rc <- Right (Right msg, rc)

testEncryptDecrypt :: IO ()
testEncryptDecrypt = do
  (bob, alice) <- initRatchets

  Right (msg1, bob1) <- encrypt bob "hello alice"
  Decrypted "hello alice" alice1 <- decrypt alice msg1

  Right (msg2, bob2) <- encrypt bob1 "hello there again"
  Decrypted "hello there again" alice2 <- decrypt alice1 msg2

  Right (msg3, alice3) <- encrypt alice2 "hello bob"
  Decrypted "hello bob" bob3 <- decrypt bob2 msg3

  Right (msg4, _) <- encrypt alice3 "hello bob again"
  Decrypted "hello bob again" _ <- decrypt bob3 msg4

  pure ()

testSkippedMessages :: IO ()
testSkippedMessages = do
  (bob, alice) <- initRatchets

  Right (msg1, bob1) <- encrypt bob "hello alice"
  Right (msg2, bob2) <- encrypt bob1 "hello there again"
  Right (msg3, _) <- encrypt bob2 "are you there?"

  Decrypted "are you there?" alice1 <- decrypt alice msg3
  Decrypted "hello there again" alice2 <- decrypt alice1 msg2
  Decrypted "hello alice" _ <- decrypt alice2 msg1

  pure ()

initRatchets :: IO (Ratchet X25519, Ratchet X25519)
initRatchets = do
  salt <- getRandomBytes 16
  (ak, apk) <- C.generateKeyPair' 0
  (bk, bpk) <- C.generateKeyPair' 0
  bob <- initSndRatchet' ak bpk salt
  alice <- initRcvRatchet' bk (ak, apk) salt
  pure (bob, alice)

encrypt :: AlgorithmI a => Ratchet a -> ByteString -> IO (Either CryptoError (ByteString, Ratchet a))
encrypt rc msg =
  runExceptT (rcEncrypt' rc paddedMsgLen msg)
    >>= either (pure . Left) checkLength
  where
    checkLength r@(msg', _) = do
      B.length msg' `shouldBe` fullMsgLen
      pure $ Right r

decrypt :: (AlgorithmI a, DhAlgorithm a) => Ratchet a -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString, Ratchet a))
decrypt rc msg = runExceptT $ rcDecrypt' rc msg
