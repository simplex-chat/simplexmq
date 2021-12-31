{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import ProtocolTests
import ServerTests
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import Test.Hspec
import VersionRangeTests

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  hspec $ do
    describe "Protocol tests" protocolTests
    describe "Version range" versionRangeTests
    describe "SMP server via TLS 1.3" $ serverTests (transport @TLS)
    describe "SMP server via WebSockets" $ serverTests (transport @WS)
    describe "SMP client agent" $ agentTests (transport @TLS)
  removeDirectoryRecursive "tests/tmp"
