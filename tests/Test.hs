{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import ProtocolErrorTests
import ServerTests
import Simplex.Messaging.Transport (Transport (..))
import Simplex.Messaging.Transport.Plain (Plain)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "Protocol errors" protocolErrorTests
    describe "SMP server via Plain TLS 1.3 over TCP" $ serverTests (transport @Plain)
    -- describe "SMP server via WebSockets" $ serverTests (transport @WS)
    describe "SMP client agent" $ agentTests (transport @Plain)
  removeDirectoryRecursive "tests/tmp"
