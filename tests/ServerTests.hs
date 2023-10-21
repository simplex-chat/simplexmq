{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ServerTests where

import AgentTests.NotificationTests (removeFileIfExists)
import Control.Concurrent (ThreadId, killThread, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad
import Control.Monad.IO.Class
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Set as S
import GHC.Stack (withFrozenCallStack)
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Stats (PeriodStatsData (..), ServerStatsData (..))
import Simplex.Messaging.Transport
import System.Directory (removeFile)
import System.TimeIt (timeItT)
import System.Timeout
import Test.HUnit
import Test.Hspec

serverTests :: ATransport -> Spec
serverTests t@(ATransport t') = do
  describe "SMP syntax" $ syntaxTests t
  describe "SMP queues" $ do
    describe "NEW and KEY commands, SEND messages (v2)" $ testCreateSecureV2 t'
    describe "NEW and KEY commands, SEND messages (v3)" $ testCreateSecure t
    describe "NEW, OFF and DEL commands, SEND messages" $ testCreateDelete t
    describe "Stress test" $ stressTest t
    describe "allowNewQueues setting" $ testAllowNewQueues t'
  describe "SMP messages" $ do
    describe "duplex communication over 2 SMP connections" $ testDuplex t
    describe "switch subscription to another TCP connection" $ testSwitchSub t
    describe "GET command" $ testGetCommand t'
    describe "GET & SUB commands" $ testGetSubCommands t'
    describe "Exceeding queue quota" $ testExceedQueueQuota t'
  describe "Store log" $ testWithStoreLog t
  describe "Restore messages" $ testRestoreMessages t
  describe "Restore messages (old / v2)" $ do
    testRestoreMessagesV2 t
    testRestoreExpireMessages t
  describe "Timing of AUTH error" $ testTiming t
  describe "Message notifications" $ testMessageNotifications t
  describe "Message expiration" $ do
    testMsgExpireOnSend t'
    testMsgExpireOnInterval t'
    testMsgNOTExpireOnInterval t'

pattern Resp :: CorrId -> QueueId -> BrokerMsg -> SignedTransmission ErrorType BrokerMsg
pattern Resp corrId queueId command <- (_, _, (corrId, queueId, Right command))

pattern Ids :: RecipientId -> SenderId -> RcvPublicDhKey -> BrokerMsg
pattern Ids rId sId srvDh <- IDS (QIK rId sId srvDh)

pattern Msg :: MsgId -> MsgBody -> BrokerMsg
pattern Msg msgId body <- MSG RcvMessage {msgId, msgBody = EncRcvMsgBody body}

sendRecv :: forall c p. (Transport c, PartyI p) => THandle c -> (Maybe C.ASignature, ByteString, ByteString, Command p) -> IO (SignedTransmission ErrorType BrokerMsg)
sendRecv h@THandle {thVersion, sessionId} (sgn, corrId, qId, cmd) = do
  let t = encodeTransmission thVersion sessionId (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (sgn, t)
  tGet1 h

signSendRecv :: forall c p. (Transport c, PartyI p) => THandle c -> C.APrivateSignKey -> (ByteString, ByteString, Command p) -> IO (SignedTransmission ErrorType BrokerMsg)
signSendRecv h@THandle {thVersion, sessionId} pk (corrId, qId, cmd) = do
  let t = encodeTransmission thVersion sessionId (CorrId corrId, qId, cmd)
  Right () <- tPut1 h (Just $ C.sign pk t, t)
  tGet1 h

tPut1 :: Transport c => THandle c -> SentRawTransmission -> IO (Either TransportError ())
tPut1 h t = do
  [r] <- tPut h Nothing [t]
  pure r

tGet1 :: (ProtocolEncoding err cmd, Transport c, MonadIO m, MonadFail m) => THandle c -> m (SignedTransmission err cmd)
tGet1 h = do
  [r] <- liftIO $ tGet h
  pure r

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

_SEND :: MsgBody -> Command 'Sender
_SEND = SEND noMsgFlags

_SEND' :: MsgBody -> Command 'Sender
_SEND' = SEND MsgFlags {notification = True}

decryptMsgV2 :: C.DhSecret 'C.X25519 -> ByteString -> ByteString -> Either C.CryptoError ByteString
decryptMsgV2 dhShared = C.cbDecrypt dhShared . C.cbNonce

decryptMsgV3 :: C.DhSecret 'C.X25519 -> ByteString -> ByteString -> Either String MsgBody
decryptMsgV3 dhShared nonce body =
  case parseAll clientRcvMsgBodyP =<< first show (C.cbDecrypt dhShared (C.cbNonce nonce) body) of
    Right ClientRcvMsgBody {msgBody} -> Right msgBody
    Right ClientRcvMsgQuota {} -> Left "ClientRcvMsgQuota"
    Left e -> Left e

testCreateSecureV2 :: forall c. Transport c => TProxy c -> Spec
testCreateSecureV2 _ =
  it "should create (NEW) and secure (KEY) queue" $
    withSmpServerConfigOn (transport @c) cfgV2 testPort $ \_ -> testSMPClient @c $ \h -> do
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd448
      (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" rId1 (Ids rId sId srvDh) <- signSendRecv h rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
      let dec = decryptMsgV2 $ C.dh' srvDh dhPriv
      (rId1, "") #== "creates queue"

      Resp "bcda" sId1 ok1 <- sendRecv h ("", "bcda", sId, _SEND "hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp "" _ (Msg mId1 msg1) <- tGet1 h
      (dec mId1 msg1, Right "hello") #== "delivers message"

      Resp "cdab" _ ok4 <- signSendRecv h rKey ("cdab", rId, ACK mId1)
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp "dabc" _ err6 <- signSendRecv h rKey ("dabc", rId, ACK mId1)
      (err6, ERR NO_MSG) #== "replies ERR when message acknowledged without messages"

      (sPub, sKey) <- C.generateSignatureKeyPair C.SEd448
      Resp "abcd" sId2 err1 <- signSendRecv h sKey ("abcd", sId, _SEND "hello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      Resp "bcda" _ err2 <- sendRecv h (sampleSig, "bcda", rId, KEY sPub)
      (err2, ERR AUTH) #== "rejects KEY with wrong signature"

      Resp "cdab" _ err3 <- signSendRecv h rKey ("cdab", sId, KEY sPub)
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp "dabc" rId2 ok2 <- signSendRecv h rKey ("dabc", rId, KEY sPub)
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp "abcd" _ OK <- signSendRecv h rKey ("abcd", rId, KEY sPub)
      (sPub', _) <- C.generateSignatureKeyPair C.SEd448
      Resp "abcd" _ err4 <- signSendRecv h rKey ("abcd", rId, KEY sPub')
      (err4, ERR AUTH) #== "rejects if secured with different key"

      Resp "bcda" _ ok3 <- signSendRecv h sKey ("bcda", sId, _SEND "hello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp "" _ (Msg mId2 msg2) <- tGet1 h
      (dec mId2 msg2, Right "hello again") #== "delivers message 2"

      Resp "cdab" _ ok5 <- signSendRecv h rKey ("cdab", rId, ACK mId2)
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp "dabc" _ err5 <- sendRecv h ("", "dabc", sId, _SEND "hello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

      let maxAllowedMessage = B.replicate maxMessageLength '-'
      Resp "bcda" _ OK <- signSendRecv h sKey ("bcda", sId, _SEND maxAllowedMessage)
      Resp "" _ (Msg mId3 msg3) <- tGet1 h
      (dec mId3 msg3, Right maxAllowedMessage) #== "delivers message of max size"

      let biggerMessage = B.replicate (maxMessageLength + 1) '-'
      Resp "bcda" _ (ERR LARGE_MSG) <- signSendRecv h sKey ("bcda", sId, _SEND biggerMessage)
      pure ()

testCreateSecure :: ATransport -> Spec
testCreateSecure (ATransport t) =
  it "should create (NEW) and secure (KEY) queue" $
    smpTest2 t $ \r s -> do
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd448
      (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" rId1 (Ids rId sId srvDh) <- signSendRecv r rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
      let dec = decryptMsgV3 $ C.dh' srvDh dhPriv
      (rId1, "") #== "creates queue"

      Resp "bcda" sId1 ok1 <- sendRecv s ("", "bcda", sId, _SEND "hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp "" _ (Msg mId1 msg1) <- tGet1 r
      (dec mId1 msg1, Right "hello") #== "delivers message"

      Resp "cdab" _ ok4 <- signSendRecv r rKey ("cdab", rId, ACK mId1)
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp "dabc" _ err6 <- signSendRecv r rKey ("dabc", rId, ACK mId1)
      (err6, ERR NO_MSG) #== "replies ERR when message acknowledged without messages"

      (sPub, sKey) <- C.generateSignatureKeyPair C.SEd448
      Resp "abcd" sId2 err1 <- signSendRecv s sKey ("abcd", sId, _SEND "hello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      Resp "bcda" _ err2 <- sendRecv r (sampleSig, "bcda", rId, KEY sPub)
      (err2, ERR AUTH) #== "rejects KEY with wrong signature"

      Resp "cdab" _ err3 <- signSendRecv r rKey ("cdab", sId, KEY sPub)
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp "dabc" rId2 ok2 <- signSendRecv r rKey ("dabc", rId, KEY sPub)
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp "abcd" _ OK <- signSendRecv r rKey ("abcd", rId, KEY sPub)
      (sPub', _) <- C.generateSignatureKeyPair C.SEd448
      Resp "abcd" _ err4 <- signSendRecv r rKey ("abcd", rId, KEY sPub')
      (err4, ERR AUTH) #== "rejects if secured with different key"

      Resp "bcda" _ ok3 <- signSendRecv s sKey ("bcda", sId, _SEND "hello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp "" _ (Msg mId2 msg2) <- tGet1 r
      (dec mId2 msg2, Right "hello again") #== "delivers message 2"

      Resp "cdab" _ ok5 <- signSendRecv r rKey ("cdab", rId, ACK mId2)
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp "dabc" _ err5 <- sendRecv s ("", "dabc", sId, _SEND "hello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

      let maxAllowedMessage = B.replicate maxMessageLength '-'
      Resp "bcda" _ OK <- signSendRecv s sKey ("bcda", sId, _SEND maxAllowedMessage)
      Resp "" _ (Msg mId3 msg3) <- tGet1 r
      (dec mId3 msg3, Right maxAllowedMessage) #== "delivers message of max size"

      let biggerMessage = B.replicate (maxMessageLength + 1) '-'
      Resp "bcda" _ (ERR LARGE_MSG) <- signSendRecv s sKey ("bcda", sId, _SEND biggerMessage)
      pure ()

testCreateDelete :: ATransport -> Spec
testCreateDelete (ATransport t) =
  it "should create (NEW), suspend (OFF) and delete (DEL) queue" $
    smpTest2 t $ \rh sh -> do
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd25519
      (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" rId1 (Ids rId sId srvDh) <- signSendRecv rh rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
      let dec = decryptMsgV3 $ C.dh' srvDh dhPriv
      (rId1, "") #== "creates queue"

      (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
      Resp "bcda" _ ok1 <- signSendRecv rh rKey ("bcda", rId, KEY sPub)
      (ok1, OK) #== "secures queue"

      Resp "cdab" _ ok2 <- signSendRecv sh sKey ("cdab", sId, _SEND "hello")
      (ok2, OK) #== "accepts signed SEND"

      Resp "dabc" _ ok7 <- signSendRecv sh sKey ("dabc", sId, _SEND "hello 2")
      (ok7, OK) #== "accepts signed SEND 2 - this message is not delivered because the first is not ACKed"

      Resp "" _ (Msg mId1 msg1) <- tGet1 rh
      (dec mId1 msg1, Right "hello") #== "delivers message"

      Resp "abcd" _ err1 <- sendRecv rh (sampleSig, "abcd", rId, OFF)
      (err1, ERR AUTH) #== "rejects OFF with wrong signature"

      Resp "bcda" _ err2 <- signSendRecv rh rKey ("bcda", sId, OFF)
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp "cdab" rId2 ok3 <- signSendRecv rh rKey ("cdab", rId, OFF)
      (ok3, OK) #== "suspends queue"
      (rId2, rId) #== "same queue ID in response 2"

      Resp "dabc" _ err3 <- signSendRecv sh sKey ("dabc", sId, _SEND "hello")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp "abcd" _ err4 <- sendRecv sh ("", "abcd", sId, _SEND "hello")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp "bcda" _ ok4 <- signSendRecv rh rKey ("bcda", rId, OFF)
      (ok4, OK) #== "accepts OFF when suspended"

      Resp "cdab" _ (Msg mId2 msg2) <- signSendRecv rh rKey ("cdab", rId, SUB)
      (dec mId2 msg2, Right "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp "dabc" _ err5 <- sendRecv rh (sampleSig, "dabc", rId, DEL)
      (err5, ERR AUTH) #== "rejects DEL with wrong signature"

      Resp "abcd" _ err6 <- signSendRecv rh rKey ("abcd", sId, DEL)
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp "bcda" rId3 ok6 <- signSendRecv rh rKey ("bcda", rId, DEL)
      (ok6, OK) #== "deletes queue"
      (rId3, rId) #== "same queue ID in response 3"

      Resp "cdab" _ err7 <- signSendRecv sh sKey ("cdab", sId, _SEND "hello")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp "dabc" _ err8 <- sendRecv sh ("", "dabc", sId, _SEND "hello")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp "abcd" _ err11 <- signSendRecv rh rKey ("abcd", rId, ACK "")
      (err11, ERR AUTH) #== "rejects ACK when conn deleted - the second message is deleted"

      Resp "bcda" _ err9 <- signSendRecv rh rKey ("bcda", rId, OFF)
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp "cdab" _ err10 <- signSendRecv rh rKey ("cdab", rId, SUB)
      (err10, ERR AUTH) #== "rejects SUB when deleted"

stressTest :: ATransport -> Spec
stressTest (ATransport t) =
  it "should create many queues, disconnect and re-connect" $
    smpTest3 t $ \h1 h2 h3 -> do
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd25519
      (dhPub, _ :: C.PrivateKeyX25519) <- C.generateKeyPair'
      rIds <- forM ([1 .. 50] :: [Int]) . const $ do
        Resp "" "" (Ids rId _ _) <- signSendRecv h1 rKey ("", "", NEW rPub dhPub Nothing SMSubscribe)
        pure rId
      let subscribeQueues h = forM_ rIds $ \rId -> do
            Resp "" rId' OK <- signSendRecv h rKey ("", rId, SUB)
            rId' `shouldBe` rId
      closeConnection $ connection h1
      subscribeQueues h2
      closeConnection $ connection h2
      subscribeQueues h3

testAllowNewQueues :: forall c. Transport c => TProxy c -> Spec
testAllowNewQueues t =
  it "should prohibit creating new queues with allowNewQueues = False" $ do
    withSmpServerConfigOn (ATransport t) cfg {allowNewQueues = False} testPort $ \_ ->
      testSMPClient @c $ \h -> do
        (rPub, rKey) <- C.generateSignatureKeyPair C.SEd448
        (dhPub, _ :: C.PrivateKeyX25519) <- C.generateKeyPair'
        Resp "abcd" "" (ERR AUTH) <- signSendRecv h rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
        pure ()

testDuplex :: ATransport -> Spec
testDuplex (ATransport t) =
  it "should create 2 simplex connections and exchange messages" $
    smpTest2 t $ \alice bob -> do
      (arPub, arKey) <- C.generateSignatureKeyPair C.SEd448
      (aDhPub, aDhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" _ (Ids aRcv aSnd aSrvDh) <- signSendRecv alice arKey ("abcd", "", NEW arPub aDhPub Nothing SMSubscribe)
      let aDec = decryptMsgV3 $ C.dh' aSrvDh aDhPriv
      -- aSnd ID is passed to Bob out-of-band

      (bsPub, bsKey) <- C.generateSignatureKeyPair C.SEd448
      Resp "bcda" _ OK <- sendRecv bob ("", "bcda", aSnd, _SEND $ "key " <> strEncode bsPub)
      -- "key ..." is ad-hoc, not a part of SMP protocol

      Resp "" _ (Msg mId1 msg1) <- tGet1 alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, ACK mId1)
      Right ["key", bobKey] <- pure $ B.words <$> aDec mId1 msg1
      (bobKey, strEncode bsPub) #== "key received from Bob"
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, KEY bsPub)

      (brPub, brKey) <- C.generateSignatureKeyPair C.SEd448
      (bDhPub, bDhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" _ (Ids bRcv bSnd bSrvDh) <- signSendRecv bob brKey ("abcd", "", NEW brPub bDhPub Nothing SMSubscribe)
      let bDec = decryptMsgV3 $ C.dh' bSrvDh bDhPriv
      Resp "bcda" _ OK <- signSendRecv bob bsKey ("bcda", aSnd, _SEND $ "reply_id " <> encode bSnd)
      -- "reply_id ..." is ad-hoc, not a part of SMP protocol

      Resp "" _ (Msg mId2 msg2) <- tGet1 alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, ACK mId2)
      Right ["reply_id", bId] <- pure $ B.words <$> aDec mId2 msg2
      (bId, encode bSnd) #== "reply queue ID received from Bob"

      (asPub, asKey) <- C.generateSignatureKeyPair C.SEd448
      Resp "dabc" _ OK <- sendRecv alice ("", "dabc", bSnd, _SEND $ "key " <> strEncode asPub)
      -- "key ..." is ad-hoc, not a part of  SMP protocol

      Resp "" _ (Msg mId3 msg3) <- tGet1 bob
      Resp "abcd" _ OK <- signSendRecv bob brKey ("abcd", bRcv, ACK mId3)
      Right ["key", aliceKey] <- pure $ B.words <$> bDec mId3 msg3
      (aliceKey, strEncode asPub) #== "key received from Alice"
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, KEY asPub)

      Resp "cdab" _ OK <- signSendRecv bob bsKey ("cdab", aSnd, _SEND "hi alice")

      Resp "" _ (Msg mId4 msg4) <- tGet1 alice
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, ACK mId4)
      (aDec mId4 msg4, Right "hi alice") #== "message received from Bob"

      Resp "abcd" _ OK <- signSendRecv alice asKey ("abcd", bSnd, _SEND "how are you bob")

      Resp "" _ (Msg mId5 msg5) <- tGet1 bob
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, ACK mId5)
      (bDec mId5 msg5, Right "how are you bob") #== "message received from alice"

testSwitchSub :: ATransport -> Spec
testSwitchSub (ATransport t) =
  it "should create simplex connections and switch subscription to another TCP connection" $
    smpTest3 t $ \rh1 rh2 sh -> do
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd448
      (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" _ (Ids rId sId srvDh) <- signSendRecv rh1 rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
      let dec = decryptMsgV3 $ C.dh' srvDh dhPriv
      Resp "bcda" _ ok1 <- sendRecv sh ("", "bcda", sId, _SEND "test1")
      (ok1, OK) #== "sent test message 1"
      Resp "cdab" _ ok2 <- sendRecv sh ("", "cdab", sId, _SEND "test2, no ACK")
      (ok2, OK) #== "sent test message 2"

      Resp "" _ (Msg mId1 msg1) <- tGet1 rh1
      (dec mId1 msg1, Right "test1") #== "test message 1 delivered to the 1st TCP connection"
      Resp "abcd" _ (Msg mId2 msg2) <- signSendRecv rh1 rKey ("abcd", rId, ACK mId1)
      (dec mId2 msg2, Right "test2, no ACK") #== "test message 2 delivered, no ACK"

      Resp "bcda" _ (Msg mId2' msg2') <- signSendRecv rh2 rKey ("bcda", rId, SUB)
      (dec mId2' msg2', Right "test2, no ACK") #== "same simplex queue via another TCP connection, tes2 delivered again (no ACK in 1st queue)"
      Resp "cdab" _ OK <- signSendRecv rh2 rKey ("cdab", rId, ACK mId2')

      Resp "" _ end <- tGet1 rh1
      (end, END) #== "unsubscribed the 1st TCP connection"

      Resp "dabc" _ OK <- sendRecv sh ("", "dabc", sId, _SEND "test3")

      Resp "" _ (Msg mId3 msg3) <- tGet1 rh2
      (dec mId3 msg3, Right "test3") #== "delivered to the 2nd TCP connection"

      Resp "abcd" _ err <- signSendRecv rh1 rKey ("abcd", rId, ACK mId3)
      (err, ERR NO_MSG) #== "rejects ACK from the 1st TCP connection"

      Resp "bcda" _ ok3 <- signSendRecv rh2 rKey ("bcda", rId, ACK mId3)
      (ok3, OK) #== "accepts ACK from the 2nd TCP connection"

      1000 `timeout` tGet @ErrorType @BrokerMsg rh1 >>= \case
        Nothing -> return ()
        Just _ -> error "nothing else is delivered to the 1st TCP connection"

testGetCommand :: forall c. Transport c => TProxy c -> Spec
testGetCommand t =
  it "should retrieve messages from the queue using GET command" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    smpTest t $ \sh -> do
      queue <- newEmptyTMVarIO
      testSMPClient @c $ \rh ->
        atomically . putTMVar queue =<< createAndSecureQueue rh sPub
      testSMPClient @c $ \rh -> do
        (sId, rId, rKey, dhShared) <- atomically $ takeTMVar queue
        let dec = decryptMsgV3 dhShared
        Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello")
        Resp "2" _ (Msg mId1 msg1) <- signSendRecv rh rKey ("2", rId, GET)
        (dec mId1 msg1, Right "hello") #== "retrieved from queue"
        Resp "3" _ OK <- signSendRecv rh rKey ("3", rId, ACK mId1)
        Resp "4" _ OK <- signSendRecv rh rKey ("4", rId, GET)
        pure ()

testGetSubCommands :: forall c. Transport c => TProxy c -> Spec
testGetSubCommands t =
  it "should retrieve messages with GET and receive with SUB, only one ACK would work" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    smpTest3 t $ \rh1 rh2 sh -> do
      (sId, rId, rKey, dhShared) <- createAndSecureQueue rh1 sPub
      let dec = decryptMsgV3 dhShared
      Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello 1")
      Resp "1a" _ OK <- signSendRecv sh sKey ("1a", sId, _SEND "hello 2")
      Resp "1b" _ OK <- signSendRecv sh sKey ("1b", sId, _SEND "hello 3")
      Resp "1c" _ OK <- signSendRecv sh sKey ("1c", sId, _SEND "hello 4")
      -- both get the same if not ACK'd
      Resp "" _ (Msg mId1 msg1) <- tGet1 rh1
      Resp "2" _ (Msg mId1' msg1') <- signSendRecv rh2 rKey ("2", rId, GET)
      (dec mId1 msg1, Right "hello 1") #== "received from queue via SUB"
      (dec mId1' msg1', Right "hello 1") #== "retrieved from queue with GET"
      mId1 `shouldBe` mId1'
      msg1 `shouldBe` msg1'
      -- subscriber cannot GET, getter cannot SUB
      Resp "3" _ (ERR (CMD PROHIBITED)) <- signSendRecv rh1 rKey ("3", rId, GET)
      Resp "3a" _ (ERR (CMD PROHIBITED)) <- signSendRecv rh2 rKey ("3a", rId, SUB)
      -- ACK for SUB delivers the next message
      Resp "4" _ (Msg mId2 msg2) <- signSendRecv rh1 rKey ("4", rId, ACK mId1)
      (dec mId2 msg2, Right "hello 2") #== "received from queue via SUB"
      -- bad msgId returns error
      Resp "5" _ (ERR NO_MSG) <- signSendRecv rh2 rKey ("5", rId, ACK "1234")
      -- already ACK'd by subscriber, but still returns OK when msgId matches
      Resp "5a" _ OK <- signSendRecv rh2 rKey ("5a", rId, ACK mId1)
      -- msg2 is not lost - even if subscriber does not ACK it, it is delivered to getter
      Resp "6" _ (Msg mId2' msg2') <- signSendRecv rh2 rKey ("6", rId, GET)
      (dec mId2' msg2', Right "hello 2") #== "retrieved from queue with GET"
      mId2 `shouldBe` mId2'
      msg2 `shouldBe` msg2'
      -- getter ACK returns OK, even though there is the next message
      Resp "7" _ OK <- signSendRecv rh2 rKey ("7", rId, ACK mId2')
      Resp "8" _ (Msg mId3 msg3) <- signSendRecv rh2 rKey ("8", rId, GET)
      (dec mId3 msg3, Right "hello 3") #== "retrieved from queue with GET"
      -- subscriber ACK does not lose message
      Resp "9" _ (Msg mId3' msg3') <- signSendRecv rh1 rKey ("9", rId, ACK mId2')
      (dec mId3' msg3', Right "hello 3") #== "retrieved from queue with GET"
      mId3 `shouldBe` mId3'
      msg3 `shouldBe` msg3'
      Resp "10" _ (Msg mId4 msg4) <- signSendRecv rh1 rKey ("10", rId, ACK mId3)
      (dec mId4 msg4, Right "hello 4") #== "retrieved from queue with GET"
      Resp "11" _ OK <- signSendRecv rh1 rKey ("11", rId, ACK mId4)
      -- no more messages for getter too
      Resp "12" _ OK <- signSendRecv rh2 rKey ("12", rId, GET)
      pure ()

testExceedQueueQuota :: forall c. Transport c => TProxy c -> Spec
testExceedQueueQuota t =
  it "should reply with ERR QUOTA to sender and send QUOTA message to the recipient" $ do
    withSmpServerConfigOn (ATransport t) cfg {msgQueueQuota = 2} testPort $ \_ ->
      testSMPClient @c $ \sh -> testSMPClient @c $ \rh -> do
        (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
        (sId, rId, rKey, dhShared) <- createAndSecureQueue rh sPub
        let dec = decryptMsgV3 dhShared
        Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello 1")
        Resp "2" _ OK <- signSendRecv sh sKey ("2", sId, _SEND "hello 2")
        Resp "3" _ (ERR QUOTA) <- signSendRecv sh sKey ("3", sId, _SEND "hello 3")
        Resp "" _ (Msg mId1 msg1) <- tGet1 rh
        (dec mId1 msg1, Right "hello 1") #== "hello 1"
        Resp "4" _ (Msg mId2 msg2) <- signSendRecv rh rKey ("4", rId, ACK mId1)
        (dec mId2 msg2, Right "hello 2") #== "hello 2"
        Resp "5" _ (ERR QUOTA) <- signSendRecv sh sKey ("5", sId, _SEND "hello 3")
        Resp "6" _ (Msg mId3 msg3) <- signSendRecv rh rKey ("6", rId, ACK mId2)
        (dec mId3 msg3, Left "ClientRcvMsgQuota") #== "ClientRcvMsgQuota"
        Resp "7" _ (ERR QUOTA) <- signSendRecv sh sKey ("7", sId, _SEND "hello 3")
        Resp "8" _ OK <- signSendRecv rh rKey ("8", rId, ACK mId3)
        Resp "9" _ OK <- signSendRecv sh sKey ("9", sId, _SEND "hello 3")
        Resp "" _ (Msg mId4 msg4) <- tGet1 rh
        (dec mId4 msg4, Right "hello 3") #== "hello 3"
        Resp "10" _ OK <- signSendRecv rh rKey ("10", rId, ACK mId4)
        pure ()

testWithStoreLog :: ATransport -> Spec
testWithStoreLog at@(ATransport t) =
  it "should store simplex queues to log and restore them after server restart" $ do
    (sPub1, sKey1) <- C.generateSignatureKeyPair C.SEd25519
    (sPub2, sKey2) <- C.generateSignatureKeyPair C.SEd25519
    (nPub, nKey) <- C.generateSignatureKeyPair C.SEd25519
    recipientId1 <- newTVarIO ""
    recipientKey1 <- newTVarIO Nothing
    dhShared1 <- newTVarIO Nothing
    senderId1 <- newTVarIO ""
    senderId2 <- newTVarIO ""
    notifierId <- newTVarIO ""

    withSmpServerStoreLogOn at testPort . runTest t $ \h -> runClient t $ \h1 -> do
      (sId1, rId1, rKey1, dhShared) <- createAndSecureQueue h sPub1
      (rcvNtfPubDhKey, _) <- C.generateKeyPair'
      Resp "abcd" _ (NID nId _) <- signSendRecv h rKey1 ("abcd", rId1, NKEY nPub rcvNtfPubDhKey)
      atomically $ do
        writeTVar recipientId1 rId1
        writeTVar recipientKey1 $ Just rKey1
        writeTVar dhShared1 $ Just dhShared
        writeTVar senderId1 sId1
        writeTVar notifierId nId
      Resp "dabc" _ OK <- signSendRecv h1 nKey ("dabc", nId, NSUB)
      signSendRecv h sKey1 ("bcda", sId1, _SEND' "hello") >>= \case
        Resp "bcda" _ OK -> pure ()
        r -> unexpected r
      Resp "" _ (Msg mId1 msg1) <- tGet1 h
      (decryptMsgV3 dhShared mId1 msg1, Right "hello") #== "delivered from queue 1"
      Resp "" _ (NMSG _ _) <- tGet1 h1

      (sId2, rId2, rKey2, dhShared2) <- createAndSecureQueue h sPub2
      atomically $ writeTVar senderId2 sId2
      signSendRecv h sKey2 ("cdab", sId2, _SEND "hello too") >>= \case
        Resp "cdab" _ OK -> pure ()
        r -> unexpected r
      Resp "" _ (Msg mId2 msg2) <- tGet1 h
      (decryptMsgV3 dhShared2 mId2 msg2, Right "hello too") #== "delivered from queue 2"

      Resp "dabc" _ OK <- signSendRecv h rKey2 ("dabc", rId2, DEL)
      pure ()

    logSize testStoreLogFile `shouldReturn` 6

    withSmpServerThreadOn at testPort . runTest t $ \h -> do
      sId1 <- readTVarIO senderId1
      -- fails if store log is disabled
      Resp "bcda" _ (ERR AUTH) <- signSendRecv h sKey1 ("bcda", sId1, _SEND "hello")
      pure ()

    withSmpServerStoreLogOn at testPort . runTest t $ \h -> runClient t $ \h1 -> do
      -- this queue is restored
      rId1 <- readTVarIO recipientId1
      Just rKey1 <- readTVarIO recipientKey1
      Just dh1 <- readTVarIO dhShared1
      sId1 <- readTVarIO senderId1
      nId <- readTVarIO notifierId
      Resp "dabc" _ OK <- signSendRecv h1 nKey ("dabc", nId, NSUB)
      Resp "bcda" _ OK <- signSendRecv h sKey1 ("bcda", sId1, _SEND' "hello")
      Resp "cdab" _ (Msg mId3 msg3) <- signSendRecv h rKey1 ("cdab", rId1, SUB)
      (decryptMsgV3 dh1 mId3 msg3, Right "hello") #== "delivered from restored queue"
      Resp "" _ (NMSG _ _) <- tGet1 h1
      -- this queue is removed - not restored
      sId2 <- readTVarIO senderId2
      Resp "cdab" _ (ERR AUTH) <- signSendRecv h sKey2 ("cdab", sId2, _SEND "hello too")
      pure ()

    logSize testStoreLogFile `shouldReturn` 1
    removeFile testStoreLogFile
  where
    runTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> ThreadId -> Expectation
    runTest _ test' server = do
      testSMPClient test' `shouldReturn` ()
      killThread server

    runClient :: Transport c => TProxy c -> (THandle c -> IO ()) -> Expectation
    runClient _ test' = testSMPClient test' `shouldReturn` ()

logSize :: FilePath -> IO Int
logSize f =
  try (length . B.lines <$> B.readFile f) >>= \case
    Right l -> pure l
    Left (_ :: SomeException) -> logSize f

testRestoreMessages :: ATransport -> Spec
testRestoreMessages at@(ATransport t) =
  it "should store messages on exit and restore on start" $ do
    removeFileIfExists testStoreLogFile
    removeFileIfExists testStoreMsgsFile
    removeFileIfExists testServerStatsBackupFile

    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    recipientId <- newTVarIO ""
    recipientKey <- newTVarIO Nothing
    dhShared <- newTVarIO Nothing
    senderId <- newTVarIO ""

    withSmpServerStoreMsgLogOn at testPort . runTest t $ \h -> do
      runClient t $ \h1 -> do
        (sId, rId, rKey, dh) <- createAndSecureQueue h1 sPub
        atomically $ do
          writeTVar recipientId rId
          writeTVar recipientKey $ Just rKey
          writeTVar dhShared $ Just dh
          writeTVar senderId sId
        Resp "1" _ OK <- signSendRecv h sKey ("1", sId, _SEND "hello")
        Resp "" _ (Msg mId1 msg1) <- tGet1 h1
        Resp "1a" _ OK <- signSendRecv h1 rKey ("1a", rId, ACK mId1)
        (decryptMsgV3 dh mId1 msg1, Right "hello") #== "message delivered"
      -- messages below are delivered after server restart
      sId <- readTVarIO senderId
      Resp "2" _ OK <- signSendRecv h sKey ("2", sId, _SEND "hello 2")
      Resp "3" _ OK <- signSendRecv h sKey ("3", sId, _SEND "hello 3")
      Resp "4" _ OK <- signSendRecv h sKey ("4", sId, _SEND "hello 4")
      Resp "5" _ OK <- signSendRecv h sKey ("5", sId, _SEND "hello 5")
      Resp "6" _ (ERR QUOTA) <- signSendRecv h sKey ("6", sId, _SEND "hello 6")
      pure ()

    rId <- readTVarIO recipientId

    logSize testStoreLogFile `shouldReturn` 2
    logSize testStoreMsgsFile `shouldReturn` 5
    logSize testServerStatsBackupFile `shouldReturn` 16
    Right stats1 <- strDecode <$> B.readFile testServerStatsBackupFile
    checkStats stats1 [rId] 5 1

    withSmpServerStoreMsgLogOn at testPort . runTest t $ \h -> do
      Just rKey <- readTVarIO recipientKey
      Just dh <- readTVarIO dhShared
      let dec = decryptMsgV3 dh
      Resp "2" _ (Msg mId2 msg2) <- signSendRecv h rKey ("2", rId, SUB)
      (dec mId2 msg2, Right "hello 2") #== "restored message delivered"
      Resp "3" _ (Msg mId3 msg3) <- signSendRecv h rKey ("3", rId, ACK mId2)
      (dec mId3 msg3, Right "hello 3") #== "restored message delivered"
      Resp "4" _ (Msg mId4 msg4) <- signSendRecv h rKey ("4", rId, ACK mId3)
      (dec mId4 msg4, Right "hello 4") #== "restored message delivered"

    logSize testStoreLogFile `shouldReturn` 1
    -- the last message is not removed because it was not ACK'd
    logSize testStoreMsgsFile `shouldReturn` 3
    logSize testServerStatsBackupFile `shouldReturn` 16
    Right stats2 <- strDecode <$> B.readFile testServerStatsBackupFile
    checkStats stats2 [rId] 5 3

    withSmpServerStoreMsgLogOn at testPort . runTest t $ \h -> do
      Just rKey <- readTVarIO recipientKey
      Just dh <- readTVarIO dhShared
      let dec = decryptMsgV3 dh
      Resp "4" _ (Msg mId4 msg4) <- signSendRecv h rKey ("4", rId, SUB)
      (dec mId4 msg4, Right "hello 4") #== "restored message delivered"
      Resp "5" _ (Msg mId5 msg5) <- signSendRecv h rKey ("5", rId, ACK mId4)
      (dec mId5 msg5, Right "hello 5") #== "restored message delivered"
      Resp "6" _ (Msg mId6 msg6) <- signSendRecv h rKey ("6", rId, ACK mId5)
      (dec mId6 msg6, Left "ClientRcvMsgQuota") #== "restored message delivered"
      Resp "7" _ OK <- signSendRecv h rKey ("7", rId, ACK mId6)
      pure ()

    logSize testStoreLogFile `shouldReturn` 1
    logSize testStoreMsgsFile `shouldReturn` 0
    logSize testServerStatsBackupFile `shouldReturn` 16
    Right stats3 <- strDecode <$> B.readFile testServerStatsBackupFile
    checkStats stats3 [rId] 5 5

    removeFile testStoreLogFile
    removeFile testStoreMsgsFile
    removeFile testServerStatsBackupFile
  where
    runTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> ThreadId -> Expectation
    runTest _ test' server = do
      testSMPClient test' `shouldReturn` ()
      killThread server

    runClient :: Transport c => TProxy c -> (THandle c -> IO ()) -> Expectation
    runClient _ test' = testSMPClient test' `shouldReturn` ()

checkStats :: ServerStatsData -> [RecipientId] -> Int -> Int -> Expectation
checkStats s qs sent received = do
  _qCreated s `shouldBe` length qs
  _qSecured s `shouldBe` length qs
  _qDeleted s `shouldBe` 0
  _msgSent s `shouldBe` sent
  _msgRecv s `shouldBe` received
  _msgSentNtf s `shouldBe` 0
  _msgRecvNtf s `shouldBe` 0
  let PeriodStatsData {_day, _week, _month} = _activeQueues s
  S.toList _day `shouldBe` qs
  S.toList _week `shouldBe` qs
  S.toList _month `shouldBe` qs

testRestoreMessagesV2 :: ATransport -> Spec
testRestoreMessagesV2 at@(ATransport t) =
  it "should store messages on exit and restore on start" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    recipientId <- newTVarIO ""
    recipientKey <- newTVarIO Nothing
    dhShared <- newTVarIO Nothing
    senderId <- newTVarIO ""

    withSmpServerStoreMsgLogOnV2 at testPort . runTest t $ \h -> do
      runClient t $ \h1 -> do
        (sId, rId, rKey, dh) <- createAndSecureQueue h1 sPub
        atomically $ do
          writeTVar recipientId rId
          writeTVar recipientKey $ Just rKey
          writeTVar dhShared $ Just dh
          writeTVar senderId sId
        Resp "1" _ OK <- signSendRecv h sKey ("1", sId, _SEND "hello")
        Resp "" _ (Msg mId1 msg1) <- tGet1 h1
        Resp "1a" _ OK <- signSendRecv h1 rKey ("1a", rId, ACK mId1)
        (decryptMsgV2 dh mId1 msg1, Right "hello") #== "message delivered"
      -- messages below are delivered after server restart
      sId <- readTVarIO senderId
      Resp "2" _ OK <- signSendRecv h sKey ("2", sId, _SEND "hello 2")
      Resp "3" _ OK <- signSendRecv h sKey ("3", sId, _SEND "hello 3")
      Resp "4" _ OK <- signSendRecv h sKey ("4", sId, _SEND "hello 4")
      pure ()

    logSize testStoreLogFile `shouldReturn` 2
    logSize testStoreMsgsFile `shouldReturn` 3

    withSmpServerStoreMsgLogOnV2 at testPort . runTest t $ \h -> do
      rId <- readTVarIO recipientId
      Just rKey <- readTVarIO recipientKey
      Just dh <- readTVarIO dhShared
      let dec = decryptMsgV2 dh
      Resp "2" _ (Msg mId2 msg2) <- signSendRecv h rKey ("2", rId, SUB)
      (dec mId2 msg2, Right "hello 2") #== "restored message delivered"
      Resp "3" _ (Msg mId3 msg3) <- signSendRecv h rKey ("3", rId, ACK mId2)
      (dec mId3 msg3, Right "hello 3") #== "restored message delivered"
      Resp "4" _ (Msg mId4 msg4) <- signSendRecv h rKey ("4", rId, ACK mId3)
      (dec mId4 msg4, Right "hello 4") #== "restored message delivered"

    logSize testStoreLogFile `shouldReturn` 1
    -- the last message is not removed because it was not ACK'd
    logSize testStoreMsgsFile `shouldReturn` 1

    withSmpServerStoreMsgLogOnV2 at testPort . runTest t $ \h -> do
      rId <- readTVarIO recipientId
      Just rKey <- readTVarIO recipientKey
      Just dh <- readTVarIO dhShared
      Resp "4" _ (Msg mId4 msg4) <- signSendRecv h rKey ("4", rId, SUB)
      Resp "5" _ OK <- signSendRecv h rKey ("5", rId, ACK mId4)
      (decryptMsgV2 dh mId4 msg4, Right "hello 4") #== "restored message delivered"

    logSize testStoreLogFile `shouldReturn` 1
    logSize testStoreMsgsFile `shouldReturn` 0

    removeFile testStoreLogFile
    removeFile testStoreMsgsFile
  where
    runTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> ThreadId -> Expectation
    runTest _ test' server = do
      testSMPClient test' `shouldReturn` ()
      killThread server

    runClient :: Transport c => TProxy c -> (THandle c -> IO ()) -> Expectation
    runClient _ test' = testSMPClient test' `shouldReturn` ()

testRestoreExpireMessages :: ATransport -> Spec
testRestoreExpireMessages at@(ATransport t) =
  it "should store messages on exit and restore on start" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    recipientId <- newTVarIO ""
    recipientKey <- newTVarIO Nothing
    dhShared <- newTVarIO Nothing
    senderId <- newTVarIO ""

    withSmpServerStoreMsgLogOnV2 at testPort . runTest t $ \h -> do
      runClient t $ \h1 -> do
        (sId, rId, rKey, dh) <- createAndSecureQueue h1 sPub
        atomically $ do
          writeTVar recipientId rId
          writeTVar recipientKey $ Just rKey
          writeTVar dhShared $ Just dh
          writeTVar senderId sId
      sId <- readTVarIO senderId
      Resp "1" _ OK <- signSendRecv h sKey ("1", sId, _SEND "hello 1")
      Resp "2" _ OK <- signSendRecv h sKey ("2", sId, _SEND "hello 2")
      threadDelay 3000000
      Resp "3" _ OK <- signSendRecv h sKey ("3", sId, _SEND "hello 3")
      Resp "4" _ OK <- signSendRecv h sKey ("4", sId, _SEND "hello 4")
      pure ()

    logSize testStoreLogFile `shouldReturn` 2
    msgs <- B.readFile testStoreMsgsFile
    length (B.lines msgs) `shouldBe` 4

    let expCfg1 = Just ExpirationConfig {ttl = 86400, checkInterval = 43200}
        cfg1 = cfgV2 {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile, messageExpiration = expCfg1}
    withSmpServerConfigOn at cfg1 testPort . runTest t $ \_ -> pure ()

    logSize testStoreLogFile `shouldReturn` 1
    msgs' <- B.readFile testStoreMsgsFile
    msgs' `shouldBe` msgs

    let expCfg2 = Just ExpirationConfig {ttl = 2, checkInterval = 43200}
        cfg2 = cfgV2 {storeLogFile = Just testStoreLogFile, storeMsgsFile = Just testStoreMsgsFile, messageExpiration = expCfg2}
    withSmpServerConfigOn at cfg2 testPort . runTest t $ \_ -> pure ()

    logSize testStoreLogFile `shouldReturn` 1
    -- two messages expired
    msgs'' <- B.readFile testStoreMsgsFile
    length (B.lines msgs'') `shouldBe` 2
    B.lines msgs'' `shouldBe` drop 2 (B.lines msgs)
  where
    runTest :: Transport c => TProxy c -> (THandle c -> IO ()) -> ThreadId -> Expectation
    runTest _ test' server = do
      testSMPClient test' `shouldReturn` ()
      killThread server

    runClient :: Transport c => TProxy c -> (THandle c -> IO ()) -> Expectation
    runClient _ test' = testSMPClient test' `shouldReturn` ()

createAndSecureQueue :: Transport c => THandle c -> SndPublicVerifyKey -> IO (SenderId, RecipientId, RcvPrivateSignKey, RcvDhSecret)
createAndSecureQueue h sPub = do
  (rPub, rKey) <- C.generateSignatureKeyPair C.SEd448
  (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
  Resp "abcd" "" (Ids rId sId srvDh) <- signSendRecv h rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
  let dhShared = C.dh' srvDh dhPriv
  Resp "dabc" rId' OK <- signSendRecv h rKey ("dabc", rId, KEY sPub)
  (rId', rId) #== "same queue ID"
  pure (sId, rId, rKey, dhShared)

testTiming :: ATransport -> Spec
testTiming (ATransport t) =
  it "should have similar time for auth error, whether queue exists or not, for all key sizes" $
    smpTest2 t $ \rh sh ->
      mapM_ (testSameTiming rh sh) timingTests
  where
    timingTests :: [(Int, Int, Int)]
    timingTests =
      [ (32, 32, 200),
        (32, 57, 100),
        (57, 32, 200),
        (57, 57, 100)
      ]
    timeRepeat n = fmap fst . timeItT . forM_ (replicate n ()) . const
    similarTime t1 t2 = abs (t2 / t1 - 1) < 0.25 `shouldBe` True
    testSameTiming :: Transport c => THandle c -> THandle c -> (Int, Int, Int) -> Expectation
    testSameTiming rh sh (goodKeySize, badKeySize, n) = do
      (rPub, rKey) <- generateKeys goodKeySize
      (dhPub, dhPriv :: C.PrivateKeyX25519) <- C.generateKeyPair'
      Resp "abcd" "" (Ids rId sId srvDh) <- signSendRecv rh rKey ("abcd", "", NEW rPub dhPub Nothing SMSubscribe)
      let dec = decryptMsgV3 $ C.dh' srvDh dhPriv
      Resp "cdab" _ OK <- signSendRecv rh rKey ("cdab", rId, SUB)

      (_, badKey) <- generateKeys badKeySize
      -- runTimingTest rh badKey rId "SUB"

      (sPub, sKey) <- generateKeys goodKeySize
      Resp "dabc" _ OK <- signSendRecv rh rKey ("dabc", rId, KEY sPub)

      Resp "bcda" _ OK <- signSendRecv sh sKey ("bcda", sId, _SEND "hello")
      Resp "" _ (Msg mId msg) <- tGet1 rh
      (dec mId msg, Right "hello") #== "delivered from queue"

      runTimingTest sh badKey sId $ _SEND "hello"
      where
        generateKeys = \case
          32 -> C.generateSignatureKeyPair C.SEd25519
          57 -> C.generateSignatureKeyPair C.SEd448
          _ -> error "unsupported key size"
        runTimingTest h badKey qId cmd = do
          timeWrongKey <- timeRepeat n $ do
            Resp "cdab" _ (ERR AUTH) <- signSendRecv h badKey ("cdab", qId, cmd)
            return ()
          timeNoQueue <- timeRepeat n $ do
            Resp "dabc" _ (ERR AUTH) <- signSendRecv h badKey ("dabc", "1234", cmd)
            return ()
          -- (putStrLn . unwords . map show)
          --   [ fromIntegral goodKeySize,
          --     fromIntegral badKeySize,
          --     timeWrongKey,
          --     timeNoQueue,
          --     timeWrongKey / timeNoQueue - 1
          --   ]
          similarTime timeNoQueue timeWrongKey

testMessageNotifications :: ATransport -> Spec
testMessageNotifications (ATransport t) =
  it "should create simplex connection, subscribe notifier and deliver notifications" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    (nPub, nKey) <- C.generateSignatureKeyPair C.SEd25519
    smpTest4 t $ \rh sh nh1 nh2 -> do
      (sId, rId, rKey, dhShared) <- createAndSecureQueue rh sPub
      let dec = decryptMsgV3 dhShared
      (rcvNtfPubDhKey, _) <- C.generateKeyPair'
      Resp "1" _ (NID nId' _) <- signSendRecv rh rKey ("1", rId, NKEY nPub rcvNtfPubDhKey)
      Resp "1a" _ (NID nId _) <- signSendRecv rh rKey ("1a", rId, NKEY nPub rcvNtfPubDhKey)
      nId' `shouldNotBe` nId
      Resp "2" _ OK <- signSendRecv nh1 nKey ("2", nId, NSUB)
      Resp "3" _ OK <- signSendRecv sh sKey ("3", sId, _SEND' "hello")
      Resp "" _ (Msg mId1 msg1) <- tGet1 rh
      (dec mId1 msg1, Right "hello") #== "delivered from queue"
      Resp "3a" _ OK <- signSendRecv rh rKey ("3a", rId, ACK mId1)
      Resp "" _ (NMSG _ _) <- tGet1 nh1
      Resp "4" _ OK <- signSendRecv nh2 nKey ("4", nId, NSUB)
      Resp "" _ END <- tGet1 nh1
      Resp "5" _ OK <- signSendRecv sh sKey ("5", sId, _SEND' "hello again")
      Resp "" _ (Msg mId2 msg2) <- tGet1 rh
      Resp "5a" _ OK <- signSendRecv rh rKey ("5a", rId, ACK mId2)
      (dec mId2 msg2, Right "hello again") #== "delivered from queue again"
      Resp "" _ (NMSG _ _) <- tGet1 nh2
      1000 `timeout` tGet @ErrorType @BrokerMsg nh1 >>= \case
        Nothing -> pure ()
        Just _ -> error "nothing else should be delivered to the 1st notifier's TCP connection"
      Resp "6" _ OK <- signSendRecv rh rKey ("6", rId, NDEL)
      Resp "7" _ OK <- signSendRecv sh sKey ("7", sId, _SEND' "hello there")
      Resp "" _ (Msg mId3 msg3) <- tGet1 rh
      (dec mId3 msg3, Right "hello there") #== "delivered from queue again"
      1000 `timeout` tGet @ErrorType @BrokerMsg nh2 >>= \case
        Nothing -> pure ()
        Just _ -> error "nothing else should be delivered to the 2nd notifier's TCP connection"

testMsgExpireOnSend :: forall c. Transport c => TProxy c -> Spec
testMsgExpireOnSend t =
  it "should expire messages that are not received before messageTTL on SEND" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    let cfg' = cfg {messageExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 10000}}
    withSmpServerConfigOn (ATransport t) cfg' testPort $ \_ ->
      testSMPClient @c $ \sh -> do
        (sId, rId, rKey, dhShared) <- testSMPClient @c $ \rh -> createAndSecureQueue rh sPub
        let dec = decryptMsgV3 dhShared
        Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello (should expire)")
        threadDelay 2500000
        Resp "2" _ OK <- signSendRecv sh sKey ("2", sId, _SEND "hello (should NOT expire)")
        testSMPClient @c $ \rh -> do
          Resp "3" _ (Msg mId msg) <- signSendRecv rh rKey ("3", rId, SUB)
          (dec mId msg, Right "hello (should NOT expire)") #== "delivered"
          1000 `timeout` tGet @ErrorType @BrokerMsg rh >>= \case
            Nothing -> return ()
            Just _ -> error "nothing else should be delivered"

testMsgExpireOnInterval :: forall c. Transport c => TProxy c -> Spec
testMsgExpireOnInterval t =
  -- fails on ubuntu
  xit' "should expire messages that are not received before messageTTL after expiry interval" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    let cfg' = cfg {messageExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
    withSmpServerConfigOn (ATransport t) cfg' testPort $ \_ ->
      testSMPClient @c $ \sh -> do
        (sId, rId, rKey, _) <- testSMPClient @c $ \rh -> createAndSecureQueue rh sPub
        Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello (should expire)")
        threadDelay 2500000
        testSMPClient @c $ \rh -> do
          signSendRecv rh rKey ("2", rId, SUB) >>= \case
            Resp "2" _ OK -> pure ()
            r -> unexpected r
          1000 `timeout` tGet @ErrorType @BrokerMsg rh >>= \case
            Nothing -> return ()
            Just _ -> error "nothing should be delivered"

testMsgNOTExpireOnInterval :: forall c. Transport c => TProxy c -> Spec
testMsgNOTExpireOnInterval t =
  it "should NOT expire messages that are not received before messageTTL if expiry interval is large" $ do
    (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
    let cfg' = cfg {messageExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 10000}}
    withSmpServerConfigOn (ATransport t) cfg' testPort $ \_ ->
      testSMPClient @c $ \sh -> do
        (sId, rId, rKey, dhShared) <- testSMPClient @c $ \rh -> createAndSecureQueue rh sPub
        let dec = decryptMsgV3 dhShared
        Resp "1" _ OK <- signSendRecv sh sKey ("1", sId, _SEND "hello (should NOT expire)")
        threadDelay 2500000
        testSMPClient @c $ \rh -> do
          Resp "2" _ (Msg mId msg) <- signSendRecv rh rKey ("2", rId, SUB)
          (dec mId msg, Right "hello (should NOT expire)") #== "delivered"
          1000 `timeout` tGet @ErrorType @BrokerMsg rh >>= \case
            Nothing -> return ()
            Just _ -> error "nothing else should be delivered"

samplePubKey :: C.APublicVerifyKey
samplePubKey = C.APublicVerifyKey C.SEd25519 "MCowBQYDK2VwAyEAfAOflyvbJv1fszgzkQ6buiZJVgSpQWsucXq7U6zjMgY="

sampleDhPubKey :: C.PublicKey 'C.X25519
sampleDhPubKey = "MCowBQYDK2VuAyEAriy+HcARIhqsgSjVnjKqoft+y6pxrxdY68zn4+LjYhQ="

sampleSig :: Maybe C.ASignature
sampleSig = "e8JK+8V3fq6kOLqco/SaKlpNaQ7i1gfOrXoqekEl42u4mF8Bgu14T5j0189CGcUhJHw2RwCMvON+qbvQ9ecJAA=="

noAuth :: (Char, Maybe BasicAuth)
noAuth = ('A', Nothing)

syntaxTests :: ATransport -> Spec
syntaxTests (ATransport t) = do
  it "unknown command" $ ("", "abcd", "1234", ('H', 'E', 'L', 'L', 'O')) >#> ("", "abcd", "1234", ERR $ CMD UNKNOWN)
  describe "NEW" $ do
    it "no parameters" $ (sampleSig, "bcda", "", NEW_) >#> ("", "bcda", "", ERR $ CMD SYNTAX)
    it "many parameters" $ (sampleSig, "cdab", "", (NEW_, ' ', ('\x01', 'A'), samplePubKey, sampleDhPubKey)) >#> ("", "cdab", "", ERR $ CMD SYNTAX)
    it "no signature" $ ("", "dabc", "", (NEW_, ' ', samplePubKey, sampleDhPubKey, SMSubscribe)) >#> ("", "dabc", "", ERR $ CMD NO_AUTH)
    it "queue ID" $ (sampleSig, "abcd", "12345678", (NEW_, ' ', samplePubKey, sampleDhPubKey, SMSubscribe)) >#> ("", "abcd", "12345678", ERR $ CMD HAS_AUTH)
  describe "KEY" $ do
    it "valid syntax" $ (sampleSig, "bcda", "12345678", (KEY_, ' ', samplePubKey)) >#> ("", "bcda", "12345678", ERR AUTH)
    it "no parameters" $ (sampleSig, "cdab", "12345678", KEY_) >#> ("", "cdab", "12345678", ERR $ CMD SYNTAX)
    it "many parameters" $ (sampleSig, "dabc", "12345678", (KEY_, ' ', ('\x01', 'A'), samplePubKey)) >#> ("", "dabc", "12345678", ERR $ CMD SYNTAX)
    it "no signature" $ ("", "abcd", "12345678", (KEY_, ' ', samplePubKey)) >#> ("", "abcd", "12345678", ERR $ CMD NO_AUTH)
    it "no queue ID" $ (sampleSig, "bcda", "", (KEY_, ' ', samplePubKey)) >#> ("", "bcda", "", ERR $ CMD NO_AUTH)
  noParamsSyntaxTest "SUB" SUB_
  noParamsSyntaxTest "OFF" OFF_
  noParamsSyntaxTest "DEL" DEL_
  describe "SEND" $ do
    it "valid syntax" $ (sampleSig, "cdab", "12345678", (SEND_, ' ', noMsgFlags, ' ', "hello" :: ByteString)) >#> ("", "cdab", "12345678", ERR AUTH)
    it "no parameters" $ (sampleSig, "abcd", "12345678", SEND_) >#> ("", "abcd", "12345678", ERR $ CMD SYNTAX)
    it "no queue ID" $ (sampleSig, "bcda", "", (SEND_, ' ', noMsgFlags, ' ', "hello" :: ByteString)) >#> ("", "bcda", "", ERR $ CMD NO_ENTITY)
  describe "ACK" $ do
    it "valid syntax" $ (sampleSig, "cdab", "12345678", (ACK_, ' ', "1234" :: ByteString)) >#> ("", "cdab", "12345678", ERR AUTH)
    it "no parameters" $ (sampleSig, "abcd", "12345678", ACK_) >#> ("", "abcd", "12345678", ERR $ CMD SYNTAX)
    it "no queue ID" $ (sampleSig, "bcda", "", (ACK_, ' ', "1234" :: ByteString)) >#> ("", "bcda", "", ERR $ CMD NO_AUTH)
    it "no signature" $ ("", "cdab", "12345678", (ACK_, ' ', "1234" :: ByteString)) >#> ("", "cdab", "12345678", ERR $ CMD NO_AUTH)
  describe "PING" $ do
    it "valid syntax" $ ("", "abcd", "", PING_) >#> ("", "abcd", "", PONG)
  describe "broker response not allowed" $ do
    it "OK" $ (sampleSig, "bcda", "12345678", OK_) >#> ("", "bcda", "12345678", ERR $ CMD UNKNOWN)
  where
    noParamsSyntaxTest :: PartyI p => String -> CommandTag p -> Spec
    noParamsSyntaxTest description cmd = describe description $ do
      it "valid syntax" $ (sampleSig, "abcd", "12345678", cmd) >#> ("", "abcd", "12345678", ERR AUTH)
      it "wrong terminator" $ (sampleSig, "bcda", "12345678", (cmd, '=')) >#> ("", "bcda", "12345678", ERR $ CMD UNKNOWN)
      it "no signature" $ ("", "cdab", "12345678", cmd) >#> ("", "cdab", "12345678", ERR $ CMD NO_AUTH)
      it "no queue ID" $ (sampleSig, "dabc", "", cmd) >#> ("", "dabc", "", ERR $ CMD NO_AUTH)
    (>#>) ::
      Encoding smp =>
      (Maybe C.ASignature, ByteString, ByteString, smp) ->
      (Maybe C.ASignature, ByteString, ByteString, BrokerMsg) ->
      Expectation
    command >#> response = withFrozenCallStack $ smpServerTest t command `shouldReturn` response
