{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

module AgentTests.DoubleRatchetTests where

import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON, ToJSON, (.=))
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import Data.Type.Equality
import Simplex.Messaging.Crypto (Algorithm (..), AlgorithmI, CryptoError, DhAlgorithm)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$$>))
import Simplex.Messaging.Version
import Test.Hspec

doubleRatchetTests :: Spec
doubleRatchetTests = do
  describe "double-ratchet encryption/decryption" $ do
    it "should serialize and parse message header" $ do
      testAlgs $ testMessageHeader kdfX3DHE2EEncryptVersion
      testAlgs $ testMessageHeader $ max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
    describe "message tests" $ runMessageTests initRatchets False
    it "should encode/decode ratchet as JSON" $ do
      testAlgs testKeyJSON
      testAlgs testRatchetJSON
      testVersionJSON
    it "should decode v2 Ratchet with default field values" $ testDecodeV2RatchetJSON
    it "should agree the same ratchet parameters" $ testAlgs testX3dh
    it "should agree the same ratchet parameters with version 1" $ testAlgs testX3dhV1
  describe "post-quantum hybrid KEM double-ratchet algorithm" $ do
    describe "hybrid KEM key agreement" $ do
      it "should propose KEM during agreement, but no shared secret" $ testAlgs testPqX3dhProposeInReply
      it "should agree shared secret using KEM" $ testAlgs testPqX3dhProposeAccept
      it "should reject proposed KEM in reply" $ testAlgs testPqX3dhProposeReject
      it "should allow second proposal in reply" $ testAlgs testPqX3dhProposeAgain
    describe "hybrid KEM key agreement errors" $ do
      it "should fail if reply contains acceptance without proposal" $ testAlgs testPqX3dhAcceptWithoutProposalError
    describe "ratchet encryption/decryption" $ do
      it "should serialize and parse public KEM params" testKEMParams
      it "should serialize and parse message header" $ testAlgs testMessageHeaderKEM
      describe "message tests, KEM proposed" $ runMessageTests initRatchetsKEMProposed True
      describe "message tests, KEM accepted" $ runMessageTests initRatchetsKEMAccepted False
      describe "message tests, KEM proposed again in reply" $ runMessageTests initRatchetsKEMProposedAgain True
      it "should disable and re-enable KEM" $ withRatchets_ @X25519 initRatchetsKEMAccepted testDisableEnableKEM
      it "should disable and re-enable KEM (always set PQEncryption)" $ withRatchets_ @X25519 initRatchetsKEMAccepted testDisableEnableKEMStrict
      it "should enable KEM when it was not enabled in handshake" $ withRatchets_ @X25519 initRatchets testEnableKEM
      it "should enable KEM when it was not enabled in handshake (always set PQEncryption)" $ withRatchets_ @X25519 initRatchets testEnableKEMStrict

runMessageTests ::
  (forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a)) ->
  Bool ->
  Spec
runMessageTests initRatchets_ agreeRatchetKEMs = do
  it "should encrypt and decrypt messages" $ run $ testEncryptDecrypt agreeRatchetKEMs
  it "should encrypt and decrypt skipped messages" $ run $ testSkippedMessages agreeRatchetKEMs
  it "should encrypt and decrypt many messages" $ run $ testManyMessages agreeRatchetKEMs
  it "should allow skipped after ratchet advance" $ run $ testSkippedAfterRatchetAdvance agreeRatchetKEMs
  where
    run :: (forall a. (AlgorithmI a, DhAlgorithm a) => TestRatchets a) -> IO ()
    run test = do
      withRatchets_ @X25519 initRatchets_ test
      withRatchets_ @X448 initRatchets_ test


testAlgs :: (forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()) -> IO ()
testAlgs test = test C.SX25519 >> test C.SX448

paddedMsgLen :: Int
paddedMsgLen = 100

fullMsgLen :: Ratchet a -> Int
fullMsgLen Ratchet {rcSupportKEM, rcVersion} = headerLenLength + fullHeaderLen v rcSupportKEM + C.authTagSize + paddedMsgLen
  where
    v = current rcVersion
    headerLenLength
      | v >= pqRatchetE2EEncryptVersion = 3 -- two bytes are added because of two Large used in new encoding
      | otherwise = 1

testMessageHeader :: forall a. AlgorithmI a => VersionE2E -> C.SAlgorithm a -> Expectation
testMessageHeader v _ = do
  (k, _) <- atomically . C.generateKeyPair @a =<< C.newRandom
  let hdr = MsgHeader {msgMaxVersion = v, msgDHRs = k, msgKEM = Nothing, msgPN = 0, msgNs = 0}
  parseAll (msgHeaderP v) (encodeMsgHeader v hdr) `shouldBe` Right hdr

testKEMParams :: Expectation
testKEMParams = do
  g <- C.newRandom
  (kem, _) <- sntrup761Keypair g
  let kemParams = ARKP SRKSProposed $ RKParamsProposed kem
  parseAll (smpP @ARKEMParams) (smpEncode kemParams) `shouldBe` Right kemParams
  (kem', _) <- sntrup761Keypair g
  (ct, _) <- sntrup761Enc g kem
  let kemParams' = ARKP SRKSAccepted $ RKParamsAccepted ct kem'
  parseAll (smpP @ARKEMParams) (smpEncode kemParams') `shouldBe` Right kemParams'

testMessageHeaderKEM :: forall a. AlgorithmI a => C.SAlgorithm a -> Expectation
testMessageHeaderKEM _ = do
  g <- C.newRandom
  (k, _) <- atomically $ C.generateKeyPair @a g
  (kem, _) <- sntrup761Keypair g
  let msgMaxVersion = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
      msgKEM = Just . ARKP SRKSProposed $ RKParamsProposed kem
      hdr = MsgHeader {msgMaxVersion, msgDHRs = k, msgKEM, msgPN = 0, msgNs = 0}
  parseAll (msgHeaderP msgMaxVersion) (encodeMsgHeader msgMaxVersion hdr) `shouldBe` Right hdr
  (kem', _) <- sntrup761Keypair g
  (ct, _) <- sntrup761Enc g kem
  let msgKEM' = Just . ARKP SRKSAccepted $ RKParamsAccepted ct kem'
      hdr' = MsgHeader {msgMaxVersion, msgDHRs = k, msgKEM = msgKEM', msgPN = 0, msgNs = 0}
  parseAll (msgHeaderP msgMaxVersion) (encodeMsgHeader msgMaxVersion hdr') `shouldBe` Right hdr'

pattern Decrypted :: ByteString -> Either CryptoError (Either CryptoError ByteString)
pattern Decrypted msg <- Right (Right msg)

type Encrypt a = TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError ByteString)

type Decrypt a = TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString))

type EncryptDecryptSpec a = (TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys), ByteString) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> Expectation

type TestRatchets a =
  TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) ->
  TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) ->
  Encrypt a ->
  Decrypt a ->
  EncryptDecryptSpec a ->
  IO ()

deriving instance Eq (Ratchet a)

deriving instance Eq (SndRatchet a)

deriving instance Eq RcvRatchet

deriving instance Eq RatchetKEM

deriving instance Eq RatchetKEMAccepted

deriving instance Eq RatchetInitParams

deriving instance Eq RatchetKey

instance Eq ARKEMParams where
  (ARKP s ps) == (ARKP s' ps') = case testEquality s s' of
    Just Refl -> ps == ps'
    Nothing -> False

deriving instance Eq (MsgHeader a)

initRatchetKEM :: (AlgorithmI a, DhAlgorithm a) => TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> IO ()
initRatchetKEM s r = encryptDecrypt (Just $ PQEncOn) (const ()) (const ()) (s, "initialising ratchet") r

testEncryptDecrypt :: (AlgorithmI a, DhAlgorithm a) => Bool -> TestRatchets a
testEncryptDecrypt agreeRatchetKEMs alice bob encrypt decrypt (#>) = do
  when agreeRatchetKEMs $ initRatchetKEM bob alice >> initRatchetKEM alice bob
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

testSkippedMessages :: (AlgorithmI a, DhAlgorithm a) => Bool -> TestRatchets a
testSkippedMessages agreeRatchetKEMs alice bob encrypt decrypt _ = do
  when agreeRatchetKEMs $ initRatchetKEM bob alice >> initRatchetKEM alice bob
  Right msg1 <- encrypt bob "hello alice"
  Right msg2 <- encrypt bob "hello there again"
  Right msg3 <- encrypt bob "are you there?"
  Decrypted "are you there?" <- decrypt alice msg3
  Right (Left C.CERatchetDuplicateMessage) <- decrypt alice msg3
  Decrypted "hello there again" <- decrypt alice msg2
  Decrypted "hello alice" <- decrypt alice msg1
  pure ()

testManyMessages :: (AlgorithmI a, DhAlgorithm a) => Bool -> TestRatchets a
testManyMessages agreeRatchetKEMs alice bob _ _ (#>) = do
  when agreeRatchetKEMs $ initRatchetKEM bob alice >> initRatchetKEM alice bob
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

testSkippedAfterRatchetAdvance :: (AlgorithmI a, DhAlgorithm a) => Bool -> TestRatchets a
testSkippedAfterRatchetAdvance agreeRatchetKEMs alice bob encrypt decrypt (#>) = do
  when agreeRatchetKEMs $ initRatchetKEM bob alice >> initRatchetKEM alice bob
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

testDisableEnableKEM :: forall a. (AlgorithmI a, DhAlgorithm a) => TestRatchets a
testDisableEnableKEM alice bob _ _ _ = do
  (bob, "hello alice") !#> alice
  (alice, "hello bob") !#> bob
  (bob, "disabling KEM") !#>\ alice
  (alice, "still disabling KEM") !#> bob
  (bob, "now KEM is disabled") \#> alice
  (alice, "KEM is disabled for both sides") \#> bob
  (bob, "trying to enable KEM") \#>! alice
  (alice, "but unless alice enables it too it won't enable") \#> bob
  (bob, "KEM is disabled") \#> alice
  (alice, "KEM is disabled for both sides") \#> bob
  (bob, "enabling KEM again") \#>! alice
  (alice, "and alice accepts it this time") \#>! bob
  (bob, "still enabling KEM") \#>! alice
  (alice, "now KEM is enabled") !#> bob
  (bob, "KEM is enabled for both sides") !#> alice

testDisableEnableKEMStrict :: forall a. (AlgorithmI a, DhAlgorithm a) => TestRatchets a
testDisableEnableKEMStrict alice bob _ _ _ = do
  (bob, "hello alice") !#>! alice
  (alice, "hello bob") !#>! bob
  (bob, "disabling KEM") !#>\ alice
  (alice, "still disabling KEM") !#>! bob
  (bob, "now KEM is disabled") \#>\ alice
  (alice, "KEM is disabled for both sides") \#>\ bob
  (bob, "trying to enable KEM") \#>! alice
  (alice, "but unless alice enables it too it won't enable") \#>\ bob
  (bob, "KEM is disabled") \#>! alice
  (alice, "KEM is disabled for both sides") \#>\ bob
  (bob, "enabling KEM again") \#>! alice
  (alice, "and alice accepts it this time") \#>! bob
  (bob, "still enabling KEM") \#>! alice
  (alice, "now KEM is enabled") !#>! bob
  (bob, "KEM is enabled for both sides") !#>! alice

testEnableKEM :: forall a. (AlgorithmI a, DhAlgorithm a) => TestRatchets a
testEnableKEM alice bob _ _ _ = do
  (bob, "hello alice") \#> alice
  (alice, "hello bob") \#> bob
  (bob, "enabling KEM") \#>! alice
  (bob, "KEM not enabled yet") \#>! alice
  (alice, "accepting KEM") \#>! bob
  (alice, "KEM not enabled yet here too") \#>! bob
  (bob, "KEM is still not enabled") \#>! alice
  (alice, "now KEM is enabled") !#>! bob
  (bob, "now KEM is enabled for both sides") !#> alice
  (alice, "still enabled for both sides") !#> bob
  (bob, "still enabled for both sides 2") !#> alice
  (alice, "disabling KEM") !#>\ bob
  (bob, "KEM not disabled yet") !#> alice
  (alice, "KEM disabled") \#> bob
  (bob, "KEM disabled on both sides") \#> alice

testEnableKEMStrict :: forall a. (AlgorithmI a, DhAlgorithm a) => TestRatchets a
testEnableKEMStrict alice bob _ _ _ = do
  (bob, "hello alice") \#>\ alice
  (alice, "hello bob") \#>\ bob
  (bob, "enabling KEM") \#>! alice
  (bob, "KEM not enabled yet") \#>! alice
  (alice, "accepting KEM") \#>! bob
  (alice, "KEM not enabled yet here too") \#>! bob
  (bob, "KEM is still not enabled") \#>! alice
  (alice, "now KEM is enabled") !#>! bob
  (bob, "now KEM is enabled for both sides") !#>! alice
  (alice, "still enabled for both sides") !#>! bob
  (bob, "still enabled for both sides 2") !#>! alice
  (alice, "disabling KEM") !#>\ bob
  (bob, "KEM not disabled yet") !#>! alice
  (alice, "KEM disabled") \#>\ bob
  (bob, "KEM disabled on both sides") \#>! alice
  (alice, "KEM still disabled 1") \#>\ bob
  (bob, "KEM still disabled 2") \#>! alice
  (alice, "KEM still disabled 3") \#>\ bob
  (bob, "KEM still disabled 4") \#>! alice
  (alice, "KEM still disabled 5") \#>\ bob
  (bob, "KEM still disabled 6") \#>! alice

testKeyJSON :: forall a. AlgorithmI a => C.SAlgorithm a -> IO ()
testKeyJSON _ = do
  (k, pk) <- atomically . C.generateKeyPair @a =<< C.newRandom
  testEncodeDecode k
  testEncodeDecode pk

testRatchetJSON :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testRatchetJSON _ = do
  (alice, bob, _, _, _) <- initRatchets @a
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
    rv v1 v2 = RatchetVersions (VersionE2E v1) (VersionE2E v2)
    testDecodeRV :: ToJSON a => a -> Expectation
    testDecodeRV a = J.eitherDecode' (J.encode a) `shouldBe` Right (rv 1 2)

testDecodeV2RatchetJSON :: IO ()
testDecodeV2RatchetJSON = do
  let v2RatchetJSON = "{\"rcVersion\":[2,2],\"rcAD\":\"2GEJrq48TmQse6NR16I-hrI0tSySZQ57E_g46nDceAPRAiF6j0drq26RTE7be6X7uiB4RaGJGf4QRXzcYuVtWw==\",\"rcDHRs\":\"TUM0Q0FRQXdCUVlESzJWdUJDSUVJRkNYbUxtSHQ3SUNfeHpGTi1Qb3ZqTVQ3S2p6XzZlZlBjOG9fRFY2RWxKOQ==\",\"rcRK\":\"BOX2X7YW5qDSp2XknY_lqacSrtDqQNPvS6iJlZIs3G0=\",\"rcNs\":0,\"rcNr\":0,\"rcPN\":0,\"rcNHKs\":\"IMouSkXUvzT_mo0WM-pqEUK09-HTLk9WOTCFQglyQxU=\",\"rcNHKr\":\"g-tus1clYPV0rGlzkf5a959tUqDYQVZ1FpcPeXdKwxI=\"}"
  Right (r :: Ratchet X25519) <- pure $ J.eitherDecodeStrict' v2RatchetJSON
  rcSupportKEM r `shouldBe` PQSupportOff
  rcEnableKEM r `shouldBe` PQEncOff
  rcSndKEM r `shouldBe` PQEncOff
  rcRcvKEM r `shouldBe` PQEncOff

testEncodeDecode :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
testEncodeDecode x = do
  let j = J.encode x
      x' = J.eitherDecode' j
  x' `shouldBe` Right x

testX3dh :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dh _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v Nothing
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOff
  let paramsBob = pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `shouldBe` paramsBob

testX3dhV1 :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dhV1 _ = do
  g <- C.newRandom
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g (VersionE2E 1) Nothing
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g (VersionE2E 1) PQSupportOff
  let paramsBob = pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `shouldBe` paramsBob

testPqX3dhProposeInReply :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeInReply _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOff
  -- propose KEM in reply
  (pkBob1, pkBob2, pKemBob_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSProposed ProposeKEM)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemBob_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhProposeAccept :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeAccept _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, pKemAlice_@(Just _), e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOn
  E2ERatchetParams _ _ _ (Just (RKParamsProposed aliceKem)) <- pure e2eAlice
  -- accept KEM
  (pkBob1, pkBob2, pKemBob_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSAccepted $ AcceptKEM aliceKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemBob_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 pKemAlice_ e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhProposeReject :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeReject _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, pKemAlice_@(Just _), e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOn
  E2ERatchetParams _ _ _ (Just (RKParamsProposed _)) <- pure e2eAlice
  -- reject KEM
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v Nothing
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 pKemAlice_ e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhAcceptWithoutProposalError :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhAcceptWithoutProposalError _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOff
  E2ERatchetParams _ _ _ Nothing <- pure e2eAlice
  -- incorrectly accept KEM
  -- we don't have key in proposal, so we just generate it
  (k, _) <- sntrup761Keypair g
  (pkBob1, pkBob2, pKemBob_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSAccepted $ AcceptKEM k)
  pqX3dhSnd pkBob1 pkBob2 pKemBob_ e2eAlice `shouldBe` Left C.CERatchetKEMState
  runExceptT (pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob) `shouldReturn` Left C.CERatchetKEMState

testPqX3dhProposeAgain :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeAgain _ = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, pKemAlice_@(Just _), e2eAlice) <- liftIO $ generateRcvE2EParams @a g v PQSupportOn
  E2ERatchetParams _ _ _ (Just (RKParamsProposed _)) <- pure e2eAlice
  -- propose KEM again in reply - this is not an error
  (pkBob1, pkBob2, pKemBob_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSProposed ProposeKEM)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemBob_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 pKemAlice_ e2eBob
  paramsAlice `compatibleRatchets` paramsBob

compatibleRatchets :: (RatchetInitParams, x) -> (RatchetInitParams, x) -> Expectation
compatibleRatchets
  (RatchetInitParams {assocData, ratchetKey, sndHK, rcvNextHK, kemAccepted}, _)
  (RatchetInitParams {assocData = ad, ratchetKey = rk, sndHK = shk, rcvNextHK = rnhk, kemAccepted = ka}, _) = do
    assocData == ad && ratchetKey == rk && sndHK == shk && rcvNextHK == rnhk `shouldBe` True
    case (kemAccepted, ka) of
      (Just RatchetKEMAccepted {rcPQRr, rcPQRss, rcPQRct}, Just RatchetKEMAccepted {rcPQRr = pqk, rcPQRss = pqss, rcPQRct = pqct}) ->
        pqk /= rcPQRr && pqss == rcPQRss && pqct == rcPQRct `shouldBe` True
      (Nothing, Nothing) -> pure ()
      _ -> expectationFailure "RatchetInitParams params are not compatible"

encryptDecrypt :: (AlgorithmI a, DhAlgorithm a) => Maybe PQEncryption -> (Ratchet a -> ()) -> (Ratchet a -> ()) -> EncryptDecryptSpec a
encryptDecrypt pqEnc validSnd validRcv (alice, msg) bob = do
  Right msg' <- withTVar (encrypt_ pqEnc) validSnd alice msg
  Decrypted msg'' <- decrypt' validRcv bob msg'
  msg'' `shouldBe` msg

-- enable KEM (currently disabled)
(\#>!) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) \#>! r = encryptDecrypt (Just PQEncOn) noSndKEM noRcvKEM (s, msg) r

-- enable KEM (currently enabled)
(!#>!) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) !#>! r = encryptDecrypt (Just PQEncOn) hasSndKEM hasRcvKEM (s, msg) r

-- KEM enabled (no user preference)
(!#>) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) !#> r = encryptDecrypt Nothing hasSndKEM hasRcvKEM (s, msg) r

-- disable KEM (currently enabled)
(!#>\) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) !#>\ r = encryptDecrypt (Just PQEncOff) hasSndKEM hasRcvKEM (s, msg) r

-- disable KEM (currently disabled)
(\#>\) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) \#>\ r = encryptDecrypt (Just PQEncOff) noSndKEM noSndKEM (s, msg) r

-- KEM disabled (no user preference)
(\#>) :: (AlgorithmI a, DhAlgorithm a) => EncryptDecryptSpec a
(s, msg) \#> r = encryptDecrypt Nothing noSndKEM noSndKEM (s, msg) r

withRatchets_ :: IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a) -> TestRatchets a -> Expectation
withRatchets_ initRatchets_ test = do
  ga <- C.newRandom
  gb <- C.newRandom
  (a, b, encrypt, decrypt, (#>)) <- initRatchets_
  alice <- newTVarIO (ga, a, M.empty)
  bob <- newTVarIO (gb, b, M.empty)
  test alice bob encrypt decrypt (#>) `shouldReturn` ()

initRatchets :: (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a)
initRatchets = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  (pkBob1, pkBob2, _pKemParams@Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v Nothing
  (pkAlice1, pkAlice2, _pKem@Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams g v PQSupportOff
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let vs = testRatchetVersions
      bob = initSndRatchet vs (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet vs pkAlice2 paramsAlice PQSupportOff
  pure (alice, bob, encrypt' noSndKEM, decrypt' noRcvKEM, (\#>))

initRatchetsKEMProposed :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a)
initRatchetsKEMProposed = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams g v PQSupportOff
  -- propose KEM in reply
  let useKem = AUseKEM SRKSProposed ProposeKEM
  (pkBob1, pkBob2, pKemParams_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemParams_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let vs = testRatchetVersions
      bob = initSndRatchet vs (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet vs pkAlice2 paramsAlice PQSupportOn
  pure (alice, bob, encrypt' hasSndKEM, decrypt' hasRcvKEM, (!#>))

initRatchetsKEMAccepted :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a)
initRatchetsKEMAccepted = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (propose)
  (pkAlice1, pkAlice2, pKem_@(Just _), e2eAlice) <- liftIO $ generateRcvE2EParams g v PQSupportOn
  E2ERatchetParams _ _ _ (Just (RKParamsProposed aliceKem)) <- pure e2eAlice
  -- accept
  let useKem = AUseKEM SRKSAccepted (AcceptKEM aliceKem)
  (pkBob1, pkBob2, pKemParams_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemParams_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 pKem_ e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let vs = testRatchetVersions
      bob = initSndRatchet vs (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet vs pkAlice2 paramsAlice PQSupportOn
  pure (alice, bob, encrypt' hasSndKEM, decrypt' hasRcvKEM, (!#>))

initRatchetsKEMProposedAgain :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a, Encrypt a, Decrypt a, EncryptDecryptSpec a)
initRatchetsKEMProposedAgain = do
  g <- C.newRandom
  let v = max pqRatchetE2EEncryptVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, pKem_@(Just _), e2eAlice) <- liftIO $ generateRcvE2EParams g v PQSupportOn
  -- propose KEM again in reply
  let useKem = AUseKEM SRKSProposed ProposeKEM
  (pkBob1, pkBob2, pKemParams_@(Just _), AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 pKemParams_ e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 pKem_ e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let vs = testRatchetVersions
      bob = initSndRatchet vs (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet vs pkAlice2 paramsAlice PQSupportOn
  pure (alice, bob, encrypt' hasSndKEM, decrypt' hasRcvKEM, (!#>))

testRatchetVersions :: RatchetVersions
testRatchetVersions =
  let v = maxVersion supportedE2EEncryptVRange
   in RatchetVersions v v

encrypt_ :: AlgorithmI a => Maybe PQEncryption -> (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (ByteString, Ratchet a, SkippedMsgDiff))
encrypt_ pqEnc_ (_, rc, _) msg =
  -- print msg >>
  runExceptT encrypt
    >>= either (pure . Left) checkLength
  where
    encrypt = do
      (mek, rc') <- rcEncryptHeader rc pqEnc_ currentE2EEncryptVersion
      msg' <- rcEncryptMsg mek paddedMsgLen msg
      pure (msg', rc')
    checkLength (msg', rc') = do
      B.length msg' `shouldBe` fullMsgLen rc'
      pure $ Right (msg', rc', SMDNoChange)

decrypt_ :: (AlgorithmI a, DhAlgorithm a) => (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either CryptoError (Either CryptoError ByteString, Ratchet a, SkippedMsgDiff))
decrypt_ (g, rc, smks) msg = runExceptT $ rcDecrypt g rc smks msg

encrypt' :: AlgorithmI a => (Ratchet a -> ()) -> Encrypt a
encrypt' = withTVar $ encrypt_ Nothing

decrypt' :: (AlgorithmI a, DhAlgorithm a) => (Ratchet a -> ()) -> Decrypt a
decrypt' = withTVar decrypt_

noSndKEM :: Ratchet a -> ()
noSndKEM Ratchet {rcSndKEM = PQEncOn} = error "snd ratchet has KEM"
noSndKEM _ = ()

noRcvKEM :: Ratchet a -> ()
noRcvKEM Ratchet {rcRcvKEM = PQEncOn} = error "rcv ratchet has KEM"
noRcvKEM _ = ()

hasSndKEM :: Ratchet a -> ()
hasSndKEM Ratchet {rcSndKEM = PQEncOn} = ()
hasSndKEM _ = error "snd ratchet has no KEM"

hasRcvKEM :: Ratchet a -> ()
hasRcvKEM Ratchet {rcRcvKEM = PQEncOn} = ()
hasRcvKEM _ = error "rcv ratchet has no KEM"

withTVar ::
  AlgorithmI a =>
  ((TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> ByteString -> IO (Either e (r, Ratchet a, SkippedMsgDiff))) ->
  (Ratchet a -> ()) ->
  TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) ->
  ByteString ->
  IO (Either e r)
withTVar op valid rcVar msg = do
  (g, rc, smks) <- readTVarIO rcVar
  applyDiff smks <$$> (testEncodeDecode rc >> op (g, rc, smks) msg)
    >>= \case
      Right (res, rc', smks') -> valid rc' `seq` atomically (writeTVar rcVar (g, rc', smks')) >> pure (Right res)
      Left e -> pure $ Left e
  where
    applyDiff smks (res, rc', smDiff) = (res, rc', applySMDiff smks smDiff)
