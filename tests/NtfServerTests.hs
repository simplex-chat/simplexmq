{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
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
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.STM

ntfServerTests :: ATransport -> Spec
ntfServerTests t = do
  describe "Notifications server protocol syntax" $ ntfSyntaxTests t
  describe "Notification subscriptions (NKEY)" $ testNotificationSubscription t createNtfQueueNKEY
  -- describe "Notification subscriptions (NEW with ntf creds)" $ testNotificationSubscription t createNtfQueueNEW

ntfSyntaxTests :: ATransport -> Spec
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
      (Maybe TransmissionAuth, ByteString, ByteString, smp) ->
      (Maybe TransmissionAuth, ByteString, ByteString, NtfResponse) ->
      Expectation
    command >#> response = withAPNSMockServer $ \_ -> ntfServerTest t command `shouldReturn` response

pattern RespNtf :: CorrId -> QueueId -> NtfResponse -> SignedTransmission ErrorType NtfResponse
pattern RespNtf corrId queueId command <- (_, _, (corrId, queueId, Right command))

deriving instance Eq NtfResponse

sendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandleNTF c 'TClient -> (Maybe TransmissionAuth, ByteString, NtfEntityId, NtfCommand e) -> IO (SignedTransmission ErrorType NtfResponse)
sendRecvNtf h@THandle {params} (sgn, corrId, qId, cmd) = do
  let TransmissionForAuth {tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (sgn, tToSend)
  tGet1 h

signSendRecvNtf :: forall c e. (Transport c, NtfEntityI e) => THandleNTF c 'TClient -> C.APrivateAuthKey -> (ByteString, NtfEntityId, NtfCommand e) -> IO (SignedTransmission ErrorType NtfResponse)
signSendRecvNtf h@THandle {params} (C.APrivateAuthKey a pk) (corrId, qId, cmd) = do
  let TransmissionForAuth {tForAuth, tToSend} = encodeTransmissionForAuth params (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (authorize tForAuth, tToSend)
  tGet1 h
  where
    authorize t = case a of
      C.SEd25519 -> Just . TASignature . C.ASignature C.SEd25519 $ C.sign' pk t
      C.SEd448 -> Just . TASignature . C.ASignature C.SEd448 $ C.sign' pk t
      _ -> Nothing

(.->) :: J.Value -> J.Key -> Either String ByteString
v .-> key =
  let J.Object o = v
   in U.decodeLenient . encodeUtf8 <$> JT.parseEither (J..: key) o

testNotificationSubscription :: ATransport -> CreateQueueFunc -> Spec
testNotificationSubscription (ATransport t) createQueue =
  it "should create notification subscription and notify when message is received" $ do
    g <- C.newRandom
    (sPub, sKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (nPub, nKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (tknPub, tknKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
    (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    let tkn = DeviceToken PPApnsTest "abcd"
    withAPNSMockServer $ \apns ->
      smpTest2' t $ \rh sh ->
        ntfTest t $ \nh -> do
          ((sId, rId, rKey, rcvDhSecret), nId, rcvNtfDhSecret) <- createQueue rh sPub nPub
          -- register and verify token
          RespNtf "1" NoEntity (NRTknId tId ntfDh) <- signSendRecvNtf nh tknKey ("1", NoEntity, TNEW $ NewNtfTkn tkn tknPub dhPub)
          APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}} <-
            getMockNotification apns tkn
          let dhSecret = C.dh' ntfDh dhPriv
              Right verification = ntfData .-> "verification"
              Right nonce = C.cbNonce <$> ntfData .-> "nonce"
              Right code = NtfRegCode <$> C.cbDecrypt dhSecret nonce verification
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

-- TODO [notifications]
-- createNtfQueueNEW :: CreateQueueFunc
-- createNtfQueueNEW h sPub nPub = do
--   g <- C.newRandom
--   (rPub, rKey) <- atomically $ C.generateAuthKeyPair C.SEd448 g
--   (dhPub, dhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
--   (rcvNtfPubDhKey, rcvNtfPrivDhKey) <- atomically $ C.generateKeyPair g
--   let cmd = NEW (NewQueueReq rPub dhPub Nothing SMSubscribe (Just (QRMessaging Nothing)) (Just (NewNtfCreds nPub rcvNtfPubDhKey)))
--   Resp "abcd" NoEntity (IDS (QIK rId sId srvDh _sndSecure _linkId (Just (ServerNtfCreds nId rcvNtfSrvPubDhKey)))) <-
--     signSendRecv h rKey ("abcd", NoEntity, cmd)
--   let dhShared = C.dh' srvDh dhPriv
--   Resp "dabc" rId' OK <- signSendRecv h rKey ("dabc", rId, KEY sPub)
--   (rId', rId) #== "same queue ID"
--   let rcvNtfDhSecret = C.dh' rcvNtfSrvPubDhKey rcvNtfPrivDhKey
--   pure ((sId, rId, rKey, dhShared), nId, rcvNtfDhSecret)
