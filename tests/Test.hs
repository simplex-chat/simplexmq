{-# LANGUAGE BlockArguments #-}

import SMPClient
import Test.Hspec

(>#>) :: [TestTransmission] -> [TestTransmission] -> Expectation
commands >#> responses = smpServerTest commands `shouldReturn` responses

main :: IO ()
main = hspec do
  describe "SMP syntax" do
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
