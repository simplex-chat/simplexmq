{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module ServerTests where

import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPClient
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import System.Timeout
import Test.HUnit
import Test.Hspec

rsaKeySize :: Int
rsaKeySize = 1024 `div` 8

serverTests :: Spec
serverTests = do
  xdescribe "SMP syntax" syntaxTests
  xdescribe "SMP queues" do
    describe "NEW and KEY commands, SEND messages" testCreateSecure
    describe "NEW, OFF and DEL commands, SEND messages" testCreateDelete
  xdescribe "SMP messages" do
    describe "duplex communication over 2 SMP connections" testDuplex
    describe "switch subscription to another SMP queue" testSwitchSub

pattern Resp :: CorrId -> QueueId -> Command 'Broker -> SignedTransmissionOrError
pattern Resp corrId queueId command <- ("", (corrId, queueId, Right (Cmd SBroker command)))

sendRecv :: THandle -> (ByteString, ByteString, ByteString, ByteString) -> IO SignedTransmissionOrError
sendRecv h (sgn, corrId, qId, cmd) = tPutRaw h (sgn, corrId, encode qId, cmd) >> tGet fromServer h

signSendRecv :: THandle -> C.PrivateKey -> (ByteString, ByteString, ByteString) -> IO SignedTransmissionOrError
signSendRecv h pk (corrId, qId, cmd) = do
  let t = B.intercalate "\r\n" [corrId, encode qId, cmd]
  Right sig <- C.sign pk t
  _ <- tPut h (sig, t)
  tGet fromServer h

cmdSEND :: ByteString -> ByteString
cmdSEND msg = serializeCommand (Cmd SSender . SEND $ msg)

(>#>) :: RawTransmission -> RawTransmission -> Expectation
command >#> response = smpServerTest command `shouldReturn` response

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

testCreateSecure :: Spec
testCreateSecure =
  it "should create (NEW) and secure (KEY) queue" $
    smpTest \h -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" rId1 (IDS rId sId) <- signSendRecv h rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      (rId1, "") #== "creates queue"

      Resp "bcda" sId1 ok1 <- sendRecv h ("", "bcda", sId, "SEND 5\r\nhello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp "cdab" _ ok4 <- signSendRecv h rKey ("cdab", rId, "ACK")
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp "dabc" _ err6 <- signSendRecv h rKey ("dabc", rId, "ACK")
      (err6, ERR PROHIBITED) #== "replies ERR when message acknowledged without messages"

      (sPub, sKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" sId2 err1 <- signSendRecv h sKey ("abcd", sId, "SEND 5\r\nhello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      let keyCmd = "KEY " <> C.serializePubKey sPub
      Resp "bcda" _ err2 <- sendRecv h ("12345678", "bcda", rId, keyCmd)
      (err2, ERR AUTH) #== "rejects KEY with wrong signature"

      Resp "cdab" _ err3 <- signSendRecv h rKey ("cdab", sId, keyCmd)
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp "dabc" rId2 ok2 <- signSendRecv h rKey ("dabc", rId, keyCmd)
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp "abcd" _ err4 <- signSendRecv h rKey ("abcd", rId, keyCmd)
      (err4, ERR AUTH) #== "rejects KEY if already secured"

      Resp "bcda" _ ok3 <- signSendRecv h sKey ("bcda", sId, "SEND 11\r\nhello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp "" _ (MSG _ _ msg) <- tGet fromServer h
      (msg, "hello again") #== "delivers message 2"

      Resp "cdab" _ ok5 <- signSendRecv h rKey ("cdab", rId, "ACK")
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp "dabc" _ err5 <- sendRecv h ("", "dabc", sId, "SEND 5\r\nhello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: Spec
testCreateDelete =
  it "should create (NEW), suspend (OFF) and delete (DEL) queue" $
    smpTest2 \rh sh -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" rId1 (IDS rId sId) <- signSendRecv rh rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      (rId1, "") #== "creates queue"

      (sPub, sKey) <- C.generateKeyPair rsaKeySize
      Resp "bcda" _ ok1 <- signSendRecv rh rKey ("bcda", rId, "KEY " <> C.serializePubKey sPub)
      (ok1, OK) #== "secures queue"

      Resp "cdab" _ ok2 <- signSendRecv sh sKey ("cdab", sId, "SEND 5\r\nhello")
      (ok2, OK) #== "accepts signed SEND"

      Resp "dabc" _ ok7 <- signSendRecv sh sKey ("dabc", sId, "SEND 7\r\nhello 2")
      (ok7, OK) #== "accepts signed SEND 2 - this message is not delivered because the first is not ACKed"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh
      (msg1, "hello") #== "delivers message"

      Resp "abcd" _ err1 <- sendRecv rh ("12345678", "abcd", rId, "OFF")
      (err1, ERR AUTH) #== "rejects OFF with wrong signature"

      Resp "bcda" _ err2 <- signSendRecv rh rKey ("bcda", sId, "OFF")
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp "cdab" rId2 ok3 <- signSendRecv rh rKey ("cdab", rId, "OFF")
      (ok3, OK) #== "suspends queue"
      (rId2, rId) #== "same queue ID in response 2"

      Resp "dabc" _ err3 <- signSendRecv sh sKey ("dabc", sId, "SEND 5\r\nhello")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp "abcd" _ err4 <- sendRecv sh ("", "abcd", sId, "SEND 5\r\nhello")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp "bcda" _ ok4 <- signSendRecv rh rKey ("bcda", rId, "OFF")
      (ok4, OK) #== "accepts OFF when suspended"

      Resp "cdab" _ (MSG _ _ msg) <- signSendRecv rh rKey ("cdab", rId, "SUB")
      (msg, "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp "dabc" _ err5 <- sendRecv rh ("12345678", "dabc", rId, "DEL")
      (err5, ERR AUTH) #== "rejects DEL with wrong signature"

      Resp "abcd" _ err6 <- signSendRecv rh rKey ("abcd", sId, "DEL")
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp "bcda" rId3 ok6 <- signSendRecv rh rKey ("bcda", rId, "DEL")
      (ok6, OK) #== "deletes queue"
      (rId3, rId) #== "same queue ID in response 3"

      Resp "cdab" _ err7 <- signSendRecv sh sKey ("cdab", sId, "SEND 5\r\nhello")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp "dabc" _ err8 <- sendRecv sh ("", "dabc", sId, "SEND 5\r\nhello")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp "abcd" _ err11 <- signSendRecv rh rKey ("abcd", rId, "ACK")
      (err11, ERR AUTH) #== "rejects ACK when conn deleted - the second message is deleted"

      Resp "bcda" _ err9 <- signSendRecv rh rKey ("bcda", rId, "OFF")
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp "cdab" _ err10 <- signSendRecv rh rKey ("cdab", rId, "SUB")
      (err10, ERR AUTH) #== "rejects SUB when deleted"

testDuplex :: Spec
testDuplex =
  it "should create 2 simplex connections and exchange messages" $
    smpTest2 \alice bob -> do
      (arPub, arKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS aRcv aSnd) <- signSendRecv alice arKey ("abcd", "", "NEW " <> C.serializePubKey arPub)
      -- aSnd ID is passed to Bob out-of-band

      (bsPub, bsKey) <- C.generateKeyPair rsaKeySize
      Resp "bcda" _ OK <- sendRecv bob ("", "bcda", aSnd, cmdSEND $ "key " <> C.serializePubKey bsPub)
      -- "key ..." is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, "ACK")
      ["key", bobKey] <- return $ B.words msg1
      (bobKey, C.serializePubKey bsPub) #== "key received from Bob"
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, "KEY " <> bobKey)

      (brPub, brKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS bRcv bSnd) <- signSendRecv bob brKey ("abcd", "", "NEW " <> C.serializePubKey brPub)
      Resp "bcda" _ OK <- signSendRecv bob bsKey ("bcda", aSnd, cmdSEND $ "reply_id " <> encode bSnd)
      -- "reply_id ..." is ad-hoc, it is not a part of SMP protocol

      Resp "" _ (MSG _ _ msg2) <- tGet fromServer alice
      Resp "cdab" _ OK <- signSendRecv alice arKey ("cdab", aRcv, "ACK")
      ["reply_id", bId] <- return $ B.words msg2
      (bId, encode bSnd) #== "reply queue ID received from Bob"

      (asPub, asKey) <- C.generateKeyPair rsaKeySize
      Resp "dabc" _ OK <- sendRecv alice ("", "dabc", bSnd, cmdSEND $ "key " <> C.serializePubKey asPub)
      -- "key ..." is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer bob
      Resp "abcd" _ OK <- signSendRecv bob brKey ("abcd", bRcv, "ACK")
      ["key", aliceKey] <- return $ B.words msg3
      (aliceKey, C.serializePubKey asPub) #== "key received from Alice"
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, "KEY " <> aliceKey)

      Resp "cdab" _ OK <- signSendRecv bob bsKey ("cdab", aSnd, "SEND 8\r\nhi alice")

      Resp "" _ (MSG _ _ msg4) <- tGet fromServer alice
      Resp "dabc" _ OK <- signSendRecv alice arKey ("dabc", aRcv, "ACK")
      (msg4, "hi alice") #== "message received from Bob"

      Resp "abcd" _ OK <- signSendRecv alice asKey ("abcd", bSnd, cmdSEND "how are you bob")

      Resp "" _ (MSG _ _ msg5) <- tGet fromServer bob
      Resp "bcda" _ OK <- signSendRecv bob brKey ("bcda", bRcv, "ACK")
      (msg5, "how are you bob") #== "message received from alice"

testSwitchSub :: Spec
testSwitchSub =
  it "should create simplex connections and switch subscription to another TCP connection" $
    smpTest3 \rh1 rh2 sh -> do
      (rPub, rKey) <- C.generateKeyPair rsaKeySize
      Resp "abcd" _ (IDS rId sId) <- signSendRecv rh1 rKey ("abcd", "", "NEW " <> C.serializePubKey rPub)
      Resp "bcda" _ ok1 <- sendRecv sh ("", "bcda", sId, "SEND 5\r\ntest1")
      (ok1, OK) #== "sent test message 1"
      Resp "cdab" _ ok2 <- sendRecv sh ("", "cdab", sId, cmdSEND "test2, no ACK")
      (ok2, OK) #== "sent test message 2"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh1
      (msg1, "test1") #== "test message 1 delivered to the 1st TCP connection"
      Resp "abcd" _ (MSG _ _ msg2) <- signSendRecv rh1 rKey ("abcd", rId, "ACK")
      (msg2, "test2, no ACK") #== "test message 2 delivered, no ACK"

      Resp "bcda" _ (MSG _ _ msg2') <- signSendRecv rh2 rKey ("bcda", rId, "SUB")
      (msg2', "test2, no ACK") #== "same simplex queue via another TCP connection, tes2 delivered again (no ACK in 1st queue)"
      Resp "cdab" _ OK <- signSendRecv rh2 rKey ("cdab", rId, "ACK")

      Resp "" _ end <- tGet fromServer rh1
      (end, END) #== "unsubscribed the 1st TCP connection"

      Resp "dabc" _ OK <- sendRecv sh ("", "dabc", sId, "SEND 5\r\ntest3")

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer rh2
      (msg3, "test3") #== "delivered to the 2nd TCP connection"

      Resp "abcd" _ err <- signSendRecv rh1 rKey ("abcd", rId, "ACK")
      (err, ERR PROHIBITED) #== "rejects ACK from the 1st TCP connection"

      Resp "bcda" _ ok3 <- signSendRecv rh2 rKey ("bcda", rId, "ACK")
      (ok3, OK) #== "accepts ACK from the 2nd TCP connection"

      1000 `timeout` tGet fromServer rh1 >>= \case
        Nothing -> return ()
        Just _ -> error "nothing else is delivered to the 1st TCP connection"

syntaxTests :: Spec
syntaxTests = do
  it "unknown command" $ ("", "abcd", "1234", "HELLO") >#> ("", "abcd", "1234", "ERR SYNTAX 2")
  describe "NEW" do
    it "no parameters" $ ("1234", "bcda", "", "NEW") >#> ("", "bcda", "", "ERR SYNTAX 2")
    it "many parameters" $ ("1234", "cdab", "", "NEW 1 2") >#> ("", "cdab", "", "ERR SYNTAX 2")
    it "no signature" $ ("", "dabc", "", "NEW 3,1234,1234") >#> ("", "dabc", "", "ERR SYNTAX 3")
    it "queue ID" $ ("1234", "abcd", "12345678", "NEW 3,1234,1234") >#> ("", "abcd", "12345678", "ERR SYNTAX 4")
  describe "KEY" do
    it "valid syntax" $ ("1234", "bcda", "12345678", "KEY 3,4567,4567") >#> ("", "bcda", "12345678", "ERR AUTH")
    it "no parameters" $ ("1234", "cdab", "12345678", "KEY") >#> ("", "cdab", "12345678", "ERR SYNTAX 2")
    it "many parameters" $ ("1234", "dabc", "12345678", "KEY 1 2") >#> ("", "dabc", "12345678", "ERR SYNTAX 2")
    it "no signature" $ ("", "abcd", "12345678", "KEY 3,4567,4567") >#> ("", "abcd", "12345678", "ERR SYNTAX 3")
    it "no queue ID" $ ("1234", "bcda", "", "KEY 3,4567,4567") >#> ("", "bcda", "", "ERR SYNTAX 3")
  noParamsSyntaxTest "SUB"
  noParamsSyntaxTest "ACK"
  noParamsSyntaxTest "OFF"
  noParamsSyntaxTest "DEL"
  describe "SEND" do
    it "valid syntax 1" $ ("1234", "cdab", "12345678", "SEND 5\r\nhello") >#> ("", "cdab", "12345678", "ERR AUTH")
    it "valid syntax 2" $ ("1234", "dabc", "12345678", "SEND 11\r\nhello there") >#> ("", "dabc", "12345678", "ERR AUTH")
    it "no parameters" $ ("1234", "abcd", "12345678", "SEND") >#> ("", "abcd", "12345678", "ERR SYNTAX 2")
    it "no queue ID" $ ("1234", "bcda", "", "SEND 5\r\nhello") >#> ("", "bcda", "", "ERR SYNTAX 5")
    it "bad message body 1" $ ("1234", "cdab", "12345678", "SEND 11 hello") >#> ("", "cdab", "12345678", "ERR SYNTAX 2")
    it "bad message body 2" $ ("1234", "dabc", "12345678", "SEND hello") >#> ("", "dabc", "12345678", "ERR SYNTAX 2")
    it "bigger body" $ ("1234", "abcd", "12345678", "SEND 4\r\nhello") >#> ("", "abcd", "12345678", "ERR SIZE")
  describe "PING" do
    it "valid syntax" $ ("", "abcd", "", "PING") >#> ("", "abcd", "", "PONG")
  describe "broker response not allowed" do
    it "OK" $ ("1234", "bcda", "12345678", "OK") >#> ("", "bcda", "12345678", "ERR PROHIBITED")
  where
    noParamsSyntaxTest :: ByteString -> Spec
    noParamsSyntaxTest cmd = describe (B.unpack cmd) do
      it "valid syntax" $ ("1234", "abcd", "12345678", cmd) >#> ("", "abcd", "12345678", "ERR AUTH")
      it "parameters" $ ("1234", "bcda", "12345678", cmd <> " 1") >#> ("", "bcda", "12345678", "ERR SYNTAX 2")
      it "no signature" $ ("", "cdab", "12345678", cmd) >#> ("", "cdab", "12345678", "ERR SYNTAX 3")
      it "no queue ID" $ ("1234", "dabc", "", cmd) >#> ("", "dabc", "", "ERR SYNTAX 3")
