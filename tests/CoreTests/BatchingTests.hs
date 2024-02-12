{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module CoreTests.BatchingTests (batchingTests) where

import Control.Concurrent.STM
import Control.Monad
import Crypto.Random (ChaChaDRG)
import qualified Crypto.Store.X509 as SX
import qualified Data.ByteString as B
import Data.ByteString.Char8 (ByteString)
import qualified Data.List.NonEmpty as L
import qualified Data.X509 as X
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (Version)
import Test.Hspec

batchingTests :: Spec
batchingTests = do
  describe "batchTransmissions" $ do
    describe "SMP v7 (current)" $ do
      it "should batch with 109 subscriptions per batch" $ testBatchSubscriptions
      it "should break on message that does not fit" testBatchWithMessage
      it "should break on large message" testBatchWithLargeMessage
    describe "v8 (next)" $ do
      it "should batch with 142 subscriptions per batch" testBatchSubscriptionsV8
      it "should break on message that does not fit" testBatchWithMessageV8
      it "should break on large message" testBatchWithLargeMessageV8
  describe "batchTransmissions'" $ do
    describe "SMP v7 (current)" $ do
      it "should batch with 109 subscriptions per batch" testClientBatchSubscriptions
      it "should break on message that does not fit" testClientBatchWithMessage
      it "should break on large message" testClientBatchWithLargeMessage
    describe "v8 (next)" $ do
      it "should batch with 142 subscriptions per batch" testClientBatchSubscriptionsV8
      it "should break on message that does not fit" testClientBatchWithMessageV8
      it "should break on large message" testClientBatchWithLargeMessageV8

testBatchSubscriptions :: IO ()
testBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 250 $ randomSUB sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 250
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (32, 109, 109)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchSubscriptionsV8 :: IO ()
testBatchSubscriptionsV8 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 300 $ randomSUBv8 sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 300
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (16, 142, 142)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithMessage :: IO ()
testBatchWithMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 8000
  subs2 <- replicateM 40 $ randomSUB sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _] <- pure batches
  (n1, n2) `shouldBe` (45, 56)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithMessageV8 :: IO ()
testBatchWithMessageV8 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUBv8 sessId
  send <- randomSENDv8 sessId 8000
  subs2 <- replicateM 40 $ randomSUBv8 sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _] <- pure batches
  (n1, n2) `shouldBe` (29, 72)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithLargeMessage :: IO ()
testBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 17000
  subs2 <- replicateM 120 $ randomSUB sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 181
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 180
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 _, TBError TELargeMsg _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 11, 109)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithLargeMessageV8 :: IO ()
testBatchWithLargeMessageV8 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUBv8 sessId
  send <- randomSENDv8 sessId 17000
  subs2 <- replicateM 150 $ randomSUBv8 sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 211
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 210
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 _, TBError TELargeMsg _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 8, 142)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptions :: IO ()
testClientBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing Nothing
  subs <- replicateM 250 $ randomSUBCmd client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (31, 110, 109)
  (length rs1, length rs2, length rs3) `shouldBe` (31, 110, 109)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptionsV8 :: IO ()
testClientBatchSubscriptionsV8 = do
  client <- clientStubV8
  subs <- replicateM 300 $ randomSUBCmdV8 client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (16, 142, 142)
  (length rs1, length rs2, length rs3) `shouldBe` (16, 142, 142)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchWithMessage :: IO ()
testClientBatchWithMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing Nothing
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 8000
  subs2 <- replicateM 40 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (45, 56)
  (length rs1, length rs2) `shouldBe` (45, 56)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithMessageV8 :: IO ()
testClientBatchWithMessageV8 = do
  client <- clientStubV8
  subs1 <- replicateM 60 $ randomSUBCmdV8 client
  send <- randomSENDCmdV8 client 8000
  subs2 <- replicateM 40 $ randomSUBCmdV8 client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (28, 73)
  (length rs1, length rs2) `shouldBe` (28, 73)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithLargeMessage :: IO ()
testClientBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing Nothing
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 17000
  subs2 <- replicateM 120 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 181
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 180
  --
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 rs1, TBError TELargeMsg _, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 11, 109)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 11, 109)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (71, 109)
  (length rs1', length rs2') `shouldBe` (71, 109)
  all lenOk [s1', s2'] `shouldBe` True

testClientBatchWithLargeMessageV8 :: IO ()
testClientBatchWithLargeMessageV8 = do
  client <- clientStubV8
  subs1 <- replicateM 60 $ randomSUBCmdV8 client
  send <- randomSENDCmdV8 client 17000
  subs2 <- replicateM 150 $ randomSUBCmdV8 client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 211
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 210
  --
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 rs1, TBError TELargeMsg _, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 8, 142)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 8, 142)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (68, 142)
  (length rs1', length rs2') `shouldBe` (68, 142)
  all lenOk [s1', s2'] `shouldBe` True

clientStubV8 :: IO (ProtocolClient ErrorType BrokerMsg)
clientStubV8 = do
  g <- C.newRandom
  sessId <- atomically $ C.randomBytes 32 g
  (rKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  caCrt <- SX.readSignedObject "tests/fixtures/ca.crt"
  serverCrt <- SX.readSignedObject "tests/fixtures/server.crt"
  let thServerCerts_ = Just $ X.CertificateChain (serverCrt <> caCrt)
  thAuth_ <- testTHandleAuth authEncryptCmdsSMPVersion g rKey
  atomically $ clientStub sessId authEncryptCmdsSMPVersion thServerCerts_ thAuth_

randomSUB :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB = randomSUB_ C.SEd448 currentClientSMPRelayVersion

randomSUBv8 :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUBv8 = randomSUB_ C.SX25519 authEncryptCmdsSMPVersion

randomSUB_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> Version -> ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB_ a v sessId = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  corrId <- atomically $ CorrId <$> C.randomBytes 3 g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g rKey
  let thParams = testTHandleParams v sessId
      ClntTransmission {tForAuth, tToSend} = encodeClntTransmission thParams (corrId, rId, Cmd SRecipient SUB)
  pure $ (,tToSend) <$> authTransmission thAuth_ (Just rpKey) corrId tForAuth

randomSUBCmd :: ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd = randomSUBCmd_ C.SEd448

randomSUBCmdV8 :: ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmdV8 = randomSUBCmd_ C.SX25519

randomSUBCmd_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd_ a c = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair a g
  mkTransmission c (Just rpKey, rId, Cmd SRecipient SUB)

randomSEND :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND = randomSEND_ C.SEd448 currentClientSMPRelayVersion

randomSENDv8 :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSENDv8 = randomSEND_ C.SX25519 authEncryptCmdsSMPVersion

randomSEND_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> Version -> ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND_ a v sessId len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  corrId <- atomically $ CorrId <$> C.randomBytes 3 g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g rKey
  msg <- atomically $ C.randomBytes len g
  let thParams = testTHandleParams v sessId
      ClntTransmission {tForAuth, tToSend} = encodeClntTransmission thParams (corrId, sId, Cmd SSender $ SEND noMsgFlags msg)
  pure $ (,tToSend) <$> authTransmission thAuth_ (Just rpKey) corrId tForAuth

testTHandleParams :: Version -> ByteString -> THandleParams
testTHandleParams v sessionId =
  THandleParams
    { sessionId,
      blockSize = smpBlockSize,
      thVersion = v,
      thAuth = Nothing,
      encrypt = v >= dontSendSessionIdSMPVersion,
      batch = True
    }

testTHandleAuth :: Version -> TVar ChaChaDRG -> C.APublicAuthKey -> IO (Maybe THandleAuth)
testTHandleAuth v g (C.APublicAuthKey a k) = case a of
  C.SX25519 | v >= authEncryptCmdsSMPVersion -> do
    (_, pk) <- atomically $ C.generateKeyPair g
    pure $ Just THandleAuth {peerPubKey = k, privKey = pk, dhSecret = C.dh' k pk}
  _ -> pure Nothing

randomSENDCmd :: ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd = randomSENDCmd_ C.SEd448

randomSENDCmdV8 :: ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmdV8 = randomSENDCmd_ C.SX25519

randomSENDCmd_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd_ a c len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair a g
  msg <- atomically $ C.randomBytes len g
  mkTransmission c (Just rpKey, sId, Cmd SSender $ SEND noMsgFlags msg)

lenOk :: ByteString -> Bool
lenOk s = 0 < B.length s && B.length s <= smpBlockSize - 2

lenOk1 :: TransportBatch r -> Bool
lenOk1 = \case
  TBTransmission s _ -> lenOk s
  _ -> False
