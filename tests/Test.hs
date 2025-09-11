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
import Test.Hspec hiding (fit, it)
import Util
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
import NtfClient (ntfTestServerDBConnectInfo, ntfTestStoreDBOpts)
import PostgresSchemaDump (postgresSchemaDumpTest)
import SMPClient (testServerDBConnectInfo, testStoreDBOpts)
import Simplex.Messaging.Notifications.Server.Store.Migrations (ntfServerMigrations)
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
#endif

#if defined(dbPostgres) || defined(dbServerPostgres)
import SMPClient (postgressBracket)
#endif

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  setLogLevel testLogLevel
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
          fdescribe "Message store tests" msgStoreTests
          describe "Retry interval tests" retryIntervalTests
          describe "SOCKS settings tests" socksSettingsTests
#if defined(dbServerPostgres)
          around_ (postgressBracket testServerDBConnectInfo) $
            describe "Store log tests" storeLogTests
#else
          describe "Store log tests" storeLogTests
#endif
          describe "TRcvQueues tests" tRcvQueuesTests
          describe "Util tests" utilTests
          describe "Agent core tests" agentCoreTests
#if defined(dbServerPostgres)
        around_ (postgressBracket testServerDBConnectInfo) $
          fdescribe "SMP server schema dump" $
            postgresSchemaDumpTest
              serverMigrations
              [ "20250320_short_links" -- snd_secure moves to the bottom on down migration
              ] -- skipComparisonForDownMigrations
              testStoreDBOpts
              "src/Simplex/Messaging/Server/QueueStore/Postgres/server_schema.sql"
        around_ (postgressBracket testServerDBConnectInfo) $ do
          describe "SMP server via TLS, postgres+jornal message store" $
            before (pure (transport @TLS, ASType SQSPostgres SMSJournal)) serverTests
          describe "SMP server via TLS, postgres-only message store" $
            before (pure (transport @TLS, ASType SQSPostgres SMSPostgres)) serverTests
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
        around_ (postgressBracket ntfTestServerDBConnectInfo) $
          describe "Ntf server schema dump" $
            postgresSchemaDumpTest
              ntfServerMigrations
              [] -- skipComparisonForDownMigrations
              ntfTestStoreDBOpts
              "src/Simplex/Messaging/Notifications/Server/Store/ntf_server_schema.sql"
        around_ (postgressBracket ntfTestServerDBConnectInfo) $ do
          describe "Notifications server (SMP server: jornal store)" $
            ntfServerTests (transport @TLS, ASType SQSMemory SMSJournal)
          around_ (postgressBracket testServerDBConnectInfo) $ do
            describe "Notifications server (SMP server: postgres+jornal store)" $
              ntfServerTests (transport @TLS, ASType SQSPostgres SMSJournal)
            describe "Notifications server (SMP server: postgres-only store)" $
              ntfServerTests (transport @TLS, ASType SQSPostgres SMSPostgres)
        around_ (postgressBracket testServerDBConnectInfo) $ do
          describe "SMP client agent, postgres+jornal message store" $ agentTests (transport @TLS, ASType SQSPostgres SMSJournal)
          describe "SMP client agent, postgres-only message store" $ agentTests (transport @TLS, ASType SQSPostgres SMSPostgres)
          describe "SMP proxy, postgres+jornal message store" $
            before (pure $ ASType SQSPostgres SMSJournal) smpProxyTests
          describe "SMP proxy, postgres-only message store" $
            before (pure $ ASType SQSPostgres SMSPostgres) smpProxyTests
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
