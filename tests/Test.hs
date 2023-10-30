{-# LANGUAGE TypeApplications #-}

import AgentTests (agentTests)
import AgentTests.SchemaDump (schemaDumpTest)
import CLITests
import Control.Logger.Simple
import CoreTests.BatchingTests
import CoreTests.CryptoFileTests
import CoreTests.CryptoTests
import CoreTests.EncodingTests
import CoreTests.ProtocolErrorTests
import CoreTests.RetryIntervalTests
import CoreTests.UtilTests
import CoreTests.VersionRangeTests
import FileDescriptionTests (fileDescriptionTests)
import NtfServerTests (ntfServerTests)
import RemoteControlTests (remoteControlTests)
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
        describe "Agent SQLite schema dump" schemaDumpTest
        describe "Core tests" $ do
          describe "Batching tests" batchingTests
          describe "Encoding tests" encodingTests
          describe "Protocol error tests" protocolErrorTests
          describe "Version range" versionRangeTests
          describe "Encryption tests" cryptoTests
          describe "Encrypted files tests" cryptoFileTests
          describe "Retry interval tests" retryIntervalTests
          describe "Util tests" utilTests
        describe "SMP server via TLS" $ serverTests (transport @TLS)
        describe "SMP server via WebSockets" $ serverTests (transport @WS)
        describe "Notifications server" $ ntfServerTests (transport @TLS)
        describe "SMP client agent" $ agentTests (transport @TLS)
        describe "XFTP" $ do
          describe "XFTP server" xftpServerTests
          describe "XFTP file description" fileDescriptionTests
          describe "XFTP CLI" xftpCLITests
          describe "XFTP agent" xftpAgentTests
        fdescribe "Remote Control Protocol" remoteControlTests
        describe "Server CLIs" cliTests
