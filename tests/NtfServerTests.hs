{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module NtfServerTests where

import Control.Concurrent (threadDelay)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.List.NonEmpty as L
import Data.Text.Encoding (encodeUtf8)
import NtfClient
import SMPClient as SMP
import ServerTests
  ( createAndSecureQueue,
    sampleDhPubKey,
    samplePubKey,
    sampleSig,
    signSendRecv,
    tGet1,
    tPut1,
    (#==),
    _SEND',
    pattern Resp,
  )
import qualified Simplex.Messaging.Agent.Protocol as AP
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Transport (THandleNTF)
import Simplex.Messaging.Parsers (parse, parseAll)
import Simplex.Messaging.Protocol hiding (notification)
import Simplex.Messaging.Server.Env.STM (AStoreType)
import Simplex.Messaging.Transport
import Test.Hspec hiding (fit, it)
import UnliftIO.STM
import Util

ntfServerTests :: (ASrvTransport, AStoreType) -> Spec
ntfServerTests ps@(t, _) = do
  describe "Notifications server protocol syntax" $ ntfSyntaxTests t
  describe "Notification subscriptions (NKEY)" $ testNotificationSubscription ps createNtfQueueNKEY
  describe "Notification subscriptions (NEW with ntf creds)" $ testNotificationSubscription ps createNtfQueueNEW
  describe "Retried notification subscription" $ testRetriedNtfSubscription ps

ntfSyntaxTests :: ASrvTransport -> Spec
ntfSyntaxTests (ATransport t) = do
  it "unknown command" $ ("", "abcd", "1234", ('H', 'E', 'L', 'L', 'O')) >#> ("", "abcd", "1234", NRErr $ CMD UNKNOWN)
  describe "NEW" $ do
    it "no parameters" $ (sampleSig, "bcda", "", TNEW_) >#> ("", "bcda", "", NRErr $ CMD SYNTAX)
    it "many parameters" $ (sampleSig, "cdab", "", (TNEW_, (' ', '\x01', 'A'), ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "cdab", "", NRErr $ CMD SYNTAX)
    it "no signature" $ ("", "dabc", "", (TNEW_, ' ', ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "dabc", "", NRErr $ CMD NO_AUTH)
    it "token ID" $ (sampleSig, "abcd", "12345678", (TNEW_, ' ', ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "abcd", "12345678", NRErr $ CMD HAS_AUTH)
  where
    (>#>) ::
      Encoding smp =>
      (Maybe TAuthorizations, ByteString, ByteString, smp) ->
      (Maybe TAuthorizations, ByteString, ByteString, NtfResponse) ->
      Expectation
    command >#> response = withAPNSMockServer $ \_ -> ntfServerTest t command `shouldReturn` response

pattern RespNtf :: CorrId -> QueueId -> NtfResponse -> Transmission (Either ErrorType NtfResponse)
pattern RespNtf corrId queueId command <- (corrId, queueId, Right command)

deriving instance Eq NtfResponse

sendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandleNTF c 'TClient -> (Maybe TAuthorizations, ByteString, NtfEntityId, NtfCommand e) -> IO (Transmission (Either ErrorType NtfResponse))
sendRecvNtf h@THandle {params} (sgn, corrId, qId, cmd) = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (sgn, tToSend)
  tGet1 h

signSendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandleNTF c 'TClient -> C.APrivateAuthKey -> (ByteString, NtfEntityId, NtfCommand e) -> IO (Transmission (Either ErrorType NtfResponse))
signSendRecvNtf h@THandle {params} (C.APrivateAuthKey a pk) (corrId, qId, cmd) = do
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (authorize tForAuth, tToSend)
  tGet1 h
  where
    authorize t = (,Nothing) <$> case a of
      C.SEd25519 -> Just . TASignature . C.ASignature C.SEd25519 $ C.sign' pk t
      C.SEd448 -> Just . TASignature . C.ASignature C.SEd448 $ C.sign' pk t
      _ -> Nothing

(.->) :: J.Value -> J.Key -> Either String ByteString
v .-> key =
  let J.Object o = v
   in U.decodeLenient . encodeUtf8 <$> JT.parseEither (J..: key) o

testNotificationSubscription :: (ASrvTransport, AStoreType) -> CreateQueueFunc -> Spec
testNotificationSubscription (ATransport t, msType) createQueue =
  it "should create notification subscription and notify when message is received" $ do
    g <- C.newRandom
    (sPub, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (nPub, nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (tknPub, tknKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    let tkn = DeviceToken PPApnsTest "abcd"
    withAPNSMockServer $ \apns ->
      ntfTest t $ \nh -> do
        v <- newEmptyTMVarIO
        smpTest2 t msType $ \rh sh -> do
          ((sId, rId, rKey, rcvDhSecret), nId, rcvNtfDhSecret) <- createQueue rh sPub nPub
          -- register and verify token
          RespNtf "1" NoEntity (NRTknId tId ntfDh) <- signSendRecvNtf nh tknKey ("1", NoEntity, TNEW $ NewNtfTkn tkn tknPub dhPub)
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}} <-
            getMockNotification apns tkn
          let dhSecret = C.dh' ntfDh dhPriv
              decryptCode nd =
                let Right verification = nd .-> "verification"
                    Right nonce = C.cbNonce <$> nd .-> "nonce"
                    Right pt = C.cbDecrypt dhSecret nonce verification
                 in NtfRegCode pt
          let code = decryptCode ntfData
          -- test repeated request - should return the same token ID
          RespNtf "1a" NoEntity (NRTknId tId1 ntfDh1) <- signSendRecvNtf nh tknKey ("1a", NoEntity, TNEW $ NewNtfTkn tkn tknPub dhPub)
          tId1 `shouldBe` tId
          ntfDh1 `shouldBe` ntfDh
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData1}} <-
            getMockNotification apns tkn
          let code1 = decryptCode ntfData1
          code `shouldBe` code1
          RespNtf "2" _ NROk <- signSendRecvNtf nh tknKey ("2", tId, TVFY code)
          RespNtf "2a" _ (NRTkn NTActive) <- signSendRecvNtf nh tknKey ("2a", tId, TCHK)
          -- ntf server subscribes to queue notifications
          let srv = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
              q = SMPQueueNtf srv nId
          RespNtf "4" _ (NRSubId _subId) <- signSendRecvNtf nh tknKey ("4", NoEntity, SNEW $ NewNtfSub tId q nKey)
          -- send message
          threadDelay 50000
          Resp "5" _ OK <- signSendRecv sh sKey ("5", sId, _SEND' "hello")
          -- receive notification
          APNSMockRequest {notification} <- getMockNotification apns tkn
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData'} = notification
              Right nonce' = C.cbNonce <$> ntfData' .-> "nonce"
              Right message = ntfData' .-> "message"
              Right ntfDataDecrypted = C.cbDecrypt dhSecret nonce' message
              Right pnMsgs1 = parse pnMessagesP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted
              PNMessageData {smpQueue = SMPQueueNtf {smpServer, notifierId}, nmsgNonce, encNMsgMeta} = L.last pnMsgs1
              Right nMsgMeta = C.cbDecrypt rcvNtfDhSecret nmsgNonce encNMsgMeta
              Right NMsgMeta {msgId, msgTs} = parse smpP (AP.INTERNAL "error parsing NMsgMeta") nMsgMeta
          smpServer `shouldBe` srv
          notifierId `shouldBe` nId
          -- receive message
          Resp "" _ (MSG RcvMessage {msgId = mId1, msgBody = EncRcvMsgBody body}) <- tGet1 rh
          Right ClientRcvMsgBody {msgTs = mTs, msgBody} <- pure $ parseAll clientRcvMsgBodyP =<< first show (C.cbDecrypt rcvDhSecret (C.cbNonce mId1) body)
          mId1 `shouldBe` msgId
          mTs `shouldBe` msgTs
          (msgBody, "hello") #== "delivered from queue"
          Resp "6" _ OK <- signSendRecv rh rKey ("6", rId, ACK mId1)
          -- replace token
          let tkn' = DeviceToken PPApnsTest "efgh"
          RespNtf "7" tId' NROk <- signSendRecvNtf nh tknKey ("7", tId, TRPL tkn')
          tId `shouldBe` tId'
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData2}} <-
            getMockNotification apns tkn'
          let Right verification2 = ntfData2 .-> "verification"
              Right nonce2 = C.cbNonce <$> ntfData2 .-> "nonce"
              Right code2 = NtfRegCode <$> C.cbDecrypt dhSecret nonce2 verification2
          RespNtf "8" _ NROk <- signSendRecvNtf nh tknKey ("8", tId, TVFY code2)
          RespNtf "8a" _ (NRTkn NTActive) <- signSendRecvNtf nh tknKey ("8a", tId, TCHK)
          -- send message
          Resp "9" _ OK <- signSendRecv sh sKey ("9", sId, _SEND' "hello 2")
          APNSMockRequest {notification = notification3} <- getMockNotification apns tkn'
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData3} = notification3
              Right nonce3 = C.cbNonce <$> ntfData3 .-> "nonce"
              Right message3 = ntfData3 .-> "message"
              Right ntfDataDecrypted3 = C.cbDecrypt dhSecret nonce3 message3
              Right pnMsgs2 = parse pnMessagesP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted3
              PNMessageData {smpQueue = SMPQueueNtf {smpServer = smpServer3, notifierId = notifierId3}} = L.last pnMsgs2
          smpServer3 `shouldBe` srv
          notifierId3 `shouldBe` nId
          Resp "" _ (MSG RcvMessage {msgId = mId2, msgBody = EncRcvMsgBody body2}) <- tGet1 rh
          Right ClientRcvMsgBody {msgBody = "hello 2"} <- pure $ parseAll clientRcvMsgBodyP =<< first show (C.cbDecrypt rcvDhSecret (C.cbNonce mId2) body2)
          Resp "10" _ OK <- signSendRecv rh rKey ("10", rId, ACK mId2)

          q2 <- createQueue rh sPub nPub
          atomically $ putTMVar v (sId, rId, rKey, nId, dhSecret, rcvDhSecret, tId, tkn', srv, q2)

        (sId, rId, rKey, nId, dhSecret, rcvDhSecret, tId, tkn', srv, q2) <- atomically $ readTMVar v
        let ((sId', rId', rKey', rcvDhSecret'), nId', _rcvNtfDhSecret') = q2

        RespNtf "11" _ (NRSubId _subId) <- signSendRecvNtf nh tknKey ("11", NoEntity, SNEW $ NewNtfSub tId (SMPQueueNtf srv nId') nKey)
        threadDelay 250000

        smpTest2 t msType $ \rh sh -> do
          Resp "12" _ (SOK Nothing) <- signSendRecv rh rKey ("12", rId, SUB)
          Resp "12.1" _ (SOK Nothing) <- signSendRecv rh rKey' ("12.1", rId', SUB)
          -- deliver to queue with ntf sub created while SMP was online
          Resp "14" _ OK <- signSendRecv sh sKey ("14", sId, _SEND' "hello 3")
          APNSMockRequest {notification = notification4} <- getMockNotification apns tkn'
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData4} = notification4
              Right nonce4 = C.cbNonce <$> ntfData4 .-> "nonce"
              Right message4 = ntfData4 .-> "message"
              Right ntfDataDecrypted4 = C.cbDecrypt dhSecret nonce4 message4
              Right pnMsgs4 = parse pnMessagesP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted4
              PNMessageData {smpQueue = SMPQueueNtf {smpServer = smpServer4, notifierId = notifierId4}} = L.last pnMsgs4
          smpServer4 `shouldBe` srv
          notifierId4 `shouldBe` nId
          Resp "" _ (MSG RcvMessage {msgId = mId3, msgBody = EncRcvMsgBody body3}) <- tGet1 rh
          Right ClientRcvMsgBody {msgBody = "hello 3"} <- pure $ parseAll clientRcvMsgBodyP =<< first show (C.cbDecrypt rcvDhSecret (C.cbNonce mId3) body3)
          Resp "15" _ OK <- signSendRecv rh rKey ("15", rId, ACK mId3)

          -- deliver to queue with ntf sub created while SMP was offline
          Resp "16" _ OK <- signSendRecv sh sKey ("16", sId', _SEND' "hello 4")
          APNSMockRequest {notification = notification5} <- getMockNotification apns tkn'
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData5} = notification5
              Right nonce5 = C.cbNonce <$> ntfData5 .-> "nonce"
              Right message5 = ntfData5 .-> "message"
              Right ntfDataDecrypted5 = C.cbDecrypt dhSecret nonce5 message5
              Right pnMsgs5 = parse pnMessagesP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted5
              PNMessageData {smpQueue = SMPQueueNtf {smpServer = smpServer5, notifierId = notifierId5}} = L.last pnMsgs5
          smpServer5 `shouldBe` srv
          notifierId5 `shouldBe` nId'
          Resp "" _ (MSG RcvMessage {msgId = mId4, msgBody = EncRcvMsgBody body4}) <- tGet1 rh
          Right ClientRcvMsgBody {msgBody = "hello 4"} <- pure $ parseAll clientRcvMsgBodyP =<< first show (C.cbDecrypt rcvDhSecret' (C.cbNonce mId4) body4)
          Resp "17" _ OK <- signSendRecv rh rKey' ("17", rId', ACK mId4)
          pure ()

testRetriedNtfSubscription :: (ASrvTransport, AStoreType) -> Spec
testRetriedNtfSubscription (ATransport t, msType) =
  it "should allow retrying to create notification subscription with the same token and key" $ do
    g <- C.newRandom
    (sPub, _sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (nPub, nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    withAPNSMockServer $ \apns ->
      smpTest t msType $ \h ->
        ntfTest t $ \nh -> do
          ((_sId, _rId, _rKey, _rcvDhSecret), nId, _rcvNtfDhSecret) <- createNtfQueueNKEY h sPub nPub
          (tknKey, _dhSecret, tId, regCode) <- registerToken nh apns "abcd"
          let srv = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
              q = SMPQueueNtf srv nId
          -- fails creating subscription until token is verified
          RespNtf "2" NoEntity (NRErr AUTH) <- signSendRecvNtf nh tknKey ("2", NoEntity, SNEW $ NewNtfSub tId q nKey)
          -- verify token
          RespNtf "3" tId1 NROk <- signSendRecvNtf nh tknKey ("3", tId, TVFY regCode)
          tId1 `shouldBe` tId
          -- create subscription
          RespNtf "4" NoEntity (NRSubId subId) <- signSendRecvNtf nh tknKey ("4", NoEntity, SNEW $ NewNtfSub tId q nKey)
          -- allow retry
          RespNtf "4a" NoEntity (NRSubId subId') <- signSendRecvNtf nh tknKey ("4a", NoEntity, SNEW $ NewNtfSub tId q nKey)
          subId' `shouldBe` subId
          -- fail with another key
          (_nPub, nKey') <- atomically $ C.generateAuthKeyPair C.SEd25519 g
          RespNtf "5" NoEntity (NRErr AUTH) <- signSendRecvNtf nh tknKey ("5", NoEntity, SNEW $ NewNtfSub tId q nKey')
          -- fail with another token
          (tknKey', _dhSecret, tId', regCode') <- registerToken nh apns "efgh"
          RespNtf "6" _ NROk <- signSendRecvNtf nh tknKey' ("6", tId', TVFY regCode')
          RespNtf "7" NoEntity (NRErr AUTH) <- signSendRecvNtf nh tknKey' ("7", NoEntity, SNEW $ NewNtfSub tId' q nKey)
          pure ()

type CreateQueueFunc =
  forall c.
  Transport c =>
  THandleSMP c 'TClient ->
  SndPublicAuthKey ->
  NtfPublicAuthKey ->
  IO ((SenderId, RecipientId, RcvPrivateAuthKey, RcvDhSecret), NotifierId, C.DhSecret 'C.X25519)

createNtfQueueNKEY :: CreateQueueFunc
createNtfQueueNKEY h sPub nPub = do
  g <- C.newRandom
  (sId, rId, rKey, rcvDhSecret) <- createAndSecureQueue h sPub
  -- enable queue notifications
  (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- atomically $ C.generateKeyPair g
  Resp "3" _ (NID nId rcvNtfSrvPubDhKey) <- signSendRecv h rKey ("3", rId, NKEY nPub rcvNtfPubDhKey)
  let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
  pure ((sId, rId, rKey, rcvDhSecret), nId, rcvNtfDhSecret)

registerToken :: Transport c => THandleNTF c 'TClient -> APNSMockServer -> ByteString -> IO (C.APrivateAuthKey, C.DhSecretX25519, NtfEntityId, NtfRegCode)
registerToken nh apns token = do
  g <- C.newRandom
  (tknPub, tknKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  let tkn = DeviceToken PPApnsTest token
  RespNtf "1" NoEntity (NRTknId tId ntfDh) <- signSendRecvNtf nh tknKey ("1", NoEntity, TNEW $ NewNtfTkn tkn tknPub dhPub)
  APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}} <-
    getMockNotification apns tkn
  let dhSecret = C.dh' ntfDh dhPriv
      decryptCode nd =
        let Right verification = nd .-> "verification"
            Right nonce = C.cbNonce <$> nd .-> "nonce"
            Right pt = C.cbDecrypt dhSecret nonce verification
         in NtfRegCode pt
  let code = decryptCode ntfData
  pure (tknKey, dhSecret, tId, code)

createNtfQueueNEW :: CreateQueueFunc
createNtfQueueNEW h sPub nPub = do
  g <- C.newRandom
  (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd448 g
  (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- atomically $ C.generateKeyPair g
  let cmd = NEW (NewQueueReq rPub dhPub Nothing SMSubscribe (Just (QRMessaging Nothing)) (Just (NewNtfCreds nPub rcvNtfPubDhKey)))
  Resp "abcd" NoEntity (IDS (QIK rId sId srvDh _sndSecure _linkId _serviceId (Just (ServerNtfCreds nId rcvNtfSrvPubDhKey)))) <-
    signSendRecv h rKey ("abcd", NoEntity, cmd)
  let dhShared = C.dh' srvDh dhPriv
  Resp "dabc" rId' OK <- signSendRecv h rKey ("dabc", rId, KEY sPub)
  (rId', rId) #== "same queue ID"
  let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
  pure ((sId, rId, rKey, dhShared), nId, rcvNtfDhSecret)
