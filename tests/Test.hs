{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import AgentTests.NotificationTests (notificationTests)
import CoreTests.EncodingTests
import CoreTests.ProtocolErrorTests
import CoreTests.VersionRangeTests
import NtfServerTests (ntfServerTests)
import ServerTests
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Environment (setEnv)
import Test.Hspec

main :: IO ()
main = do
  createDirectoryIfMissing False "tests/tmp"
  setEnv "APNS_KEY_ID" "H82WD9K9AQ"
  setEnv "APNS_KEY_FILE" "./tests/fixtures/AuthKey_H82WD9K9AQ.p8"
  hspec $ do
    describe "Core tests" $ do
      describe "Encoding tests" encodingTests
      describe "Protocol error tests" protocolErrorTests
      describe "Version range" versionRangeTests
    describe "SMP server via TLS" $ serverTests (transport @TLS)
    describe "SMP server via WebSockets" $ serverTests (transport @WS)
    describe "Notifications server" $ do
      ntfServerTests (transport @TLS)
      notificationTests (transport @TLS)
    describe "SMP client agent" $ agentTests (transport @TLS)
  removeDirectoryRecursive "tests/tmp"
