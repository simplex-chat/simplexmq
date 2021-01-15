{-# LANGUAGE BlockArguments #-}

import AgentTests
import ServerTests
import Test.Hspec

main :: IO ()
main = hspec do
  -- describe "SMP server" serverTests
  describe "SMP client agent" agentTests
