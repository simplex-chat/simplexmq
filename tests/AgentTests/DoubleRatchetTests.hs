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
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON, ToJSON)
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
  fdescribe "double-ratchet encryption/decryption" $ do
    it "should serialize and parse message header" $ do
      testAlgs $ testMessageHeader kdfX3DHE2EEncryptVersion
      testAlgs $ testMessageHeader $ max pqRatchetVersion currentE2EEncryptVersion
    describe "message tests" $ runMessageTests initRatchets
    it "should encode/decode ratchet as JSON" $ do
      testAlgs testKeyJSON
      testAlgs testRatchetJSON
    it "should agree the same ratchet parameters" $ testAlgs testX3dh
    it "should agree the same ratchet parameters with version 1" $ testAlgs testX3dhV1
  fdescribe "post-quantum hybrid KEM double-ratchet algorithm" $ do
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
      describe "message tests, KEM proposed" $ runMessageTests initRatchetsKEMProposed
      describe "message tests, KEM accepted" $ runMessageTests initRatchetsKEMAccepted
      describe "message tests, KEM proposed again in reply" $ runMessageTests initRatchetsKEMProposedAgain

runMessageTests :: (forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)) -> Spec
runMessageTests initRatchets_ = do
  it "should encrypt and decrypt messages" $ run testEncryptDecrypt
  it "should encrypt and decrypt skipped messages" $ run testSkippedMessages
  it "should encrypt and decrypt many messages" $ run testManyMessages
  it "should allow skipped after ratchet advance" $ run testSkippedAfterRatchetAdvance
  where
    run :: (forall a. TestRatchets a) -> IO ()
    run test = do
      withRatchets_ @X25519 initRatchets_ test
      withRatchets_ @X448 initRatchets_ test


testAlgs :: (forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()) -> IO ()
testAlgs test = test C.SX25519 >> test C.SX448

paddedMsgLen :: Int
paddedMsgLen = 100

fullMsgLen :: Version -> Int
fullMsgLen v = headerLenLength + fullHeaderLen + C.authTagSize + paddedMsgLen
  where
    headerLenLength = if v < pqRatchetVersion then 1 else 3 -- two bytes are added because of two Large used in new encoding

testMessageHeader :: forall a. AlgorithmI a => Version -> C.SAlgorithm a -> Expectation
testMessageHeader v _ = do
  (k, _) <- atomically . C.generateKeyPair @a =<< C.newRandom
  let hdr = MsgHeader {msgMaxVersion = v, msgDHRs = k, msgKEM = Nothing, msgPN = 0, msgNs = 0}
  parseAll (smpP @(MsgHeader a)) (smpEncode hdr) `shouldBe` Right hdr

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
  let msgMaxVersion = max pqRatchetVersion currentE2EEncryptVersion
      msgKEM = Just . ARKP SRKSProposed $ RKParamsProposed kem
      hdr = MsgHeader {msgMaxVersion, msgDHRs = k, msgKEM, msgPN = 0, msgNs = 0}
  parseAll (smpP @(MsgHeader a)) (smpEncode hdr) `shouldBe` Right hdr
  (kem', _) <- sntrup761Keypair g
  (ct, _) <- sntrup761Enc g kem
  let msgKEM' = Just . ARKP SRKSAccepted $ RKParamsAccepted ct kem'
      hdr' = MsgHeader {msgMaxVersion, msgDHRs = k, msgKEM = msgKEM', msgPN = 0, msgNs = 0}
  parseAll (smpP @(MsgHeader a)) (smpEncode hdr') `shouldBe` Right hdr'

pattern Decrypted :: ByteString -> Either CryptoError (Either CryptoError ByteString)
pattern Decrypted msg <- Right (Right msg)

type TestRatchets a = (AlgorithmI a, DhAlgorithm a) => TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> IO ()

deriving instance Eq (Ratchet a)

deriving instance Eq (SndRatchet a)

deriving instance Eq RcvRatchet

deriving instance Eq RatchetKEM

deriving instance Eq RatchetKEMAccepted

deriving instance Eq RatchetInitParams

deriving instance Eq RatchetKey

deriving instance Eq (RKEMParams s)

instance Eq ARKEMParams where
  (ARKP s ps) == (ARKP s' ps') = case testEquality s s' of
    Just Refl -> ps == ps'
    Nothing -> False

deriving instance Eq (MsgHeader a)

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

testEncodeDecode :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
testEncodeDecode x = do
  let j = J.encode x
      x' = J.eitherDecode' j
  x' `shouldBe` Right x

testX3dh :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dh _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v Nothing
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v Nothing
  let paramsBob = pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `shouldBe` paramsBob

testX3dhV1 :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testX3dhV1 _ = do
  g <- C.newRandom
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g 1 Nothing
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g 1 Nothing
  let paramsBob = pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `shouldBe` paramsBob

testPqX3dhProposeInReply :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeInReply _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v Nothing
  -- propose KEM in reply
  (pkBob1, pkBob2, Just pKemBob, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSProposed ProposeKEM)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemBob) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhProposeAccept :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeAccept _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, Just pKemAlice, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v (Just ProposeKEM)
  E2ERatchetParams _ _ _ (Just (RKParamsProposed aliceKem)) <- pure e2eAlice
  -- accept KEM
  (pkBob1, pkBob2, Just pKemBob, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSAccepted $ AcceptKEM aliceKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemBob) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 (Just pKemAlice) e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhProposeReject :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeReject _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, Just pKemAlice, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v (Just ProposeKEM)
  E2ERatchetParams _ _ _ (Just (RKParamsProposed _)) <- pure e2eAlice
  -- reject KEM
  (pkBob1, pkBob2, Nothing, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v Nothing
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 (Just pKemAlice) e2eBob
  paramsAlice `compatibleRatchets` paramsBob

testPqX3dhAcceptWithoutProposalError :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhAcceptWithoutProposalError _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v Nothing
  E2ERatchetParams _ _ _ Nothing <- pure e2eAlice
  -- incorrectly accept KEM
  -- we don't have key in proposal, so we just generate it
  (k, _) <- sntrup761Keypair g
  (pkBob1, pkBob2, Just pKemBob, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSAccepted $ AcceptKEM k)
  pqX3dhSnd pkBob1 pkBob2 (Just pKemBob) e2eAlice `shouldBe` Left C.CERatchetKEMState
  runExceptT (pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob) `shouldReturn` Left C.CERatchetKEMState

testPqX3dhProposeAgain :: forall a. (AlgorithmI a, DhAlgorithm a) => C.SAlgorithm a -> IO ()
testPqX3dhProposeAgain _ = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, Just pKemAlice, e2eAlice) <- liftIO $ generateRcvE2EParams @a g v (Just ProposeKEM)
  E2ERatchetParams _ _ _ (Just (RKParamsProposed _)) <- pure e2eAlice
  -- propose KEM again in reply - this is not an error
  (pkBob1, pkBob2, Just pKemBob, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams @a g v (Just $ AUseKEM SRKSProposed ProposeKEM)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemBob) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 (Just pKemAlice) e2eBob
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

(#>) :: (AlgorithmI a, DhAlgorithm a) => (TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys), ByteString) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> Expectation
(alice, msg) #> bob = do
  Right msg' <- encrypt alice msg
  Decrypted msg'' <- decrypt bob msg'
  msg'' `shouldBe` msg

withRatchets_ :: IO (Ratchet a, Ratchet a) -> (TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> TVar (TVar ChaChaDRG, Ratchet a, SkippedMsgKeys) -> IO ()) -> Expectation
withRatchets_ initRatchets_ test = do
  ga <- C.newRandom
  gb <- C.newRandom
  (a, b) <- initRatchets_
  alice <- newTVarIO (ga, a, M.empty)
  bob <- newTVarIO (gb, b, M.empty)
  test alice bob `shouldReturn` ()

initRatchets :: (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchets = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  (pkBob1, pkBob2, _pKemParams, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v Nothing
  (pkAlice1, pkAlice2, _pKem, e2eAlice) <- liftIO $ generateRcvE2EParams g v Nothing
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 Nothing e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let bob = initSndRatchet supportedE2EEncryptVRange (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet supportedE2EEncryptVRange pkAlice2 paramsAlice
  pure (alice, bob)

initRatchetsKEMProposed :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchetsKEMProposed = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (no KEM)
  (pkAlice1, pkAlice2, Nothing, e2eAlice) <- liftIO $ generateRcvE2EParams g v Nothing
  -- propose KEM in reply
  let useKem = AUseKEM SRKSProposed ProposeKEM
  (pkBob1, pkBob2, Just pKemParams, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemParams) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 Nothing e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let bob = initSndRatchet supportedE2EEncryptVRange (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet supportedE2EEncryptVRange pkAlice2 paramsAlice
  pure (alice, bob)

initRatchetsKEMAccepted :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchetsKEMAccepted = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (propose)
  (pkAlice1, pkAlice2, Just pKem, e2eAlice) <- liftIO $ generateRcvE2EParams g v (Just ProposeKEM)
  E2ERatchetParams _ _ _ (Just (RKParamsProposed aliceKem)) <- pure e2eAlice
  -- accept
  let useKem = AUseKEM SRKSAccepted (AcceptKEM aliceKem)
  (pkBob1, pkBob2, Just pKemParams, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemParams) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 (Just pKem) e2eBob
  (_, pkBob3) <- atomically $ C.generateKeyPair g
  let bob = initSndRatchet supportedE2EEncryptVRange (C.publicKey pkAlice2) pkBob3 paramsBob
      alice = initRcvRatchet supportedE2EEncryptVRange pkAlice2 paramsAlice
  pure (alice, bob)

initRatchetsKEMProposedAgain :: forall a. (AlgorithmI a, DhAlgorithm a) => IO (Ratchet a, Ratchet a)
initRatchetsKEMProposedAgain = do
  g <- C.newRandom
  let v = max pqRatchetVersion currentE2EEncryptVersion
  -- initiate (propose KEM)
  (pkAlice1, pkAlice2, Just pKem, e2eAlice) <- liftIO $ generateRcvE2EParams g v (Just ProposeKEM)
  -- propose KEM again in reply
  let useKem = AUseKEM SRKSProposed ProposeKEM
  (pkBob1, pkBob2, Just pKemParams, AE2ERatchetParams _ e2eBob) <- liftIO $ generateSndE2EParams g v (Just useKem)
  Right paramsBob <- pure $ pqX3dhSnd pkBob1 pkBob2 (Just pKemParams) e2eAlice
  Right paramsAlice <- runExceptT $ pqX3dhRcv pkAlice1 pkAlice2 (Just pKem) e2eBob
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
      B.length msg' `shouldBe` fullMsgLen (maxVersion $ rcVersion rc)
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
