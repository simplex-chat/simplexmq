module CoreTests.ProtocolErrorTests where

import Simplex.Messaging.Agent.Protocol (AgentErrorType)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (ErrorType)
import Simplex.Messaging.Encoding.String
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

protocolErrorTests :: Spec
protocolErrorTests = modifyMaxSuccess (const 1000) $ do
  describe "errors parsing / serializing" $ do
    it "should parse SMP protocol errors" . property $ \err ->
      parseAll strP (strEncode err)
        == Right (err :: ErrorType)
    it "should parse SMP agent errors" . property $ \err ->
      parseAll strP (strEncode err)
        == Right (err :: AgentErrorType)
