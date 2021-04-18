module ProtocolErrorTests where

import Simplex.Messaging.Agent.Transmission (AgentErrorType, agentErrorTypeP, serializeAgentError)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (ErrorType, errorTypeP, serializeErrorType)
import Simplex.Messaging.Util (bshow)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

protocolErrorTests :: Spec
protocolErrorTests = modifyMaxSuccess (const 1000) $ do
  describe "errors parsing / serializing" $ do
    it "should parse SMP protocol errors" . property $ \err ->
      parseAll errorTypeP (serializeErrorType err)
        == Right (err :: ErrorType)
    it "should parse SMP agent errors" . property $ \err ->
      parseAll agentErrorTypeP (serializeAgentError err)
        == Right (err :: AgentErrorType)
