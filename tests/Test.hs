{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}

import SMPClient
import System.IO (Handle)
import Test.Hspec
import Transmission
import Transport

(>#>) :: [TestTransmission] -> [TestTransmission] -> Expectation
commands >#> responses = smpServerTest commands `shouldReturn` responses

main :: IO ()
main = hspec do
  describe "SMP syntax" syntaxTests
  describe "SMP connections" connectionTests

pattern Resp :: ConnId -> Command 'Broker -> TransmissionOrError
pattern Resp connId command = ("", (connId, Right (Cmd SBroker command)))

smpExpect :: (Show a, Eq a) => a -> (Handle -> IO a) -> Expectation
smpExpect result test = runSmpTest test `shouldReturn` result

sendRecv :: Handle -> RawTransmission -> IO TransmissionOrError
sendRecv h t = tPutRaw h t >> tGet fromServer h

assert :: Bool -> IO ()
assert True = return ()
assert False = error "failed assertion"

connectionTests :: SpecWith ()
connectionTests = do
  it "CREATE and SECURE connection, SEND messages (no delivery yet)" $
    smpExpect True \h -> do
      Resp rId (CONN rId' sId) <- sendRecv h ("", "", "CREATE 123")
      assert $ rId == rId'
      -- should allow unsigned
      Resp sId' OK <- sendRecv h ("", sId, "SEND :hello")
      assert $ sId' == sId
      -- should not allow signed
      Resp sId'' (ERROR AUTH) <- sendRecv h ("456", sId, "SEND :hello")
      assert $ sId'' == sId
      -- shoud not secure with wrong signature (password atm)
      Resp _ (ERROR AUTH) <- sendRecv h ("1234", rId, "SECURE 456")
      -- shoud not secure with sender's ID
      Resp _ (ERROR AUTH) <- sendRecv h ("123", sId, "SECURE 456")
      -- secure connection
      Resp rId'' OK <- sendRecv h ("123", rId, "SECURE 456")
      assert $ rId == rId''
      -- should not allow SECURE if already secured
      Resp _ (ERROR AUTH) <- sendRecv h ("123", rId, "SECURE 456")
      -- should allow signed
      Resp _ OK <- sendRecv h ("456", sId, "SEND :hello")
      -- should not allow unsigned
      Resp _ (ERROR AUTH) <- sendRecv h ("", sId, "SEND :hello")
      return True

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
