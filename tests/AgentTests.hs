module AgentTests where

import AgentTests.SQLite
import Test.Hspec

agentTests :: Spec
agentTests = do
  describe "SQLite store" storeTests
