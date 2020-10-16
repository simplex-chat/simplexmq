{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

import SMPClient
import System.IO (Handle)
import Test.HUnit
import Test.Hspec
import Transmission
import Transport

(>#>) :: [TestTransmission] -> [TestTransmission] -> Expectation
commands >#> responses = smpServerTest commands `shouldReturn` responses

main :: IO ()
main = hspec do
  describe "SMP syntax" syntaxTests
  describe "SMP connections" do
    testCreateSecure
    testCreateDelete

pattern Resp :: ConnId -> Command 'Broker -> TransmissionOrError
pattern Resp connId command = ("", (connId, Right (Cmd SBroker command)))

smpTest :: (Handle -> IO ()) -> Expectation
smpTest test' = runSmpTest test' `shouldReturn` ()

sendRecv :: Handle -> RawTransmission -> IO TransmissionOrError
sendRecv h t = tPutRaw h t >> tGet fromServer h

(#==) :: (HasCallStack, Eq a, Show a) => (a, a) -> String -> Assertion
(actual, expected) #== message = assertEqual message expected actual

testCreateSecure :: SpecWith ()
testCreateSecure = do
  it "CONN and KEY commands, SEND messages (no delivery yet)" $
    smpTest \h -> do
      Resp rId (IDS rId1 sId) <- sendRecv h ("", "", "CONN 123")
      (rId1, rId) #== "creates connection"

      Resp sId1 ok1 <- sendRecv h ("", sId, "SEND :hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same connection ID in response 1"

      Resp _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp _ ok4 <- sendRecv h ("123", "1", "ACK")
      (ok4, OK) #== "replies OK when message acknowledged if no more messages"

      Resp sId2 err1 <- sendRecv h ("456", sId, "SEND :hello")
      (err1, ERR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same connection ID in response 2"

      Resp _ err2 <- sendRecv h ("1234", rId, "KEY 456")
      (err2, ERR AUTH) #== "rejects KEY with wrong signature (password atm)"

      Resp _ err3 <- sendRecv h ("123", sId, "KEY 456")
      (err3, ERR AUTH) #== "rejects KEY with sender's ID"

      Resp rId2 ok2 <- sendRecv h ("123", rId, "KEY 456")
      (ok2, OK) #== "secures connection"
      (rId2, rId) #== "same connection ID in response 3"

      Resp _ err4 <- sendRecv h ("123", rId, "KEY 456")
      (err4, ERR AUTH) #== "rejects KEY if already secured"

      Resp _ ok3 <- sendRecv h ("456", sId, "SEND 11\nhello again")
      (ok3, OK) #== "accepts signed SEND"

      Resp _ (MSG _ _ msg) <- tGet fromServer h
      (msg, "hello again") #== "delivers message 2"

      Resp _ ok5 <- sendRecv h ("123", "1", "ACK")
      (ok5, OK) #== "replies OK when message acknowledged 2"

      Resp _ err5 <- sendRecv h ("", sId, "SEND :hello")
      (err5, ERR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: SpecWith ()
testCreateDelete = do
  it "CONN, OFF and DEL commands, SEND messages (no delivery yet)" $
    smpTest \h -> do
      Resp rId (IDS rId1 sId) <- sendRecv h ("", "", "CONN 123")
      (rId1, rId) #== "creates connection"

      Resp _ ok1 <- sendRecv h ("123", rId, "KEY 456")
      (ok1, OK) #== "secures connection"

      Resp _ ok2 <- sendRecv h ("456", sId, "SEND :hello")
      (ok2, OK) #== "accepts signed SEND"

      Resp _ (MSG _ _ msg1) <- tGet fromServer h
      (msg1, "hello") #== "delivers message"

      Resp _ err1 <- sendRecv h ("1234", rId, "OFF")
      (err1, ERR AUTH) #== "rejects OFF with wrong signature (password atm)"

      Resp _ err2 <- sendRecv h ("123", sId, "OFF")
      (err2, ERR AUTH) #== "rejects OFF with sender's ID"

      Resp rId2 ok3 <- sendRecv h ("123", rId, "OFF")
      (ok3, OK) #== "suspends connection"
      (rId2, rId) #== "same connection ID in response 2"

      Resp _ err3 <- sendRecv h ("456", sId, "SEND :hello")
      (err3, ERR AUTH) #== "rejects signed SEND"

      Resp _ err4 <- sendRecv h ("", sId, "SEND :hello")
      (err4, ERR AUTH) #== "reject unsigned SEND too"

      Resp _ ok4 <- sendRecv h ("123", rId, "OFF")
      (ok4, OK) #== "accepts OFF when suspended"

      Resp _ (MSG _ _ msg) <- sendRecv h ("123", rId, "SUB")
      (msg, "hello") #== "accepts SUB when suspended and delivers the message again (because was not ACKed)"

      Resp _ err5 <- sendRecv h ("1234", rId, "DEL")
      (err5, ERR AUTH) #== "rejects DEL with wrong signature (password atm)"

      Resp _ err6 <- sendRecv h ("123", sId, "DEL")
      (err6, ERR AUTH) #== "rejects DEL with sender's ID"

      Resp rId3 ok6 <- sendRecv h ("123", rId, "DEL")
      (ok6, OK) #== "deletes connection"
      (rId3, rId) #== "same connection ID in response 3"

      Resp _ err7 <- sendRecv h ("456", sId, "SEND :hello")
      (err7, ERR AUTH) #== "rejects signed SEND when deleted"

      Resp _ err8 <- sendRecv h ("", sId, "SEND :hello")
      (err8, ERR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp _ err9 <- sendRecv h ("123", rId, "OFF")
      (err9, ERR AUTH) #== "rejects OFF when deleted"

      Resp _ err10 <- sendRecv h ("123", rId, "SUB")
      (err10, ERR AUTH) #== "rejects SUB when deleted"

syntaxTests :: SpecWith ()
syntaxTests = do
  it "unknown command" $ [("", "123", "HELLO")] >#> [("", "123", "ERR UNKNOWN")]
  describe "CONN" do
    it "no parameters" $ [("", "", "CONN")] >#> [("", "", "ERR SYNTAX 2")]
    it "many parameters" $ [("", "", "CONN 1 2")] >#> [("", "", "ERR SYNTAX 2")]
    it "has signature" $ [("123", "", "CONN 123")] >#> [("", "", "ERR SYNTAX 4")]
    it "connection ID" $ [("", "1", "CONN 123")] >#> [("", "1", "ERR SYNTAX 4")]
  describe "KEY" do
    it "valid syntax" $ [("123", "1", "KEY 456")] >#> [("", "1", "ERR AUTH")]
    it "no parameters" $ [("123", "1", "KEY")] >#> [("", "1", "ERR SYNTAX 2")]
    it "many parameters" $ [("123", "1", "KEY 1 2")] >#> [("", "1", "ERR SYNTAX 2")]
    it "no signature" $ [("", "1", "KEY 456")] >#> [("", "1", "ERR SYNTAX 3")]
    it "no connection ID" $ [("123", "", "KEY 456")] >#> [("", "", "ERR SYNTAX 3")]
  noParamsSyntaxTest "SUB"
  noParamsSyntaxTest "ACK"
  noParamsSyntaxTest "OFF"
  noParamsSyntaxTest "DEL"
  describe "SEND" do
    it "valid syntax 1" $ [("123", "1", "SEND :hello")] >#> [("", "1", "ERR AUTH")]
    it "valid syntax 2" $ [("123", "1", "SEND 11\nhello there\n")] >#> [("", "1", "ERR AUTH")]
    it "no parameters" $ [("123", "1", "SEND")] >#> [("", "1", "ERR SYNTAX 2")]
    it "no connection ID" $ [("123", "", "SEND :hello")] >#> [("", "", "ERR SYNTAX 5")]
    it "bad message body 1" $ [("123", "1", "SEND 11 hello")] >#> [("", "1", "ERR SYNTAX 6")]
    it "bad message body 2" $ [("123", "1", "SEND hello")] >#> [("", "1", "ERR SYNTAX 6")]
    it "bigger body" $ [("123", "1", "SEND 4\nhello\n")] >#> [("", "1", "ERR SIZE")]
  describe "broker response not allowed" do
    it "OK" $ [("123", "1", "OK")] >#> [("", "1", "ERR PROHIBITED")]
  where
    noParamsSyntaxTest :: String -> SpecWith ()
    noParamsSyntaxTest cmd = describe cmd do
      it "valid syntax" $ [("123", "1", cmd)] >#> [("", "1", "ERR AUTH")]
      it "parameters" $ [("123", "1", cmd ++ " 1")] >#> [("", "1", "ERR SYNTAX 2")]
      it "no signature" $ [("", "1", cmd)] >#> [("", "1", "ERR SYNTAX 3")]
      it "no connection ID" $ [("123", "", cmd)] >#> [("", "", "ERR SYNTAX 3")]
