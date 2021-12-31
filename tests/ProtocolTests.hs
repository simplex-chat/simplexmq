module ProtocolTests where

import qualified Data.Set as S
import Simplex.Messaging.Agent.Protocol (AgentErrorType, agentErrorTypeP, serializeAgentError, serializeSmpErrorType, smpErrorTypeP)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (ErrorType, protocolTags)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

protocolTests :: Spec
protocolTests = modifyMaxSuccess (const 1000) $ do
  describe "protocol" $ do
    it "should have different non-zero tags" $ do
      checkTags protocolTags `shouldBe` True
    it "expected checkTags failures" $ do
      checkTags (head protocolTags : protocolTags) `shouldBe` False
      checkTags ('\x00' : protocolTags) `shouldBe` False
  describe "errors parsing / serializing" $ do
    it "should parse SMP protocol errors" . property $ \err ->
      parseAll smpErrorTypeP (serializeSmpErrorType err)
        == Right (err :: ErrorType)
    it "should parse SMP agent errors" . property $ \err ->
      parseAll agentErrorTypeP (serializeAgentError err)
        == Right (err :: AgentErrorType)

-- | checks that all tags are different and not equal to '\NUL'
checkTags :: [Char] -> Bool
checkTags tags =
  let s = S.fromList tags
   in S.size s == length tags && not (S.member '\NUL' s)
