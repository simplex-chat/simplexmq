{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

import AgentTests (agentCoreTests, agentTests)
import CLITests
import Control.Concurrent (threadDelay)
import qualified Control.Exception as E
import Control.Logger.Simple
import CoreTests.BatchingTests
import CoreTests.CryptoFileTests
import CoreTests.CryptoTests
import CoreTests.EncodingTests
import CoreTests.MsgStoreTests
import CoreTests.RetryIntervalTests
import CoreTests.SOCKSSettings
import CoreTests.StoreLogTests
import CoreTests.TRcvQueuesTests
import CoreTests.UtilTests
import CoreTests.VersionRangeTests
import FileDescriptionTests (fileDescriptionTests)
import GHC.IO.Exception (IOException (..))
import qualified GHC.IO.Exception as IOException
import RemoteControl (remoteControlTests)
import SMPProxyTests (smpProxyTests)
import ServerTests
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Transport (TLS, Transport (..))
-- import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Environment (setEnv)
import Test.Hspec
import XFTPAgent
import XFTPCLI
import XFTPServerTests (xftpServerTests)

#if defined(dbPostgres)
import Fixtures
#else
import AgentTests.SchemaDump (schemaDumpTest)
#endif

#if defined(dbServerPostgres)
import NtfServerTests (ntfServerTests)
import NtfClient (ntfTestServerDBConnectInfo)
import SMPClient (testServerDBConnectInfo)
import ServerTests.SchemaDump
#endif

#if defined(dbPostgres) || defined(dbServerPostgres)
import SMPClient (postgressBracket)
#endif

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  -- TODO [ntfdb] running wiht LogWarn level shows potential issue "Queue count differs"
  setLogLevel LogError -- LogInfo
  withGlobalLogging logCfg $ do
    setEnv "APNS_KEY_ID" "H82WD9K9AQ"
    setEnv "APNS_KEY_FILE" "./tests/fixtures/AuthKey_H82WD9K9AQ.p8"
    hspec
#if defined(dbPostgres)
      . aroundAll_ (postgressBracket testDBConnectInfo)
#endif
      . before_ (createDirectoryIfMissing False "tests/tmp")
      . after_ (eventuallyRemove "tests/tmp" 3)
      $ do
-- TODO [postgres] schema dump for postgres
#if !defined(dbPostgres)
        describe "Agent SQLite schema dump" schemaDumpTest
#endif
        describe "Core tests" $ do
          describe "Batching tests" batchingTests
          describe "Encoding tests" encodingTests
          describe "Version range" versionRangeTests
          describe "Encryption tests" cryptoTests
          describe "Encrypted files tests" cryptoFileTests
          describe "Message store tests" msgStoreTests
          describe "Retry interval tests" retryIntervalTests
          describe "SOCKS settings tests" socksSettingsTests
          describe "Store log tests" storeLogTests
          describe "TRcvQueues tests" tRcvQueuesTests
          describe "Util tests" utilTests
          describe "Agent core tests" agentCoreTests
#if defined(dbServerPostgres)
        around_ (postgressBracket testServerDBConnectInfo) $
          describe "Server schema dump" serverSchemaDumpTest
        aroundAll_ (postgressBracket testServerDBConnectInfo) $
          describe "SMP server via TLS, postgres+jornal message store" $
            before (pure (transport @TLS, ASType SQSPostgres SMSJournal)) serverTests
#endif
        describe "SMP server via TLS, jornal message store" $ do
          describe "SMP syntax" $ serverSyntaxTests (transport @TLS)
          before (pure (transport @TLS, ASType SQSMemory SMSJournal)) serverTests
        describe "SMP server via TLS, memory message store" $
          before (pure (transport @TLS, ASType SQSMemory SMSMemory)) serverTests
        -- xdescribe "SMP server via WebSockets" $ do
        --   describe "SMP syntax" $ serverSyntaxTests (transport @WS)
        --   before (pure (transport @WS, ASType SQSMemory SMSJournal)) serverTests
#if defined(dbServerPostgres)
        aroundAll_ (postgressBracket ntfTestServerDBConnectInfo) $ do
          describe "Notifications server" $ ntfServerTests (transport @TLS)
        aroundAll_ (postgressBracket testServerDBConnectInfo) $ do
          describe "SMP client agent, postgres+jornal message store" $ agentTests (transport @TLS, ASType SQSPostgres SMSJournal)
          describe "SMP proxy, postgres+jornal message store" $
            before (pure $ ASType SQSPostgres SMSJournal) smpProxyTests
#endif
        describe "SMP client agent, jornal message store" $ agentTests (transport @TLS, ASType SQSMemory SMSJournal)
        describe "SMP proxy, jornal message store" $
          before (pure $ ASType SQSMemory SMSJournal) smpProxyTests
        describe "XFTP" $ do
          describe "XFTP server" xftpServerTests
          describe "XFTP file description" fileDescriptionTests
          describe "XFTP CLI" xftpCLITests
          describe "XFTP agent" xftpAgentTests
        describe "XRCP" remoteControlTests
        describe "Server CLIs" cliTests

eventuallyRemove :: FilePath -> Int -> IO ()
eventuallyRemove path retries = case retries of
  0 -> action
  n ->
    action `E.catch` \ioe@IOError {ioe_type, ioe_filename} -> case ioe_type of
      IOException.UnsatisfiedConstraints | ioe_filename == Just path -> threadDelay 1000000 >> eventuallyRemove path (n - 1)
      _ -> E.throwIO ioe
  where
    action = removeDirectoryRecursive path
