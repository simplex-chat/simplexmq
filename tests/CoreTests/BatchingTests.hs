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
import Test.Hspec hiding (fit, it)
import Util

batchingTests :: Spec
batchingTests = do
  describe "batchTransmissions" $ do
    it "should batch with 135 subscriptions per batch" testBatchSubscriptions
    it "should break on message that does not fit" testBatchWithMessage
    it "should break on large message" testBatchWithLargeMessage
  describe "batchTransmissions'" $ do
    it "should batch with 135 subscriptions per batch" testClientBatchSubscriptions
    it "should batch with 255 ENDs per batch" testClientBatchENDs
    it "should batch with 80 NMSGs per batch" testClientBatchNMSGs
    it "should batch subscription responses with message" testBatchSubResponses
    it "should break on message that does not fit" testClientBatchWithMessage
    it "should break on large message" testClientBatchWithLargeMessage

testBatchSubscriptions :: IO ()
testBatchSubscriptions = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs <- replicateM 300 $ randomSUB sessId
  let thParams = testTHandleParams sessId
  let batches = batchTransmissions thParams $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (30, 135, 135)
  all lenOk [s1, s2, s3] `shouldBe` True

testBatchWithMessage :: IO ()
testBatchWithMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 8000
  subs2 <- replicateM 40 $ randomSUB sessId
  let thParams = testTHandleParams sessId
      cmds = subs1 <> [send] <> subs2
  let batches = batchTransmissions thParams $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 _, TBTransmissions s2 n2 _] <- pure batches
  (n1, n2) `shouldBe` (33, 68)
  all lenOk [s1, s2] `shouldBe` True

testBatchWithLargeMessage :: IO ()
testBatchWithLargeMessage = do
  sessId <- atomically . C.randomBytes 32 =<< C.newRandom
  subs1 <- replicateM 60 $ randomSUB sessId
  send <- randomSEND sessId 17000
  subs2 <- replicateM 150 $ randomSUB sessId
  let thParams = testTHandleParams sessId
      cmds = subs1 <> [send] <> subs2
  let batches = batchTransmissions thParams $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 _, TBError TELargeMsg _, TBTransmissions s2 n2 _, TBTransmissions s3 n3 _] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 15, 135)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchSubscriptions :: IO ()
testClientBatchSubscriptions = do
  client <- testClientStub
  subs <- replicateM 300 $ randomSUBCmd client
  let batches = batchTransmissions' (thParams client) $ L.fromList subs
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (30, 135, 135)
  (length rs1, length rs2, length rs3) `shouldBe` (30, 135, 135)
  all lenOk [s1, s2, s3] `shouldBe` True

testClientBatchENDs :: IO ()
testClientBatchENDs = do
  client <- testClientStub
  ends <- replicateM 300 randomENDCmd
  let ends' = map (\t -> Right (Nothing, encodeTransmission (thParams client) t)) ends
  let batches = batchTransmissions (thParams client) $ L.fromList ends'
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
  let batches = batchTransmissions (thParams client) $ L.fromList ntfs'
  length batches `shouldBe` 3
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (40, 80, 80)
  (length rs1, length rs2, length rs3) `shouldBe` (40, 80, 80)
  all lenOk [s1, s2, s3] `shouldBe` True

-- 4 responses are used in Simplex.Messaging.Server / `send`
testBatchSubResponses :: IO ()
testBatchSubResponses = do
  client <- testClientStub
  soks <- replicateM 4 $ randomSOK
  msg <- randomMSG
  let msgs = map (\t -> Right (Nothing, encodeTransmission (thParams client) t)) (soks <> [msg])
      batches = batchTransmissions (thParams client) $ L.fromList msgs
  length batches `shouldBe` 1
  soks' <- replicateM 5 $ randomSOK
  let msgs' = map (\t -> Right (Nothing, encodeTransmission (thParams client) t)) (soks' <> [msg])
      batches' = batchTransmissions (thParams client) $ L.fromList msgs'
  length batches' `shouldBe` 2

testClientBatchWithMessage :: IO ()
testClientBatchWithMessage = do
  client <- testClientStub
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 8000
  subs2 <- replicateM 40 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches = batchTransmissions' (thParams client) $ L.fromList cmds
  length batches `shouldBe` 2
  [TBTransmissions s1 n1 rs1, TBTransmissions s2 n2 rs2] <- pure batches
  (n1, n2) `shouldBe` (33, 68)
  (length rs1, length rs2) `shouldBe` (33, 68)
  all lenOk [s1, s2] `shouldBe` True

testClientBatchWithLargeMessage :: IO ()
testClientBatchWithLargeMessage = do
  client <- testClientStub
  subs1 <- replicateM 60 $ randomSUBCmd client
  send <- randomSENDCmd client 17000
  subs2 <- replicateM 150 $ randomSUBCmd client
  let cmds = subs1 <> [send] <> subs2
      batches = batchTransmissions' (thParams client) $ L.fromList cmds
  length batches `shouldBe` 4
  [TBTransmissions s1 n1 rs1, TBError TELargeMsg _, TBTransmissions s2 n2 rs2, TBTransmissions s3 n3 rs3] <- pure batches
  (n1, n2, n3) `shouldBe` (60, 15, 135)
  (length rs1, length rs2, length rs3) `shouldBe` (60, 15, 135)
  all lenOk [s1, s2, s3] `shouldBe` True
  --
  let cmds' = [send] <> subs1 <> subs2
  let batches' = batchTransmissions' (thParams client) $ L.fromList cmds'
  length batches' `shouldBe` 3
  [TBError TELargeMsg _, TBTransmissions s1' n1' rs1', TBTransmissions s2' n2' rs2'] <- pure batches'
  (n1', n2') `shouldBe` (75, 135)
  (length rs1', length rs2') `shouldBe` (75, 135)
  all lenOk [s1', s2'] `shouldBe` True

testClientStub :: IO (ProtocolClient SMPVersion ErrorType BrokerMsg)
testClientStub = do
  g <- C.newRandom
  sessId <- atomically $ C.randomBytes 32 g
  (rKey, _) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  thAuth_ <- testTHandleAuth g rKey
  smpClientStub g sessId currentClientSMPRelayVersion thAuth_

randomSUB :: ByteString -> IO (Either TransportError (Maybe TAuthorizations, ByteString))
randomSUB sessId = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  nonce@(C.CbNonce corrId) <- atomically $ C.randomCbNonce g
  (rKey, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  thAuth_ <- testTHandleAuth g rKey
  let thParams = testTHandleParams sessId
      TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams (CorrId corrId, EntityId rId, Cmd SRecipient SUB)
  pure $ (,tToSend) <$> authTransmission thAuth_ True (Just rpKey) nonce tForAuth

randomSUBCmd :: ProtocolClient SMPVersion ErrorType BrokerMsg -> IO (PCTransmission ErrorType BrokerMsg)
randomSUBCmd c = do
  g <- C.newRandom
  rId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  mkTransmission c (EntityId rId, Just rpKey, Cmd SRecipient SUB)

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

randomSOK :: IO (Transmission BrokerMsg)
randomSOK = do
  g <- C.newRandom
  corrId <- atomically $ C.randomBytes 24 g
  rId <- atomically $ C.randomBytes 24 g
  pure (CorrId corrId, EntityId rId, SOK Nothing)

randomMSG :: IO (Transmission BrokerMsg)
randomMSG = do
  g <- C.newRandom
  corrId <- atomically $ C.randomBytes 24 g
  rId <- atomically $ C.randomBytes 24 g
  msgId <- atomically $ C.randomBytes 24 g
  msg <- atomically $ C.randomBytes maxMessageLength g
  pure (CorrId corrId, EntityId rId, MSG RcvMessage {msgId, msgBody = EncRcvMsgBody msg})

randomSEND :: ByteString -> Int -> IO (Either TransportError (Maybe TAuthorizations, ByteString))
randomSEND sessId len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  nonce@(C.CbNonce corrId) <- atomically $ C.randomCbNonce g
  (sKey, spKey) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  thAuth_ <- testTHandleAuth g sKey
  msg <- atomically $ C.randomBytes len g
  let thParams = testTHandleParams sessId
      TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth thParams (CorrId corrId, EntityId sId, Cmd SSender $ SEND noMsgFlags msg)
  pure $ (,tToSend) <$> authTransmission thAuth_ False (Just spKey) nonce tForAuth

testTHandleParams :: ByteString -> THandleParams SMPVersion 'TClient
testTHandleParams sessionId =
  THandleParams
    { sessionId,
      blockSize = smpBlockSize,
      thVersion = currentClientSMPRelayVersion,
      thServerVRange = supportedServerSMPRelayVRange,
      thAuth = Nothing,
      implySessId = True,
      encryptBlock = Nothing,
      serviceAuth = True,
      serverInfoBytes = Nothing
    }

testTHandleAuth :: TVar ChaChaDRG -> C.APublicAuthKey -> IO (Maybe (THandleAuth 'TClient))
testTHandleAuth g (C.APublicAuthKey a peerServerPubKey) = case a of
  C.SX25519 -> do
    ca <- head <$> XS.readCertificates "tests/fixtures/ca.crt"
    serverCert <- head <$> XS.readCertificates "tests/fixtures/server.crt"
    serverKey <- head <$> XF.readKeyFile "tests/fixtures/server.key"
    signKey <- either error pure $ C.x509ToPrivate (serverKey, []) >>= C.privKey @C.APrivateSignKey
    (serverAuthPub, _) <- atomically $ C.generateKeyPair @'C.X25519 g
    let peerServerCertKey = CertChainPubKey (X.CertificateChain [serverCert, ca]) (C.signX509 signKey $ C.toPubKey C.publicToX509 serverAuthPub)
    pure $ Just THAuthClient {peerServerPubKey, peerServerCertKey, clientService = Nothing, sessSecret = Nothing}
  _ -> pure Nothing

randomSENDCmd :: ProtocolClient SMPVersion ErrorType BrokerMsg -> Int -> IO (PCTransmission ErrorType BrokerMsg)
randomSENDCmd c len = do
  g <- C.newRandom
  sId <- atomically $ C.randomBytes 24 g
  (_, rpKey) <- atomically $ C.generateAuthKeyPair C.SX25519 g
  msg <- atomically $ C.randomBytes len g
  mkTransmission c (EntityId sId, Just rpKey, Cmd SSender $ SEND noMsgFlags msg)

lenOk :: ByteString -> Bool
lenOk s = 0 < B.length s && B.length s <= smpBlockSize - 2
