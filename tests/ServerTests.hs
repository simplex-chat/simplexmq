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
import Simplex.Messaging.Types
import System.IO (Handle)
import System.Timeout
import Test.HUnit
import Test.Hspec

serverTests :: Spec
serverTests = do
  describe "SMP syntax" syntaxTests
  describe "SMP queues" do
    describe "NEW and KEY commands, SEND messages" testCreateSecure
    describe "NEW, OFF and DEL commands, SEND messages" testCreateDelete
  describe "SMP messages" do
    describe "duplex communication over 2 SMP connections" testDuplex
    describe "switch subscription to another SMP queue" testSwitchSub

pattern Resp :: CorrId -> QueueId -> Command 'Broker -> SignedTransmissionOrError
pattern Resp corrId queueId command <- (C.Signature "", (corrId, queueId, Right (Cmd SBroker command)))

sendRecv :: Handle -> (ByteString, ByteString, ByteString, ByteString) -> IO SignedTransmissionOrError
sendRecv h (sgn, corrId, qId, cmd) = tPutRaw h (sgn, corrId, encode qId, cmd) >> tGet fromServer h

(>#>) :: RawTransmission -> RawTransmission -> Expectation
command >#> response = smpServerTest command `shouldReturn` response

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

testCreateSecure :: Spec
testCreateSecure =
  it "should create (NEW) and secure (KEY) queue" $
    smpTest \h -> do
      Resp "abcd" rId1 (IDS rId sId) <- sendRecv h ("1234", "abcd", "", "NEW 3,1234,1234")
      (rId1, "") #== "creates queue"

      Resp "bcda" sId1 ok1 <- sendRecv h ("", "bcda", sId, "SEND :hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp "cdab" _ ok4 <- sendRecv h ("1234", "cdab", rId, "ACK")
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp "dabc" _ err6 <- sendRecv h ("1234", "dabc", rId, "ACK")
      (err6, ERR PROHIBITED) #== "replies ERR when message acknowledged without messages"

      Resp "abcd" sId2 err1 <- sendRecv h ("4567", "abcd", sId, "SEND :hello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      Resp "bcda" _ err2 <- sendRecv h ("12345678", "bcda", rId, "KEY 3,4567,4567")
      (err2, ERR AUTH) #== "rejects KEY with wrong signature (password atm)"

      Resp "cdab" _ err3 <- sendRecv h ("1234", "cdab", sId, "KEY 3,4567,4567")
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp "dabc" rId2 ok2 <- sendRecv h ("1234", "dabc", rId, "KEY 3,4567,4567")
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp "abcd" _ err4 <- sendRecv h ("1234", "abcd", rId, "KEY 3,4567,4567")
      (err4, ERR AUTH) #== "rejects KEY if already secured"

      Resp "bcda" _ ok3 <- sendRecv h ("4567", "bcda", sId, "SEND 11\nhello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp "" _ (MSG _ _ msg) <- tGet fromServer h
      (msg, "hello again") #== "delivers message 2"

      Resp "cdab" _ ok5 <- sendRecv h ("1234", "cdab", rId, "ACK")
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp "dabc" _ err5 <- sendRecv h ("", "dabc", sId, "SEND :hello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: Spec
testCreateDelete =
  it "should create (NEW), suspend (OFF) and delete (DEL) queue" $
    smpTest2 \rh sh -> do
      Resp "abcd" rId1 (IDS rId sId) <- sendRecv rh ("1234", "abcd", "", "NEW 3,1234,1234")
      (rId1, "") #== "creates queue"

      Resp "bcda" _ ok1 <- sendRecv rh ("1234", "bcda", rId, "KEY 3,4567,4567")
      (ok1, OK) #== "secures queue"

      Resp "cdab" _ ok2 <- sendRecv sh ("4567", "cdab", sId, "SEND :hello")
      (ok2, OK) #== "accepts signed SEND"

      Resp "dabc" _ ok7 <- sendRecv sh ("4567", "dabc", sId, "SEND :hello 2")
      (ok7, OK) #== "accepts signed SEND 2 - this message is not delivered because the first is not ACKed"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh
      (msg1, "hello") #== "delivers message"

      Resp "abcd" _ err1 <- sendRecv rh ("12345678", "abcd", rId, "OFF")
      (err1, ERR AUTH) #== "rejects OFF with wrong signature (password atm)"

      Resp "bcda" _ err2 <- sendRecv rh ("1234", "bcda", sId, "OFF")
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp "cdab" rId2 ok3 <- sendRecv rh ("1234", "cdab", rId, "OFF")
      (ok3, OK) #== "suspends queue"
      (rId2, rId) #== "same queue ID in response 2"

      Resp "dabc" _ err3 <- sendRecv sh ("4567", "dabc", sId, "SEND :hello")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp "abcd" _ err4 <- sendRecv sh ("", "abcd", sId, "SEND :hello")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp "bcda" _ ok4 <- sendRecv rh ("1234", "bcda", rId, "OFF")
      (ok4, OK) #== "accepts OFF when suspended"

      Resp "cdab" _ (MSG _ _ msg) <- sendRecv rh ("1234", "cdab", rId, "SUB")
      (msg, "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp "dabc" _ err5 <- sendRecv rh ("12345678", "dabc", rId, "DEL")
      (err5, ERR AUTH) #== "rejects DEL with wrong signature (password atm)"

      Resp "abcd" _ err6 <- sendRecv rh ("1234", "abcd", sId, "DEL")
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp "bcda" rId3 ok6 <- sendRecv rh ("1234", "bcda", rId, "DEL")
      (ok6, OK) #== "deletes queue"
      (rId3, rId) #== "same queue ID in response 3"

      Resp "cdab" _ err7 <- sendRecv sh ("4567", "cdab", sId, "SEND :hello")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp "dabc" _ err8 <- sendRecv sh ("", "dabc", sId, "SEND :hello")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp "abcd" _ err11 <- sendRecv rh ("1234", "abcd", rId, "ACK")
      (err11, ERR AUTH) #== "rejects ACK when conn deleted - the second message is deleted"

      Resp "bcda" _ err9 <- sendRecv rh ("1234", "bcda", rId, "OFF")
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp "cdab" _ err10 <- sendRecv rh ("1234", "cdab", rId, "SUB")
      (err10, ERR AUTH) #== "rejects SUB when deleted"

testDuplex :: Spec
testDuplex =
  it "should create 2 simplex connections and exchange messages" $
    smpTest2 \alice bob -> do
      Resp "abcd" _ (IDS aRcv aSnd) <- sendRecv alice ("1234", "abcd", "", "NEW 3,1234,1234")
      -- aSnd ID is passed to Bob out-of-band

      Resp "bcda" _ OK <- sendRecv bob ("", "bcda", aSnd, "SEND :key 3,efgh,efgh")
      -- "key efgh" is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer alice
      Resp "cdab" _ OK <- sendRecv alice ("1234", "cdab", aRcv, "ACK")
      ["key", key1] <- return $ B.words msg1
      (key1, "3,efgh,efgh") #== "key received from Bob"
      Resp "dabc" _ OK <- sendRecv alice ("1234", "dabc", aRcv, "KEY " <> key1)

      Resp "abcd" _ (IDS bRcv bSnd) <- sendRecv bob ("abcd", "abcd", "", "NEW 3,abcd,abcd")
      Resp "bcda" _ OK <- sendRecv bob ("efgh", "bcda", aSnd, "SEND :reply_id " <> encode bSnd)
      -- "reply_id ..." is ad-hoc, it is not a part of SMP protocol

      Resp "" _ (MSG _ _ msg2) <- tGet fromServer alice
      Resp "cdab" _ OK <- sendRecv alice ("1234", "cdab", aRcv, "ACK")
      ["reply_id", bId] <- return $ B.words msg2
      (bId, encode bSnd) #== "reply queue ID received from Bob"
      Resp "dabc" _ OK <- sendRecv alice ("", "dabc", bSnd, "SEND :key 3,5678,5678")
      -- "key 5678" is ad-hoc, different from SMP protocol

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer bob
      Resp "abcd" _ OK <- sendRecv bob ("abcd", "abcd", bRcv, "ACK")
      ["key", key2] <- return $ B.words msg3
      (key2, "3,5678,5678") #== "key received from Alice"
      Resp "bcda" _ OK <- sendRecv bob ("abcd", "bcda", bRcv, "KEY " <> key2)

      Resp "cdab" _ OK <- sendRecv bob ("efgh", "cdab", aSnd, "SEND :hi alice")

      Resp "" _ (MSG _ _ msg4) <- tGet fromServer alice
      Resp "dabc" _ OK <- sendRecv alice ("1234", "dabc", aRcv, "ACK")
      (msg4, "hi alice") #== "message received from Bob"

      Resp "abcd" _ OK <- sendRecv alice ("5678", "abcd", bSnd, "SEND :how are you bob")

      Resp "" _ (MSG _ _ msg5) <- tGet fromServer bob
      Resp "bcda" _ OK <- sendRecv bob ("abcd", "bcda", bRcv, "ACK")
      (msg5, "how are you bob") #== "message received from alice"

testSwitchSub :: Spec
testSwitchSub =
  it "should create simplex connections and switch subscription to another TCP connection" $
    smpTest3 \rh1 rh2 sh -> do
      Resp "abcd" _ (IDS rId sId) <- sendRecv rh1 ("1234", "abcd", "", "NEW 3,1234,1234")
      Resp "bcda" _ ok1 <- sendRecv sh ("", "bcda", sId, "SEND :test1")
      (ok1, OK) #== "sent test message 1"
      Resp "cdab" _ ok2 <- sendRecv sh ("", "cdab", sId, "SEND :test2, no ACK")
      (ok2, OK) #== "sent test message 2"

      Resp "" _ (MSG _ _ msg1) <- tGet fromServer rh1
      (msg1, "test1") #== "test message 1 delivered to the 1st TCP connection"
      Resp "abcd" _ (MSG _ _ msg2) <- sendRecv rh1 ("1234", "abcd", rId, "ACK")
      (msg2, "test2, no ACK") #== "test message 2 delivered, no ACK"

      Resp "bcda" _ (MSG _ _ msg2') <- sendRecv rh2 ("1234", "bcda", rId, "SUB")
      (msg2', "test2, no ACK") #== "same simplex queue via another TCP connection, tes2 delivered again (no ACK in 1st queue)"
      Resp "cdab" _ OK <- sendRecv rh2 ("1234", "cdab", rId, "ACK")

      Resp "" _ end <- tGet fromServer rh1
      (end, END) #== "unsubscribed the 1st TCP connection"

      Resp "dabc" _ OK <- sendRecv sh ("", "dabc", sId, "SEND :test3")

      Resp "" _ (MSG _ _ msg3) <- tGet fromServer rh2
      (msg3, "test3") #== "delivered to the 2nd TCP connection"

      Resp "abcd" _ err <- sendRecv rh1 ("1234", "abcd", rId, "ACK")
      (err, ERR PROHIBITED) #== "rejects ACK from the 1st TCP connection"

      Resp "bcda" _ ok3 <- sendRecv rh2 ("1234", "bcda", rId, "ACK")
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
    it "valid syntax 1" $ ("1234", "cdab", "12345678", "SEND :hello") >#> ("", "cdab", "12345678", "ERR AUTH")
    it "valid syntax 2" $ ("1234", "dabc", "12345678", "SEND 11\nhello there\n") >#> ("", "dabc", "12345678", "ERR AUTH")
    it "no parameters" $ ("1234", "abcd", "12345678", "SEND") >#> ("", "abcd", "12345678", "ERR SYNTAX 2")
    it "no queue ID" $ ("1234", "bcda", "", "SEND :hello") >#> ("", "bcda", "", "ERR SYNTAX 5")
    it "bad message body 1" $ ("1234", "cdab", "12345678", "SEND 11 hello") >#> ("", "cdab", "12345678", "ERR SYNTAX 6")
    it "bad message body 2" $ ("1234", "dabc", "12345678", "SEND hello") >#> ("", "dabc", "12345678", "ERR SYNTAX 6")
    it "bigger body" $ ("1234", "abcd", "12345678", "SEND 4\nhello\n") >#> ("", "abcd", "12345678", "ERR SIZE")
  describe "broker response not allowed" do
    it "OK" $ ("1234", "bcda", "12345678", "OK") >#> ("", "bcda", "12345678", "ERR PROHIBITED")
  where
    noParamsSyntaxTest :: ByteString -> Spec
    noParamsSyntaxTest cmd = describe (B.unpack cmd) do
      it "valid syntax" $ ("1234", "abcd", "12345678", cmd) >#> ("", "abcd", "12345678", "ERR AUTH")
      it "parameters" $ ("1234", "bcda", "12345678", cmd <> " 1") >#> ("", "bcda", "12345678", "ERR SYNTAX 2")
      it "no signature" $ ("", "cdab", "12345678", cmd) >#> ("", "cdab", "12345678", "ERR SYNTAX 3")
      it "no queue ID" $ ("1234", "dabc", "", cmd) >#> ("", "dabc", "", "ERR SYNTAX 3")
