{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import CLITests
import Control.Logger.Simple
import CoreTests.CryptoTests
import CoreTests.EncodingTests
import CoreTests.ProtocolErrorTests
import CoreTests.RetryIntervalTests
import CoreTests.VersionRangeTests
import FileDescriptionTests (fileDescriptionTests)
import NtfServerTests (ntfServerTests)
import ServerTests
import Simplex.Messaging.Transport (TLS, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Environment (setEnv)
import Test.Hspec
import XFTPAgent
import XFTPCLI
import XFTPServerTests (xftpServerTests)

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel LogError -- LogInfo
  withGlobalLogging logCfg $ do
    setEnv "APNS_KEY_ID" "H82WD9K9AQ"
    setEnv "APNS_KEY_FILE" "./tests/fixtures/AuthKey_H82WD9K9AQ.p8"
    hspec
      . before_ (createDirectoryIfMissing False "tests/tmp")
      . after_ (removeDirectoryRecursive "tests/tmp")
      $ do
        describe "Core tests" $ do
          describe "Encoding tests" encodingTests
          describe "Protocol error tests" protocolErrorTests
          describe "Version range" versionRangeTests
          describe "Encryption tests" cryptoTests
          describe "Retry interval tests" retryIntervalTests
        describe "SMP server via TLS" $ serverTests (transport @TLS)
        describe "SMP server via WebSockets" $ serverTests (transport @WS)
        describe "Notifications server" $ ntfServerTests (transport @TLS)
        describe "SMP client agent" $ agentTests (transport @TLS)
        describe "XFTP" $ do
          describe "XFTP server" xftpServerTests
          describe "XFTP file description" fileDescriptionTests
          describe "XFTP CLI" xftpCLITests
          fdescribe "XFTP agent" xftpAgentTests
        describe "Server CLIs" cliTests
