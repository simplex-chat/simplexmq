{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either
import SMPClient
import Simplex.Messaging.Server.Transmission
import Simplex.Messaging.Transport
import System.IO (Handle)
import System.Timeout
import Test.HUnit
import Test.Hspec

main :: IO ()
main = hspec do
  describe "SMP syntax" syntaxTests
  describe "SMP queues" do
    describe "NEW and KEY commands, SEND messages" testCreateSecure
    describe "NEW, OFF and DEL commands, SEND messages" testCreateDelete
  describe "SMP messages" do
    describe "duplex communication over 2 SMP connections" testDuplex
    describe "switch subscription to another SMP queue" testSwitchSub

pattern Resp :: QueueId -> Command 'Broker -> TransmissionOrError
pattern Resp queueId command = ("", (queueId, Right (Cmd SBroker command)))

sendRecv :: Handle -> RawTransmission -> IO TransmissionOrError
sendRecv h (sgn, qId, cmd) = tPutRaw h (fromRight "" $ decode sgn, qId, cmd) >> tGet fromServer h

(>#>) :: [RawTransmission] -> [RawTransmission] -> Expectation
commands >#> responses = smpServerTest commands `shouldReturn` responses

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

testCreateSecure :: SpecWith ()
testCreateSecure =
  it "should create (NEW) and secure (KEY) queue" $
    smpTest \h -> do
      Resp rId1 (IDS rId sId) <- sendRecv h ("", "", "NEW 1234")
      (rId1, "") #== "creates queue"

      Resp sId1 ok1 <- sendRecv h ("", sId, "SEND :hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same queue ID in response 1"

      Resp _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp _ ok4 <- sendRecv h ("1234", rId, "ACK")
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp _ err6 <- sendRecv h ("1234", rId, "ACK")
      (err6, ERR PROHIBITED) #== "replies ERR when message acknowledged without messages"

      Resp sId2 err1 <- sendRecv h ("4567", sId, "SEND :hello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same queue ID in response 2"

      Resp _ err2 <- sendRecv h ("12345678", rId, "KEY 4567")
      (err2, ERR AUTH) #== "rejects KEY with wrong signature (password atm)"

      Resp _ err3 <- sendRecv h ("1234", sId, "KEY 4567")
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp rId2 ok2 <- sendRecv h ("1234", rId, "KEY 4567")
      (ok2, OK) #== "secures queue"
      (rId2, rId) #== "same queue ID in response 3"

      Resp _ err4 <- sendRecv h ("1234", rId, "KEY 4567")
      (err4, ERR AUTH) #== "rejects KEY if already secured"

      Resp _ ok3 <- sendRecv h ("4567", sId, "SEND 11\nhello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp _ (MSG _ _ msg) <- tGet fromServer h
      (msg, "hello again") #== "delivers message 2"

      Resp _ ok5 <- sendRecv h ("1234", rId, "ACK")
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp _ err5 <- sendRecv h ("", sId, "SEND :hello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: SpecWith ()
testCreateDelete =
  it "should create (NEW), suspend (OFF) and delete (DEL) queue" $
    smpTest2 \rh sh -> do
      Resp rId1 (IDS rId sId) <- sendRecv rh ("", "", "NEW 1234")
      (rId1, "") #== "creates queue"

      Resp _ ok1 <- sendRecv rh ("1234", rId, "KEY 4567")
      (ok1, OK) #== "secures queue"

      Resp _ ok2 <- sendRecv sh ("4567", sId, "SEND :hello")
      (ok2, OK) #== "accepts signed SEND"

      Resp _ ok7 <- sendRecv sh ("4567", sId, "SEND :hello 2")
      (ok7, OK) #== "accepts signed SEND 2 - this message is not delivered because the first is not ACKed"

      Resp _ (MSG _ _ msg1) <- tGet fromServer rh
      (msg1, "hello") #== "delivers message"

      Resp _ err1 <- sendRecv rh ("12345678", rId, "OFF")
      (err1, ERR AUTH) #== "rejects OFF with wrong signature (password atm)"

      Resp _ err2 <- sendRecv rh ("1234", sId, "OFF")
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp rId2 ok3 <- sendRecv rh ("1234", rId, "OFF")
      (ok3, OK) #== "suspends queue"
      (rId2, rId) #== "same queue ID in response 2"

      Resp _ err3 <- sendRecv sh ("4567", sId, "SEND :hello")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp _ err4 <- sendRecv sh ("", sId, "SEND :hello")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp _ ok4 <- sendRecv rh ("1234", rId, "OFF")
      (ok4, OK) #== "accepts OFF when suspended"

      Resp _ (MSG _ _ msg) <- sendRecv rh ("1234", rId, "SUB")
      (msg, "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp _ err5 <- sendRecv rh ("12345678", rId, "DEL")
      (err5, ERR AUTH) #== "rejects DEL with wrong signature (password atm)"

      Resp _ err6 <- sendRecv rh ("1234", sId, "DEL")
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp rId3 ok6 <- sendRecv rh ("1234", rId, "DEL")
      (ok6, OK) #== "deletes queue"
      (rId3, rId) #== "same queue ID in response 3"

      Resp _ err7 <- sendRecv sh ("4567", sId, "SEND :hello")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp _ err8 <- sendRecv sh ("", sId, "SEND :hello")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp _ err11 <- sendRecv rh ("1234", rId, "ACK")
      (err11, ERR AUTH) #== "rejects ACK when conn deleted - the second message is deleted"

      Resp _ err9 <- sendRecv rh ("1234", rId, "OFF")
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp _ err10 <- sendRecv rh ("1234", rId, "SUB")
      (err10, ERR AUTH) #== "rejects SUB when deleted"

testDuplex :: SpecWith ()
testDuplex =
  it "should create 2 simplex connections and exchange messages" $
    smpTest2 \alice bob -> do
      Resp _ (IDS aRcv aSnd) <- sendRecv alice ("", "", "NEW 1234")
      -- aSnd ID is passed to Bob out-of-band

      Resp _ OK <- sendRecv bob ("", aSnd, "SEND :key efgh")
      -- "key efgh" is ad-hoc, different from SMP protocol

      Resp _ (MSG _ _ msg1) <- tGet fromServer alice
      Resp _ OK <- sendRecv alice ("1234", aRcv, "ACK")
      ["key", key1] <- return $ B.words msg1
      (key1, "efgh") #== "key received from Bob"
      Resp _ OK <- sendRecv alice ("1234", aRcv, "KEY " <> key1)

      Resp _ (IDS bRcv bSnd) <- sendRecv bob ("", "", "NEW abcd")
      Resp _ OK <- sendRecv bob ("efgh", aSnd, "SEND :reply_id " <> encode bSnd)
      -- "reply_id ..." is ad-hoc, it is not a part of SMP protocol

      Resp _ (MSG _ _ msg2) <- tGet fromServer alice
      Resp _ OK <- sendRecv alice ("1234", aRcv, "ACK")
      ["reply_id", bId] <- return $ B.words msg2
      (bId, encode bSnd) #== "reply queue ID received from Bob"
      Resp _ OK <- sendRecv alice ("", bSnd, "SEND :key 5678")
      -- "key 5678" is ad-hoc, different from SMP protocol

      Resp _ (MSG _ _ msg3) <- tGet fromServer bob
      Resp _ OK <- sendRecv bob ("abcd", bRcv, "ACK")
      ["key", key2] <- return $ B.words msg3
      (key2, "5678") #== "key received from Alice"
      Resp _ OK <- sendRecv bob ("abcd", bRcv, "KEY " <> key2)

      Resp _ OK <- sendRecv bob ("efgh", aSnd, "SEND :hi alice")

      Resp _ (MSG _ _ msg4) <- tGet fromServer alice
      Resp _ OK <- sendRecv alice ("1234", aRcv, "ACK")
      (msg4, "hi alice") #== "message received from Bob"

      Resp _ OK <- sendRecv alice ("5678", bSnd, "SEND :how are you bob")

      Resp _ (MSG _ _ msg5) <- tGet fromServer bob
      Resp _ OK <- sendRecv bob ("abcd", bRcv, "ACK")
      (msg5, "how are you bob") #== "message received from alice"

testSwitchSub :: SpecWith ()
testSwitchSub =
  it "should create simplex connections and switch subscription to another TCP connection" $
    smpTest3 \rh1 rh2 sh -> do
      Resp _ (IDS rId sId) <- sendRecv rh1 ("", "", "NEW 1234")
      Resp _ ok1 <- sendRecv sh ("", sId, "SEND :test1")
      (ok1, OK) #== "sent test message 1"
      Resp _ ok2 <- sendRecv sh ("", sId, "SEND :test2, no ACK")
      (ok2, OK) #== "sent test message 2"

      Resp _ (MSG _ _ msg1) <- tGet fromServer rh1
      (msg1, "test1") #== "test message 1 delivered to the 1st TCP connection"
      Resp _ (MSG _ _ msg2) <- sendRecv rh1 ("1234", rId, "ACK")
      (msg2, "test2, no ACK") #== "test message 2 delivered, no ACK"

      Resp _ (MSG _ _ msg2') <- sendRecv rh2 ("1234", rId, "SUB")
      (msg2', "test2, no ACK") #== "same simplex queue via another TCP connection, tes2 delivered again (no ACK in 1st queue)"
      Resp _ OK <- sendRecv rh2 ("1234", rId, "ACK")

      Resp _ end <- tGet fromServer rh1
      (end, END) #== "unsubscribed the 1st TCP connection"

      Resp _ OK <- sendRecv sh ("", sId, "SEND :test3")

      Resp _ (MSG _ _ msg3) <- tGet fromServer rh2
      (msg3, "test3") #== "delivered to the 2nd TCP connection"

      Resp _ err <- sendRecv rh1 ("1234", rId, "ACK")
      (err, ERR PROHIBITED) #== "rejects ACK from the 1st TCP connection"

      Resp _ ok3 <- sendRecv rh2 ("1234", rId, "ACK")
      (ok3, OK) #== "accepts ACK from the 2nd TCP connection"

      timeout 1000 (tGet fromServer rh1) >>= \case
        Nothing -> return ()
        Just _ -> error "nothing else is delivered to the 1st TCP connection"

syntaxTests :: SpecWith ()
syntaxTests = do
  it "unknown command" $ [("", "1234", "HELLO")] >#> [("", "1234", "ERR UNKNOWN")]
  describe "NEW" do
    it "no parameters" $ [("", "", "NEW")] >#> [("", "", "ERR SYNTAX 2")]
    it "many parameters" $ [("", "", "NEW 1 2")] >#> [("", "", "ERR SYNTAX 2")]
    it "has signature" $ [("1234", "", "NEW 1234")] >#> [("", "", "ERR SYNTAX 4")]
    it "queue ID" $ [("", "1", "NEW 1234")] >#> [("", "1", "ERR SYNTAX 4")]
  describe "KEY" do
    it "valid syntax" $ [("1234", "1", "KEY 4567")] >#> [("", "1", "ERR AUTH")]
    it "no parameters" $ [("1234", "1", "KEY")] >#> [("", "1", "ERR SYNTAX 2")]
    it "many parameters" $ [("1234", "1", "KEY 1 2")] >#> [("", "1", "ERR SYNTAX 2")]
    it "no signature" $ [("", "1", "KEY 4567")] >#> [("", "1", "ERR SYNTAX 3")]
    it "no queue ID" $ [("1234", "", "KEY 4567")] >#> [("", "", "ERR SYNTAX 3")]
  noParamsSyntaxTest "SUB"
  noParamsSyntaxTest "ACK"
  noParamsSyntaxTest "OFF"
  noParamsSyntaxTest "DEL"
  describe "SEND" do
    it "valid syntax 1" $ [("1234", "1", "SEND :hello")] >#> [("", "1", "ERR AUTH")]
    it "valid syntax 2" $ [("1234", "1", "SEND 11\nhello there\n")] >#> [("", "1", "ERR AUTH")]
    it "no parameters" $ [("1234", "1", "SEND")] >#> [("", "1", "ERR SYNTAX 2")]
    it "no queue ID" $ [("1234", "", "SEND :hello")] >#> [("", "", "ERR SYNTAX 5")]
    it "bad message body 1" $ [("1234", "1", "SEND 11 hello")] >#> [("", "1", "ERR SYNTAX 6")]
    it "bad message body 2" $ [("1234", "1", "SEND hello")] >#> [("", "1", "ERR SYNTAX 6")]
    it "bigger body" $ [("1234", "1", "SEND 4\nhello\n")] >#> [("", "1", "ERR SIZE")]
  describe "broker response not allowed" do
    it "OK" $ [("1234", "1", "OK")] >#> [("", "1", "ERR PROHIBITED")]
  where
    noParamsSyntaxTest :: ByteString -> SpecWith ()
    noParamsSyntaxTest cmd = describe (B.unpack cmd) do
      it "valid syntax" $ [("1234", "1", cmd)] >#> [("", "1", "ERR AUTH")]
      it "parameters" $ [("1234", "1", cmd <> " 1")] >#> [("", "1", "ERR SYNTAX 2")]
      it "no signature" $ [("", "1", cmd)] >#> [("", "1", "ERR SYNTAX 3")]
      it "no queue ID" $ [("1234", "", cmd)] >#> [("", "", "ERR SYNTAX 3")]
