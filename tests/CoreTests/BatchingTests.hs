{-# LANGUAGE LambdaCase #-}

module CoreTests.BatchingTests (batchingTests) where

import Control.Concurrent.STM
import Control.Monad
import Crypto.Random (MonadRandom (..))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.List.NonEmpty as L
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (VersionRange (..))
import Test.Hspec

batchingTests :: Spec
batchingTests = do
  describe "batchTransmissions" $ do
    it "should batch with 90 subscriptions per batch" testBatchSubscriptions
    it "should break on message that does not fit" testBatchWithMessage
    it "should break on large message" testBatchWithLargeMessage
  describe "batchClientTransmissions" $ do
    it "should batch with 90 subscriptions per batch" testClientBatchSubscriptions
    it "should break on message that does not fit" testClientBatchWithMessage
    it "should break on large message" testClientBatchWithLargeMessage

testBatchSubscriptions :: IO ()
testBatchSubscriptions = do
  sessId <- getRandomBytes 32
  subs <- replicateM 200 $ randomSUB sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 200
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions n1 s1, TBTransmissions n2 s2, TBTransmissions n3 s3] <- pure batches
  (n1, n2, n3) `shouldBe` (90, 90, 20)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithMessage :: IO ()
testBatchWithMessage = do
  sessId <- getRandomBytes 32
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 8000
  subs2 <- replicateM 40 $ randomSUB sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions n1 s1, TBTransmissions n2 s2] <- pure batches
  (n1, n2) `shouldBe` (60, 41)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithLargeMessage :: IO ()
testBatchWithLargeMessage = do
  sessId <- getRandomBytes 32
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
  [TBTransmissions n1 s1, TBLargeTransmission, TBTransmissions n2 s2, TBTransmissions n3 s3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 90, 10)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptions :: IO ()
testClientBatchSubscriptions = do
  sessId <- getRandomBytes 32
  client <- atomically $ clientStub sessId
  subs <- replicateM 200 $ randomSUBCmd client
  let batches1 = batchClientTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1' batches1 `shouldBe` True
  let batches = batchClientTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [CBTransmissions s1 n1 rs1, CBTransmissions s2 n2 rs2, CBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (90, 90, 20)
  (length rs1, length rs2, length rs3) `shouldBe` (90, 90, 20)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchWithMessage :: IO ()
testClientBatchWithMessage = do
  sessId <- getRandomBytes 32
  client <- atomically $ clientStub sessId
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 8000
  subs2 <- replicateM 40 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchClientTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1' batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchClientTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [CBTransmissions s1 n1 rs1, CBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (60, 41)
  (length rs1, length rs2) `shouldBe` (60, 41)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithLargeMessage :: IO ()
testClientBatchWithLargeMessage = do
  sessId <- getRandomBytes 32
  client <- atomically $ clientStub sessId
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 17000
  subs2 <- replicateM 100 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchClientTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1' batches1 `shouldBe` False
  length batches1 `shouldBe` 161
  let batches1' = take 60 batches1 <> drop 61 batches1
  all lenOk1' batches1' `shouldBe` True
  length batches1' `shouldBe` 160
  --
  let batches = batchClientTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [CBTransmissions s1 n1 rs1, CBLargeTransmission _, CBTransmissions s2 n2 rs2, CBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 90, 10)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 90, 10)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchClientTransmissions True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [CBLargeTransmission _, CBTransmissions s1' n1' rs1', CBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (90, 70)
  (length rs1', length rs2') `shouldBe` (90, 70)
  all lenOk [s1', s2'] `shouldBe` True

randomSUB :: ByteString -> IO (Maybe C.ASignature, ByteString)
randomSUB sessId = do
  rId <- getRandomBytes 24
  corrId <- CorrId <$> getRandomBytes 3
  (_, rpKey) <- C.generateSignatureKeyPair C.SEd448
  let s = encodeTransmission (maxVersion supportedSMPServerVRange) sessId (corrId, rId, Cmd SRecipient SUB)
  pure (Just $ C.sign rpKey s, s)

randomSUBCmd :: ProtocolClient ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd c = do
  rId <- getRandomBytes 24
  (_, rpKey) <- C.generateSignatureKeyPair C.SEd448
  mkTransmission c (Just rpKey, rId, Cmd SRecipient SUB)

randomSEND :: ByteString -> Int -> IO (Maybe C.ASignature, ByteString)
randomSEND sessId len = do
  sId <- getRandomBytes 24
  corrId <- CorrId <$> getRandomBytes 3
  (_, rpKey) <- C.generateSignatureKeyPair C.SEd448
  msg <- getRandomBytes len
  let s = encodeTransmission (maxVersion supportedSMPServerVRange) sessId (corrId, sId, Cmd SSender $ SEND noMsgFlags msg)
  pure (Just $ C.sign rpKey s, s)

randomSENDCmd :: ProtocolClient ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd c len = do
  sId <- getRandomBytes 24
  (_, rpKey) <- C.generateSignatureKeyPair C.SEd448
  msg <- getRandomBytes len
  mkTransmission c (Just rpKey, sId, Cmd SSender $ SEND noMsgFlags msg)

lenOk :: ByteString -> Bool
lenOk s = 0 < B.length s && B.length s <= smpBlockSize - 2

lenOk1 :: TransportBatch -> Bool
lenOk1 = \case
  TBTransmission s -> lenOk s
  _ -> False

lenOk1' :: ClientBatch err msg -> Bool
lenOk1' = \case
  CBTransmission s _ -> lenOk s
  _ -> False
