{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import ProtocolErrorTests
import ServerTests
import Simplex.Messaging.Transport (TCP, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "Protocol errors" protocolErrorTests
    describe "SMP server via TCP" $ serverTests (transport @TCP)
    describe "SMP server via WebSockets" $ serverTests (transport @WS)
    xdescribe "SMP client agent" $ agentTests (transport @TCP)
  removeDirectoryRecursive "tests/tmp"
