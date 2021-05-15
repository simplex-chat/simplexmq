{-# LANGUAGE TypeApplications #-}

import AgentTests
import ProtocolErrorTests
import ServerTests
import Simplex.Messaging.Transport (TCP, Transport (..))
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "Protocol errors" protocolErrorTests
    describe "SMP server" $ serverTests (Transport @TCP)
    describe "SMP client agent" $ agentTests (Transport @TCP)
  removeDirectoryRecursive "tests/tmp"
