{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.BatchingTests (batchingTests) where

import Control.Concurrent.STM
import Control.Monad
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString as B
import Data.ByteString.Char8 (ByteString)
import qualified Data.List.NonEmpty as L
import Data.Time.Clock.System (SystemTime, getSystemTime)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.File as XF
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Test.Hspec

batchingTests :: Spec
batchingTests = do
  describe "batchTransmissions" $ do
    describe "SMP v6 (previous)" $ do
      it "should batch with 107 subscriptions per batch" testBatchSubscriptionsV6
      it "should break on message that does not fit" testBatchWithMessageV6
      it "should break on large message" testBatchWithLargeMessageV6
    describe "SMP current" $ do
      it "should batch with 136 subscriptions per batch" testBatchSubscriptions
      it "should break on message that does not fit" testBatchWithMessage
      it "should break on large message" testBatchWithLargeMessage
  describe "batchTransmissions'" $ do
    describe "SMP v6 (previous)" $ do
      it "should batch with 107 subscriptions per batch" testClientBatchSubscriptionsV6
      it "should break on message that does not fit" testClientBatchWithMessageV6
      it "should break on large message" testClientBatchWithLargeMessageV6
    describe "SMP current" $ do
      it "should batch with 136 subscriptions per batch" testClientBatchSubscriptions
      it "should batch with 255 ENDs per batch" testClientBatchENDs
      it "should batch with 80 NMSGs per batch" testClientBatchNMSGs
      it "should break on message that does not fit" testClientBatchWithMessage
      it "should break on large message" testClientBatchWithLargeMessage

testBatchSubscriptionsV6 :: IO ()
testBatchSubscriptionsV6 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 250 $ randomSUBv6 sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 250
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (36, 107, 107)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchSubscriptions :: IO ()
testBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 300 $ randomSUB sessId
  let batches1 = batchTransmissions False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 300
  let batches = batchTransmissions True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (28, 136, 136)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithMessageV6 :: IO ()
testBatchWithMessageV6 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUBv6 sessId
  send <- randomSENDv6 sessId 8000
  subs2 <- replicateM 40 $ randomSUBv6 sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _] <- pure batches
  (n1, n2) `shouldBe` (47, 54)
  all lenOk [s1, s2] `shouldBe` True

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
  (n1, n2) `shouldBe` (32, 69)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithLargeMessageV6 :: IO ()
testBatchWithLargeMessageV6 = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 50 $ randomSUBv6 sessId
  send <- randomSENDv6 sessId 17000
  subs2 <- replicateM 150 $ randomSUBv6 sessId
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 201
  let batches1' = take 50 batches1 <> drop 51 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 200
  let batches = batchTransmissions True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 _, TBError TELargeMsg _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (50, 43, 107)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithLargeMessage :: IO ()
testBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 17000
  subs2 <- replicateM 150 $ randomSUB sessId
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
  (n1, n2, n3) `shouldBe` (60, 14, 136)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptionsV6 :: IO ()
testClientBatchSubscriptionsV6 = do
  client <- testClientStubV6
  subs <- replicateM 250 $ randomSUBCmdV6 client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (36, 107, 107)
  (length rs1, length rs2, length rs3) `shouldBe` (36, 107, 107)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptions :: IO ()
testClientBatchSubscriptions = do
  client <- testClientStub
  subs <- replicateM 300 $ randomSUBCmd client
  let batches1 = batchTransmissions' False smpBlockSize $ L.fromList subs
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions' True smpBlockSize $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (28, 136, 136)
  (length rs1, length rs2, length rs3) `shouldBe` (28, 136, 136)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchENDs :: IO ()
testClientBatchENDs = do
  client <- testClientStub
  ends <- replicateM 300 randomENDCmd
  let ends' = map (\t -> Right (Nothing, encodeTransmission (thParams client) t)) ends
      batches1 = batchTransmissions False smpBlockSize $ L.fromList ends'
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions True smpBlockSize $ L.fromList ends'
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (45, 255)
  (length rs1, length rs2) `shouldBe` (45, 255)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchNMSGs :: IO ()
testClientBatchNMSGs = do
  client <- testClientStub
  ts <- getSystemTime
  ntfs <- replicateM 200 $ randomNMSGCmd ts
  let ntfs' = map (\t -> Right (Nothing, encodeTransmission (thParams client) t)) ntfs
      batches1 = batchTransmissions False smpBlockSize $ L.fromList ntfs'
  all lenOk1 batches1 `shouldBe` True
  let batches = batchTransmissions True smpBlockSize $ L.fromList ntfs'
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (40, 80, 80)
  (length rs1, length rs2, length rs3) `shouldBe` (40, 80, 80)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchWithMessageV6 :: IO ()
testClientBatchWithMessageV6 = do
  client <- testClientStubV6
  subs1 <- replicateM 60 $ randomSUBCmdV6 client
  send <- randomSENDCmdV6 client 8000
  subs2 <- replicateM 40 $ randomSUBCmdV6 client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` True
  length batches1 `shouldBe` 101
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (47, 54)
  (length rs1, length rs2) `shouldBe` (47, 54)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithMessage :: IO ()
testClientBatchWithMessage = do
  client <- testClientStub
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
  (n1, n2) `shouldBe` (32, 69)
  (length rs1, length rs2) `shouldBe` (32, 69)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithLargeMessageV6 :: IO ()
testClientBatchWithLargeMessageV6 = do
  client <- testClientStubV6
  subs1 <- replicateM 50 $ randomSUBCmdV6 client
  send <- randomSENDCmdV6 client 17000
  subs2 <- replicateM 150 $ randomSUBCmdV6 client
  let cmds = subs1 <> [send] <> subs2
      batches1 = batchTransmissions' False smpBlockSize $ L.fromList cmds
  all lenOk1 batches1 `shouldBe` False
  length batches1 `shouldBe` 201
  let batches1' = take 50 batches1 <> drop 51 batches1
  all lenOk1 batches1' `shouldBe` True
  length batches1' `shouldBe` 200
  --
  let batches = batchTransmissions' True smpBlockSize $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 rs1, TBError TELargeMsg _, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (50, 43, 107)
  (length rs1, length rs2, length rs3) `shouldBe` (50, 43, 107)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (93, 107)
  (length rs1', length rs2') `shouldBe` (93, 107)
  all lenOk [s1', s2'] `shouldBe` True

testClientBatchWithLargeMessage :: IO ()
testClientBatchWithLargeMessage = do
  client <- testClientStub
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 17000
  subs2 <- replicateM 150 $ randomSUBCmd client
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
  (n1, n2, n3) `shouldBe` (60, 14, 136)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 14, 136)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' True smpBlockSize $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (74, 136)
  (length rs1', length rs2') `shouldBe` (74, 136)
  all lenOk [s1', s2'] `shouldBe` True

testClientStubV6 :: IO (ProtocolClient SMPVersion ErrorType BrokerMsg)
testClientStubV6 = do
  g <- C.newRandom
  sessId <- atomically $ C.randomBytes 32 g
  smpClientStub g sessId subModeSMPVersion Nothing

testClientStub :: IO (ProtocolClient SMPVersion ErrorType BrokerMsg)
testClientStub = do
  g <- C.newRandom
  sessId <- atomically $ C.randomBytes 32 g
  (rKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  thAuth_ <- testTHandleAuth currentClientSMPRelayVersion g rKey
  smpClientStub g sessId currentClientSMPRelayVersion thAuth_

randomSUBv6 :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUBv6 = randomSUB_ C.SEd25519 subModeSMPVersion

randomSUB :: ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB = randomSUB_ C.SEd25519 currentClientSMPRelayVersion

randomSUB_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> VersionSMP -> ByteString -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSUB_ a v sessId = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  nonce@(C.CbNonce corrId) <- atomically $ C.randomCbNonce g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g rKey
  let thParams = testTHandleParams v sessId
      TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams (CorrId corrId, EntityId rId, Cmd SRecipient SUB)
  pure $ (,tToSend) <$> authTransmission thAuth_ (Just rpKey) nonce tForAuth

randomSUBCmdV6 :: ProtocolClient SMPVersion ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmdV6 = randomSUBCmd_ C.SEd25519

randomSUBCmd :: ProtocolClient SMPVersion ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd = randomSUBCmd_ C.SEd25519 -- same as v6

randomSUBCmd_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> ProtocolClient SMPVersion ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd_ a c = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair a g
  mkTransmission c (Just rpKey, EntityId rId, Cmd SRecipient SUB)

randomENDCmd :: IO (Transmission BrokerMsg)
randomENDCmd = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  pure (CorrId "", EntityId rId, END)

randomNMSGCmd :: SystemTime -> IO (Transmission BrokerMsg)
randomNMSGCmd ts = do
  g <- C.newRandom
  nId <- atomically $ C.randomBytes 24 g
  msgId <- atomically $ C.randomBytes 24 g
  (k, pk) <- atomically $ C.generateKeyPair g
  nonce <- atomically $ C.randomCbNonce g
  let msgMeta = NMsgMeta {msgId, msgTs = ts}
  Right encNMsgMeta <- pure $ C.cbEncrypt (C.dh' k pk) nonce (smpEncode msgMeta) 128
  pure (CorrId "", EntityId nId, NMSG nonce encNMsgMeta)

randomSENDv6 :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSENDv6 = randomSEND_ C.SEd25519 subModeSMPVersion

randomSEND :: ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND = randomSEND_ C.SX25519 currentClientSMPRelayVersion

randomSEND_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> VersionSMP -> ByteString -> Int -> IO (Either TransportError (Maybe TransmissionAuth, ByteString))
randomSEND_ a v sessId len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  nonce@(C.CbNonce corrId) <- atomically $ C.randomCbNonce g
  (sKey, spKey) <- atomically $ C.generateAuthKeyPair a g
  thAuth_ <- testTHandleAuth v g sKey
  msg <- atomically $ C.randomBytes len g
  let thParams = testTHandleParams v sessId
      TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams (CorrId corrId, EntityId sId, Cmd SSender $ SEND noMsgFlags msg)
  pure $ (,tToSend) <$> authTransmission thAuth_ (Just spKey) nonce tForAuth

testTHandleParams :: VersionSMP -> ByteString -> THandleParams SMPVersion 'TClient
testTHandleParams v sessionId =
  THandleParams
    { sessionId,
      blockSize = smpBlockSize,
      thVersion = v,
      thServerVRange = supportedServerSMPRelayVRange,
      thAuth = Nothing,
      implySessId = v >= authCmdsSMPVersion,
      batch = True
    }

testTHandleAuth :: VersionSMP -> TVar ChaChaDRG -> C.APublicAuthKey -> IO (Maybe (THandleAuth 'TClient))
testTHandleAuth v g (C.APublicAuthKey a serverPeerPubKey) = case a of
  C.SX25519 | v >= authCmdsSMPVersion -> do
    ca <- head <$> XS.readCertificates "tests/fixtures/ca.crt"
    serverCert <- head <$> XS.readCertificates "tests/fixtures/server.crt"
    serverKey <- head <$> XF.readKeyFile "tests/fixtures/server.key"
    signKey <- either error pure $ C.x509ToPrivate (serverKey, []) >>= C.privKey @C.APrivateSignKey
    (serverAuthPub, _) <- atomically $ C.generateKeyPair @'C.X25519 g
    let serverCertKey = (X.CertificateChain [serverCert, ca], C.signX509 signKey $ C.toPubKey C.publicToX509 serverAuthPub)
    pure $ Just THAuthClient {serverPeerPubKey, serverCertKey, sessSecret = Nothing}
  _ -> pure Nothing

randomSENDCmdV6 :: ProtocolClient SMPVersion ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmdV6 = randomSENDCmd_ C.SEd25519

randomSENDCmd :: ProtocolClient SMPVersion ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd = randomSENDCmd_ C.SX25519

randomSENDCmd_ :: (C.AlgorithmI a, C.AuthAlgorithm a) => C.SAlgorithm a -> ProtocolClient SMPVersion ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd_ a c len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair a g
  msg <- atomically $ C.randomBytes len g
  mkTransmission c (Just rpKey, EntityId sId, Cmd SSender $ SEND noMsgFlags msg)

lenOk :: ByteString -> Bool
lenOk s = 0 < B.length s && B.length s <= smpBlockSize - 2

lenOk1 :: TransportBatch r -> Bool
lenOk1 = \case
  TBTransmission s _ -> lenOk s
  _ -> False
