{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import Control.Logger.Simple
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

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogDebug
  withGlobalLogging logCfg $ do
    createDirectoryIfMissing False "tests/tmp"
    setEnv "APNS_KEY_ID" "H82WD9K9AQ"
    setEnv "APNS_KEY_FILE" "./tests/fixtures/AuthKey_H82WD9K9AQ.p8"
    hspec $ do
      describe "Core tests" $ do
        describe "Encoding tests" encodingTests
        describe "Protocol error tests" protocolErrorTests
        describe "Version range" versionRangeTests
      fdescribe "SMP server via TLS" $ serverTests (transport @TLS)
      describe "SMP server via WebSockets" $ serverTests (transport @WS)
      describe "Notifications server" $ ntfServerTests (transport @TLS)
      describe "SMP client agent" $ agentTests (transport @TLS)
    removeDirectoryRecursive "tests/tmp"
