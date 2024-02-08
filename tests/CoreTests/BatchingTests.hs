{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

module CoreTests.BatchingTests (batchingTests) where

import Control.Concurrent.STM
import Control.Monad
import Crypto.Random (ChaChaDRG)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString as B
import qualified Data.List.NonEmpty as L
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (Version)
import Test.Hspec

batchingTests :: Spec
batchingTests = do
  describe "batchTransmissions" $ do
    describe "SMP v6 (current)" $ do
      it "should batch with 90 subscriptions per batch" $ testBatchSubscriptions
      it "should break on message that does not fit" testBatchWithMessage
      it "should break on large message" testBatchWithLargeMessage
    describe "v7 (next)" $ do
      it "should batch with 110 subscriptions per batch" testBatchSubscriptionsV7
      it "should break on message that does not fit" testBatchWithMessageV7
      it "should break on large message" testBatchWithLargeMessageV7
  describe "batchTransmissions'" $ do
    describe "SMP v6 (current)" $ do
      it "should batch with 90 subscriptions per batch" testClientBatchSubscriptions
      it "should break on message that does not fit" testClientBatchWithMessage
      it "should break on large message" testClientBatchWithLargeMessage
    describe "v7 (next)" $ do
      it "should batch with 110 subscriptions per batch" testClientBatchSubscriptionsV7
      it "should break on message that does not fit" testClientBatchWithMessageV7
      it "should break on large message" testClientBatchWithLargeMessageV7

testBatchSubscriptions :: IO ()
testBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 200 $ randomSUB sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 200
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (20, 90, 90)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchSubscriptionsV7 :: IO ()
testBatchSubscriptionsV7 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 250 $ randomSUBv7 sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 250
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (30, 110, 110)
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
  (n1, n2) `shouldBe` (55, 46)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithMessageV7 :: IO ()
testBatchWithMessageV7 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUBv7 sessId
  send <- randomSENDv7 sessId 8000
  subs2 <- replicateM 40 $ randomSUBv7 sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _] <- pure batches
  (n1, n2) `shouldBe` (45, 56)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithLargeMessage :: IO ()
testBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 17000
  subs2 <- replicateM 100 $ randomSUB sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 161
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 160
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 _, TBError TELargeMsg _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 10, 90)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithLargeMessageV7 :: IO ()
testBatchWithLargeMessageV7 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUBv7 sessId
  send <- randomSENDv7 sessId 17000
  subs2 <- replicateM 120 $ randomSUBv7 sessId
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
  (n1, n2, n3) `shouldBe` (60, 10, 110)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptions :: IO ()
testClientBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing
  subs <- replicateM 200 $ randomSUBCmd client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (20, 90, 90)
  (length rs1, length rs2, length rs3) `shouldBe` (20, 90, 90)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptionsV7 :: IO ()
testClientBatchSubscriptionsV7 = do
  client <- clientStubV7
  subs <- replicateM 250 $ randomSUBCmdV7 client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (30, 110, 110)
  (length rs1, length rs2, length rs3) `shouldBe` (30, 110, 110)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchWithMessage :: IO ()
testClientBatchWithMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing
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
  (n1, n2) `shouldBe` (55, 46)
  (length rs1, length rs2) `shouldBe` (55, 46)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithMessageV7 :: IO ()
testClientBatchWithMessageV7 = do
  client <- clientStubV7
  subs1 <- replicateM 60 $ randomSUBCmdV7 client
  send <- randomSENDCmdV7 client 8000
  subs2 <- replicateM 40 $ randomSUBCmdV7 client
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

testClientBatchWithLargeMessage :: IO ()
testClientBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  client <- atomically $ clientStub sessId currentClientSMPRelayVersion Nothing
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 17000
  subs2 <- replicateM 100 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 161
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 160
  --
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 rs1, TBError TELargeMsg _, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 10, 90)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 10, 90)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (70, 90)
  (length rs1', length rs2') `shouldBe` (70, 90)
  all lenOk [s1', s2'] `shouldBe` True

testClientBatchWithLargeMessageV7 :: IO ()
testClientBatchWithLargeMessageV7 = do
  client <- clientStubV7
  subs1 <- replicateM 60 $ randomSUBCmdV7 client
  send <- randomSENDCmdV7 client 17000
  subs2 <- replicateM 120 $ randomSUBCmdV7 client
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
  (n1, n2, n3) `shouldBe` (60, 10, 110)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 10, 110)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (70, 110)
  (length rs1', length rs2') `shouldBe` (70, 110)
  all lenOk [s1', s2'] `shouldBe` True

clientStubV7 :: IO (ProtocolClient ErrorType BrokerMsg)
clientStubV7 = do
  g <- C.newRandom
  sessId <- atomically $ C.randomBytes 32 g
  (rKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  thAuth_ <- testTHandleAuth authEncryptCmdsSMPVersion g rKey
  atomically $ clientStub sessId authEncryptCmdsSMPVersion thAuth_

randomSUB :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB = randomSUB_ currentClientSMPRelayVersion C.SEd448

randomSUBv7 :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUBv7 = randomSUB_ authEncryptCmdsSMPVersion C.SX25519

randomSUB_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => Version -> C.SAlgorithm a -> ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB_ v a sessId = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  corrId <- atomically $ CorrId <$> C.randomBytes 3 g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g rKey
  pure $ authTransmission thAuth_ (Just rpKey) corrId $ encodeTransmission v sessId (corrId, rId, Cmd SRecipient SUB)

randomSUBCmd :: ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd = randomSUBCmd_ C.SEd448

randomSUBCmdV7 :: ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmdV7 = randomSUBCmd_ C.SX25519

randomSUBCmd_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd_ a c = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair a g
  mkTransmission c (Just rpKey, rId, Cmd SRecipient SUB)

randomSEND :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND = randomSEND_ currentClientSMPRelayVersion C.SEd448

randomSENDv7 :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSENDv7 = randomSEND_ authEncryptCmdsSMPVersion C.SX25519

randomSEND_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => Version -> C.SAlgorithm a -> ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND_ v a sessId len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  corrId <- atomically $ CorrId <$> C.randomBytes 3 g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g rKey
  msg <- atomically $ C.randomBytes len g
  pure $ authTransmission thAuth_ (Just rpKey) corrId $ encodeTransmission v sessId (corrId, sId, Cmd SSender $ SEND noMsgFlags msg)

testTHandleAuth :: Version -> TVar ChaChaDRG -> C.APublicAuthKey -> IO (Maybe THandleAuth)
testTHandleAuth v g (C.APublicAuthKey a k) = case a of
  C.SX25519 | v >= authEncryptCmdsSMPVersion -> do
    (_, pk) <- atomically $ C.generateKeyPair g
    pure $ Just THandleAuth {peerPubKey = k, privKey = pk, dhSecret = C.dh' k pk}
  _ -> pure Nothing

randomSENDCmd :: ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd = randomSENDCmd_ C.SEd448

randomSENDCmdV7 :: ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmdV7 = randomSENDCmd_ C.SX25519

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
