{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
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
  it "CREATE and SECURE connection, SEND messages (no delivery yet)" $
    smpTest \h -> do
      Resp rId (CONN rId1 sId) <- sendRecv h ("", "", "CREATE 123")
      (rId1, rId) #== "creates connection"

      Resp sId1 ok1 <- sendRecv h ("", sId, "SEND :hello")
      (ok1, OK) #== "accepts unsigned SEND"
      (sId1, sId) #== "same connection ID in response 1"

      Resp sId2 err1 <- sendRecv h ("456", sId, "SEND :hello")
      (err1, ERROR AUTH) #== "rejects signed SEND"
      (sId2, sId) #== "same connection ID in response 2"

      Resp _ err2 <- sendRecv h ("1234", rId, "SECURE 456")
      (err2, ERROR AUTH) #== "rejects SECURE with wrong signature (password atm)"

      Resp _ err3 <- sendRecv h ("123", sId, "SECURE 456")
      (err3, ERROR AUTH) #== "rejects SECURE with sender's ID"

      Resp rId2 ok2 <- sendRecv h ("123", rId, "SECURE 456")
      (ok2, OK) #== "secures connection"
      (rId2, rId) #== "same connection ID in response 3"

      Resp _ err4 <- sendRecv h ("123", rId, "SECURE 456")
      (err4, ERROR AUTH) #== "rejects SECURE if already secured"

      Resp _ ok3 <- sendRecv h ("456", sId, "SEND :hello")
      (ok3, OK) #== "accepts signed SEND"

      Resp _ err5 <- sendRecv h ("", sId, "SEND :hello")
      (err5, ERROR AUTH) #== "rejects unsigned SEND"

testCreateDelete :: SpecWith ()
testCreateDelete = do
  it "CREATE, SUSPEND and DELETE connection, SEND messages (no delivery yet)" $
    smpTest \h -> do
      Resp rId (CONN rId1 sId) <- sendRecv h ("", "", "CREATE 123")
      (rId1, rId) #== "creates connection"

      Resp _ ok1 <- sendRecv h ("123", rId, "SECURE 456")
      (ok1, OK) #== "secures connection"

      Resp _ ok2 <- sendRecv h ("456", sId, "SEND :hello")
      (ok2, OK) #== "accepts signed SEND"

      Resp _ err1 <- sendRecv h ("1234", rId, "SUSPEND")
      (err1, ERROR AUTH) #== "rejects SUSPEND with wrong signature (password atm)"

      Resp _ err2 <- sendRecv h ("123", sId, "SUSPEND")
      (err2, ERROR AUTH) #== "rejects SUSPEND with sender's ID"

      Resp rId2 ok3 <- sendRecv h ("123", rId, "SUSPEND")
      (ok3, OK) #== "suspends connection"
      (rId2, rId) #== "same connection ID in response 2"

      Resp _ err3 <- sendRecv h ("456", sId, "SEND :hello")
      (err3, ERROR AUTH) #== "rejects signed SEND"

      Resp _ err4 <- sendRecv h ("", sId, "SEND :hello")
      (err4, ERROR AUTH) #== "reject unsigned SEND too"

      Resp _ ok4 <- sendRecv h ("123", rId, "SUSPEND")
      (ok4, OK) #== "accepts SUSPEND when suspended"

      Resp _ ok5 <- sendRecv h ("123", rId, "SUB")
      (ok5, OK) #== "accepts SUB when suspended"

      Resp _ err5 <- sendRecv h ("1234", rId, "DELETE")
      (err5, ERROR AUTH) #== "rejects DELETE with wrong signature (password atm)"

      Resp _ err6 <- sendRecv h ("123", sId, "DELETE")
      (err6, ERROR AUTH) #== "rejects DELETE with sender's ID"

      Resp rId3 ok6 <- sendRecv h ("123", rId, "DELETE")
      (ok6, OK) #== "deletes connection"
      (rId3, rId) #== "same connection ID in response 3"

      Resp _ err7 <- sendRecv h ("456", sId, "SEND :hello")
      (err7, ERROR AUTH) #== "rejects signed SEND when deleted"

      Resp _ err8 <- sendRecv h ("", sId, "SEND :hello")
      (err8, ERROR AUTH) #== "rejects unsigned SEND too when deleted"

      Resp _ err9 <- sendRecv h ("123", rId, "SUSPEND")
      (err9, ERROR AUTH) #== "rejects SUSPEND when deleted"

      Resp _ err10 <- sendRecv h ("123", rId, "SUB")
      (err10, ERROR AUTH) #== "rejects SUB when deleted"

syntaxTests :: SpecWith ()
syntaxTests = do
  it "unknown command" $ [("", "123", "HELLO")] >#> [("", "123", "ERROR UNKNOWN")]
  describe "CREATE" do
    it "no parameters" $ [("", "", "CREATE")] >#> [("", "", "ERROR SYNTAX 2")]
    it "many parameters" $ [("", "", "CREATE 1 2")] >#> [("", "", "ERROR SYNTAX 2")]
    it "has signature" $ [("123", "", "CREATE 123")] >#> [("", "", "ERROR SYNTAX 4")]
    it "connection ID" $ [("", "1", "CREATE 123")] >#> [("", "1", "ERROR SYNTAX 4")]
  noParamsSyntaxTest "SUB"
  oneParamSyntaxTest "SECURE"
  oneParamSyntaxTest "DELMSG"
  noParamsSyntaxTest "SUSPEND"
  noParamsSyntaxTest "DELETE"
  describe "SEND" do
    it "valid syntax 1" $ [("123", "1", "SEND :hello")] >#> [("", "1", "ERROR AUTH")]
    it "valid syntax 2" $ [("123", "1", "SEND 11\nhello there\n")] >#> [("", "1", "ERROR AUTH")]
    it "no parameters" $ [("123", "1", "SEND")] >#> [("", "1", "ERROR SYNTAX 2")]
    it "many parameters" $ [("123", "1", "SEND 11 hello")] >#> [("", "1", "ERROR SYNTAX 2")]
    it "no connection ID" $ [("123", "", "SEND :hello")] >#> [("", "", "ERROR SYNTAX 5")]
    it "bad message body" $ [("123", "1", "SEND hello")] >#> [("", "1", "ERROR SYNTAX 6")]
    it "bigger body" $ [("123", "1", "SEND 4\nhello\n")] >#> [("", "1", "ERROR SYNTAX 7")]
  describe "broker response not allowed" do
    it "OK" $ [("123", "1", "OK")] >#> [("", "1", "ERROR PROHIBITED")]
  where
    noParamsSyntaxTest :: String -> SpecWith ()
    noParamsSyntaxTest cmd = describe cmd do
      it "valid syntax" $ [("123", "1", cmd)] >#> [("", "1", "ERROR AUTH")]
      it "parameters" $ [("123", "1", cmd ++ " 1")] >#> [("", "1", "ERROR SYNTAX 2")]
      it "no signature" $ [("", "1", cmd)] >#> [("", "1", "ERROR SYNTAX 3")]
      it "no connection ID" $ [("123", "", cmd)] >#> [("", "", "ERROR SYNTAX 3")]

    oneParamSyntaxTest :: String -> SpecWith ()
    oneParamSyntaxTest cmd = describe cmd do
      it "valid syntax" $ [("123", "1", cmd ++ " 456")] >#> [("", "1", "ERROR AUTH")]
      it "no parameters" $ [("123", "1", cmd)] >#> [("", "1", "ERROR SYNTAX 2")]
      it "many parameters" $ [("123", "1", cmd ++ " 1 2")] >#> [("", "1", "ERROR SYNTAX 2")]
      it "no signature" $ [("", "1", cmd ++ " 456")] >#> [("", "1", "ERROR SYNTAX 3")]
      it "no connection ID" $ [("123", "", cmd ++ " 456")] >#> [("", "", "ERROR SYNTAX 3")]
