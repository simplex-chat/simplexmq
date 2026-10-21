{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}

import AgentTests (agentCoreTests, agentTests)
import AgentTests.FunctionalAPITests (functionalAPITimingTests)
import CLITests
import Control.Exception (bracket_)
import Control.Logger.Simple
import CoreTests.BatchingTests
import CoreTests.CryptoFileTests
import CoreTests.CryptoTests
import CoreTests.EncodingTests
import CoreTests.MsgStoreTests
import CoreTests.RetryIntervalTests
import CoreTests.SOCKSSettings
import CoreTests.StoreLogTests
import CoreTests.TSessionSubs
import CoreTests.UtilTests
import CoreTests.VersionRangeTests
import FileDescriptionTests (fileDescriptionTests)
import RSLVTests (rslvTests)
import RemoteControl (remoteControlTests)
import SMPNamesTests (smpNamesTests)
import SMPProxyTests (smpProxyCapabilityTests, smpProxyTests)
import ServerTests
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Server.MsgStore.Types (SMSType (..), SQSType (..))
import Simplex.Messaging.Transport (TLS, Transport (..))
-- import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, listDirectory, removePathForcibly)
import System.Environment (getArgs, setEnv, withArgs)
import System.FilePath ((</>))
import Test.Hspec hiding (fit, it)
import Test.Hspec.Core.Runner (defaultConfig, evalSpec, evaluateResult, readConfig, runSpecForest)
import Util
import XFTPAgent
import XFTPCLI (xftpCLIFileTests)
import Simplex.FileTransfer.Server.Env (AFStoreType (..))
import Simplex.FileTransfer.Server.Store (SFSType (..))
import XFTPServerTests (xftpServerTests)
import WebTests (webTests)
import XFTPWebTests (xftpWebTests)

#if defined(dbPostgres)
import Fixtures
import Simplex.Messaging.Agent.Store.Postgres.Migrations.App
#else
import AgentTests.SchemaDump (schemaDumpTest)
#endif

#if defined(dbServerPostgres)
import CoreTests.XFTPStoreTests (xftpStoreTests, xftpMigrationTests)
import NtfServerTests (ntfServerTests)
import NtfClient (ntfTestServerDBConnectInfo, ntfTestServerDBOpts)
import SMPClient (testServerDBConnectInfo, testServerDBOpts)
import Simplex.Messaging.Notifications.Server.Store.Migrations (ntfServerMigrations)
import Simplex.Messaging.Server.QueueStore.Postgres.Migrations (serverMigrations)
import XFTPClient (testXFTPDBConnectInfo)
#endif

#if defined(dbPostgres) || defined(dbServerPostgres)
import PostgresSchemaDump (postgresSchemaDumpTest)
import SMPClient (postgressBracket)
#endif

#if MIN_VERSION_base(4,18,0)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forM_, void)
import GHC.Conc.Sync (listThreads, threadLabel, threadStatus)
#endif

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  dumpThreadsAfter 25
  setLogLevel testLogLevel
  withGlobalLogging logCfg $ do
    setEnv "APNS_KEY_ID" "H82WD9K9AQ"
    setEnv "APNS_KEY_FILE" "./tests/fixtures/AuthKey_H82WD9K9AQ.p8"
    hspecInTmpDir
#if defined(dbPostgres)
      . aroundAll_ (postgressBracket testDBConnectInfo)
#endif
#if defined(dbServerPostgres)
      . aroundAll_ (postgressBracket testServerDBConnectInfo)
      . aroundAll_ (postgressBracket ntfTestServerDBConnectInfo)
      . aroundAll_ (postgressBracket testXFTPDBConnectInfo)
#endif
      $ do
        parallel $ do
          describe "Core tests" $ do
            describe "Batching tests" batchingTests
            describe "Encoding tests" encodingTests
            describe "Version range" versionRangeTests
            describe "Encryption tests" cryptoTests
            describe "Encrypted files tests" cryptoFileTests
            describe "Message store tests" msgStoreTests
            describe "SOCKS settings tests" socksSettingsTests
            describe "Store log tests" storeLogTests
            describe "XFTP store log tests" fileStoreLogTests
            fileExpirationTests
            describe "TSessionSubs tests" tSessionSubsTests
            describe "Util tests" utilTests
            describe "Names resolver tests" smpNamesTests
            describe "RSLV functional API tests" rslvTests
            describe "Agent core tests" agentCoreTests
#if defined(dbServerPostgres)
          describe "SMP server via TLS, postgres-only message store" $
            before (pure (transport @TLS, ASType SQSPostgres SMSPostgres)) serverTests
#endif
          describe "SMP server via TLS, memory message store" $ do
            describe "SMP syntax" $ serverSyntaxTests (transport @TLS)
            before (pure (transport @TLS, ASType SQSMemory SMSMemory)) serverTests
          -- xdescribe "SMP server via WebSockets" $ do
          --   describe "SMP syntax" $ serverSyntaxTests (transport @WS)
          --   before (pure (transport @WS, ASType SQSMemory SMSMemory)) serverTests
#if defined(dbServerPostgres)
          describe "Notifications server (SMP server: memory store)" $
            ntfServerTests (transport @TLS, ASType SQSMemory SMSMemory)
          describe "Notifications server (SMP server: postgres-only store)" $
            ntfServerTests (transport @TLS, ASType SQSPostgres SMSPostgres)
          describe "SMP client agent, server postgres-only message store" $ agentTests (transport @TLS, ASType SQSPostgres SMSPostgres)
          describe "SMP proxy, postgres-only message store" $
            before (pure $ ASType SQSPostgres SMSPostgres) smpProxyTests
#endif
          describe "SMP client agent, server memory message store" $ agentTests (transport @TLS, ASType SQSMemory SMSMemory)
          describe "SMP proxy, memory message store" $
            before (pure $ ASType SQSMemory SMSMemory) smpProxyTests
          describe "XFTP" $ do
            describe "XFTP server" $
              before (pure $ AFSType SFSMemory) xftpServerTests
            describe "XFTP file description" fileDescriptionTests
            describe "XFTP agent" $
              before (pure $ AFSType SFSMemory) xftpAgentTests
#if defined(dbServerPostgres)
          describe "XFTP Postgres store operations" xftpStoreTests
          describe "XFTP migration round-trip" xftpMigrationTests
          describe "XFTP server (PostgreSQL)" $
            before (pure $ AFSType SFSPostgres) xftpServerTests
          describe "XFTP agent (PostgreSQL)" $
            before (pure $ AFSType SFSPostgres) xftpAgentTests
#endif
          describe "XFTP Web Client" xftpWebTests
          describe "XRCP" remoteControlTests
          describe "Web" webTests
        sequential $ do
          describe "Core tests" $ describe "Retry interval tests" retryIntervalTests
#if defined(dbServerPostgres)
          describe "SMP server via TLS, postgres-only message store" $
            before (pure (transport @TLS, ASType SQSPostgres SMSPostgres)) $ describe "Timing of AUTH error" testTiming
#endif
          describe "SMP server via TLS, memory message store" $
            before (pure (transport @TLS, ASType SQSMemory SMSMemory)) $ describe "Timing of AUTH error" testTiming
#if defined(dbServerPostgres)
          describe "SMP client agent, server postgres-only message store" $
            describe "Functional API" $ functionalAPITimingTests (transport @TLS, ASType SQSPostgres SMSPostgres)
#endif
          describe "SMP client agent, server memory message store" $
            describe "Functional API" $ functionalAPITimingTests (transport @TLS, ASType SQSMemory SMSMemory)
#if defined(dbServerPostgres)
          describe "SMP proxy capabilities, postgres-only message store" $
            before (pure $ ASType SQSPostgres SMSPostgres) smpProxyCapabilityTests
#endif
          describe "SMP proxy capabilities, memory message store" $
            before (pure $ ASType SQSMemory SMSMemory) smpProxyCapabilityTests
          describe "XFTP CLI (memory)" $
            before (pure $ AFSType SFSMemory) xftpCLIFileTests
#if defined(dbServerPostgres)
          describe "XFTP CLI (PostgreSQL)" $
            before (pure $ AFSType SFSPostgres) xftpCLIFileTests
#endif
          describe "Server CLIs" cliTests
#if defined(dbServerPostgres)
          around_ (postgressBracket testServerDBConnectInfo) $
            describe "SMP server schema dump" $
              postgresSchemaDumpTest
                serverMigrations
                [ "20250320_short_links", -- snd_secure moves to the bottom on down migration
                  "20260918_expire_messages" -- msg_queue_expire moves to the bottom on down migration
                ] -- skipComparisonForDownMigrations
                testServerDBOpts
                "src/Simplex/Messaging/Server/QueueStore/Postgres/server_schema.sql"
          around_ (postgressBracket ntfTestServerDBConnectInfo) $
            describe "Ntf server schema dump" $
              postgresSchemaDumpTest
                ntfServerMigrations
                [] -- skipComparisonForDownMigrations
                ntfTestServerDBOpts
                "src/Simplex/Messaging/Notifications/Server/Store/ntf_server_schema.sql"
#endif
#if defined(dbPostgres)
          around_ (postgressBracket testDBConnectInfo) $
            describe "Agent PostgreSQL schema dump" $
              postgresSchemaDumpTest
                appMigrations
                ["20250322_short_links"] -- snd_secure and last_broker_ts columns swap order on down migration
                (testDBOpts "smp_agent_test_protocol_schema")
                "src/Simplex/Messaging/Agent/Store/Postgres/Migrations/agent_postgres_schema.sql"
#else
          after_ (listDirectory tmpDir >>= mapM_ (removeFileIfExists . (tmpDir </>))) $
            describe "Agent SQLite schema dump" schemaDumpTest
#endif

dumpThreadsAfter :: Int -> IO ()
#if MIN_VERSION_base(4,18,0)
dumpThreadsAfter minutes = void . forkIO $ do
  threadDelay $ minutes * 60000000
  ts <- listThreads
  putStrLn $ "=== " <> show (length ts) <> " threads after " <> show minutes <> " minutes"
  forM_ ts $ \t -> do
    s <- threadStatus t
    l <- threadLabel t
    putStrLn $ show t <> " " <> show s <> " " <> maybe "" id l
#else
dumpThreadsAfter _ = pure ()
#endif

hspecInTmpDir :: Spec -> IO ()
hspecInTmpDir spec = do
  (config, forest) <- evalSpec defaultConfig spec
  config' <- getArgs >>= readConfig config
  withTmpDir (withArgs [] $ runSpecForest forest config') >>= evaluateResult

withTmpDir :: IO a -> IO a
withTmpDir = bracket_ (createDirectoryIfMissing False tmpDir >> clearTmpDir) clearTmpDir
  where
    clearTmpDir = listDirectory tmpDir >>= mapM_ (removePathForcibly . (tmpDir </>))
