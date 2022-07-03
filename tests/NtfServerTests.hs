{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module NtfServerTests where

import Control.Concurrent (threadDelay)
import Control.Monad.Except (runExceptT)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import Data.Text.Encoding (encodeUtf8)
import NtfClient
import SMPClient as SMP
import ServerTests
  ( createAndSecureQueue,
    sampleDhPubKey,
    samplePubKey,
    sampleSig,
    signSendRecv,
    (#==),
    _SEND',
    pattern Resp,
  )
import qualified Simplex.Messaging.Agent.Protocol as AP
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import qualified Simplex.Messaging.Notifications.Server.Push.APNS as APNS
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol hiding (notification)
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.STM

ntfServerTests :: ATransport -> Spec
ntfServerTests t = do
  describe "Notifications server protocol syntax" $ ntfSyntaxTests t
  describe "Notification subscriptions" $ testNotificationSubscription t

ntfSyntaxTests :: ATransport -> Spec
ntfSyntaxTests (ATransport t) = do
  it "unknown command" $ ("", "abcd", "1234", ('H', 'E', 'L', 'L', 'O')) >#> ("", "abcd", "1234", ERR $ CMD UNKNOWN)
  describe "NEW" $ do
    it "no parameters" $ (sampleSig, "bcda", "", TNEW_) >#> ("", "bcda", "", ERR $ CMD SYNTAX)
    it "many parameters" $ (sampleSig, "cdab", "", (TNEW_, (' ', '\x01', 'A'), ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "cdab", "", ERR $ CMD SYNTAX)
    it "no signature" $ ("", "dabc", "", (TNEW_, ' ', ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "dabc", "", ERR $ CMD NO_AUTH)
    it "token ID" $ (sampleSig, "abcd", "12345678", (TNEW_, ' ', ('T', 'A', 'T', "abcd" :: ByteString), samplePubKey, sampleDhPubKey)) >#> ("", "abcd", "12345678", ERR $ CMD HAS_AUTH)
  where
    (>#>) ::
      Encoding smp =>
      (Maybe C.ASignature, ByteString, ByteString, smp) ->
      (Maybe C.ASignature, ByteString, ByteString, BrokerMsg) ->
      Expectation
    command >#> response = withAPNSMockServer $ \_ -> ntfServerTest t command `shouldReturn` response

pattern RespNtf :: CorrId -> QueueId -> NtfResponse -> SignedTransmission NtfResponse
pattern RespNtf corrId queueId command <- (_, _, (corrId, queueId, Right command))

sendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandle c -> (Maybe C.ASignature, ByteString, ByteString, NtfCommand e) -> IO (SignedTransmission NtfResponse)
sendRecvNtf h@THandle {thVersion, sessionId} (sgn, corrId, qId, cmd) = do
  let t = encodeTransmission thVersion sessionId (CorrId corrId, qId, cmd)
  Right () <- tPut h (sgn, t)
  tGet h

signSendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandle c -> C.APrivateSignKey -> (ByteString, ByteString, NtfCommand e) -> IO (SignedTransmission NtfResponse)
signSendRecvNtf h@THandle {thVersion, sessionId} pk (corrId, qId, cmd) = do
  let t = encodeTransmission thVersion sessionId (CorrId corrId, qId, cmd)
  Right sig <- runExceptT $ C.sign pk t
  Right () <- tPut h (Just sig, t)
  tGet h

(.->) :: J.Value -> J.Key -> Either String ByteString
v .-> key =
  let J.Object o = v
   in U.decodeLenient . encodeUtf8 <$> JT.parseEither (J..: key) o

testNotificationSubscription :: ATransport -> Spec
testNotificationSubscription (ATransport t) =
  it "should create notification subscription and notify when message is received" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    (nPub, nKey) <- C.generateSignatureKeyPair C.SEd25519
    (tknPub, tknKey) <- C.generateSignatureKeyPair C.SEd25519
    (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
    let tkn = DeviceToken PPApnsTest "abcd"
    withAPNSMockServer $ \APNSMockServer {apnsQ} ->
      smpTest2 t $ \rh sh ->
        ntfTest t $ \nh -> do
          -- create queue
          (sId, rId, rKey, rcvDhSecret) <- createAndSecureQueue rh sPub
          -- register and verify token
          RespNtf "1" "" (NRTknId tId ntfDh) <- signSendRecvNtf nh tknKey ("1", "", TNEW $ NewNtfTkn tkn tknPub dhPub)
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse = send} <-
            atomically $ readTBQueue apnsQ
          send APNSRespOk
          let dhSecret = C.dh' ntfDh dhPriv
              Right verification = ntfData .-> "verification"
              Right nonce = C.cbNonce <$> ntfData .-> "nonce"
              Right code = NtfRegCode <$> C.cbDecrypt dhSecret nonce verification
          RespNtf "2" _ NROk <- signSendRecvNtf nh tknKey ("2", tId, TVFY code)
          RespNtf "2a" _ (NRTkn NTActive) <- signSendRecvNtf nh tknKey ("2a", tId, TCHK)
          -- enable queue notifications
          (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- C.generateKeyPair'
          Resp "3" _ (NID nId rcvNtfSrvPubDhKey) <- signSendRecv rh rKey ("3", rId, NKEY nPub rcvNtfPubDhKey)
          let srv = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
              q = SMPQueueNtf srv nId
              rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
          RespNtf "4" _ (NRSubId _subId) <- signSendRecvNtf nh tknKey ("4", "", SNEW $ NewNtfSub tId q nKey)
          -- send message
          threadDelay 50000
          Resp "5" _ OK <- signSendRecv sh sKey ("5", sId, _SEND' "hello")
          -- receive notification
          APNSMockRequest {notification, sendApnsResponse = send'} <- atomically $ readTBQueue apnsQ
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData'} = notification
              Right nonce' = C.cbNonce <$> ntfData' .-> "nonce"
              Right message = ntfData' .-> "message"
              Right ntfDataDecrypted = C.cbDecrypt dhSecret nonce' message
              Right APNS.PNMessageData {smpQueue = SMPQueueNtf {smpServer, notifierId}, nmsgNonce, encNMsgMeta} =
                parse strP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted
              Right nMsgMeta = C.cbDecrypt rcvNtfDhSecret nmsgNonce encNMsgMeta
              Right NMsgMeta {msgId, msgTs} = parse smpP (AP.INTERNAL "error parsing NMsgMeta") nMsgMeta
          smpServer `shouldBe` srv
          notifierId `shouldBe` nId
          send' APNSRespOk
          -- receive message
          Resp "" _ (MSG Message {msgId = mId1, msgBodyV3 = Just (MsgBodyV3 bodyV3)}) <- tGet rh
          Right RcvMsgBody {msgTs = mTs, msgBody} <- pure $ smpDecode =<< first show (C.cbDecrypt rcvDhSecret (C.cbNonce mId1) bodyV3)
          mId1 `shouldBe` msgId
          mTs `shouldBe` msgTs
          (msgBody, "hello") #== "delivered from queue"
          Resp "6" _ OK <- signSendRecv rh rKey ("6", rId, ACK mId1)
          pure ()
          -- replace token
          let tkn' = DeviceToken PPApnsTest "efgh"
          RespNtf "7" tId' NROk <- signSendRecvNtf nh tknKey ("7", tId, TRPL tkn')
          tId `shouldBe` tId'
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData2}, sendApnsResponse = send2} <-
            atomically $ readTBQueue apnsQ
          send2 APNSRespOk
          let Right verification2 = ntfData2 .-> "verification"
              Right nonce2 = C.cbNonce <$> ntfData2 .-> "nonce"
              Right code2 = NtfRegCode <$> C.cbDecrypt dhSecret nonce2 verification2
          RespNtf "8" _ NROk <- signSendRecvNtf nh tknKey ("8", tId, TVFY code2)
          RespNtf "8a" _ (NRTkn NTActive) <- signSendRecvNtf nh tknKey ("8a", tId, TCHK)
          -- send message
          Resp "9" _ OK <- signSendRecv sh sKey ("9", sId, _SEND' "hello 2")
          APNSMockRequest {notification = notification3, sendApnsResponse = send3} <- atomically $ readTBQueue apnsQ
          let APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData3} = notification3
              Right nonce3 = C.cbNonce <$> ntfData3 .-> "nonce"
              Right message3 = ntfData3 .-> "message"
              Right ntfDataDecrypted3 = C.cbDecrypt dhSecret nonce3 message3
              Right APNS.PNMessageData {smpQueue = SMPQueueNtf {smpServer = smpServer3, notifierId = notifierId3}} =
                parse strP (AP.INTERNAL "error parsing PNMessageData") ntfDataDecrypted3
          smpServer3 `shouldBe` srv
          notifierId3 `shouldBe` nId
          send3 APNSRespOk
