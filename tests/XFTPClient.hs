{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPClient where

import Control.Concurrent (ThreadId, threadDelay)
import Control.Exception (SomeException, catch)
import System.Directory (removeFile)
import Control.Monad (void)
import Data.String (fromString)
import Data.Time.Clock (getCurrentTime)
import Network.Socket (ServiceName)
import SMPClient (serverBracket)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Server (runXFTPServerBlocking)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..), XFTPStoreConfig (..), defaultFileExpiration, defaultInactiveClientExpiration)
import Simplex.FileTransfer.Server.Store (FileStoreClass)
import Simplex.FileTransfer.Transport (alpnSupportedXFTPhandshakes, supportedFileServerVRange)
import Simplex.Messaging.Protocol (XFTPServer)
import Simplex.Messaging.Transport.HTTP2 (httpALPN)
import Simplex.Messaging.Transport.Server
import Test.Hspec hiding (fit, it)
#if defined(dbServerPostgres)
import qualified Database.PostgreSQL.Simple as PSQL
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
import Simplex.FileTransfer.Server.Store.Postgres.Config (PostgresFileStoreCfg (..), defaultXFTPDBOpts)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
#endif

-- Parameterized server bracket

newtype XFTPTestBracket = XFTPTestBracket
  { runBracket :: forall a. (XFTPServerConfig -> XFTPServerConfig) -> IO a -> IO a
  }

-- Store-log-dependent agent tests need the bracket + a way to clear server state
type XFTPTestBracketClear = (XFTPTestBracket, IO ())

xftpMemoryBracket :: XFTPTestBracket
xftpMemoryBracket = XFTPTestBracket $ \cfgF test -> withXFTPServerCfg_ (XSCMemory Nothing) (cfgF testXFTPServerConfig) $ \_ -> test

xftpMemoryBracketWithLog :: XFTPTestBracket
xftpMemoryBracketWithLog = XFTPTestBracket $ \cfgF test ->
  withXFTPServerCfg (cfgF testXFTPServerConfig {storeLogFile = Just testXFTPLogFile, serverStatsBackupFile = Just testXFTPStatsBackupFile}) $ \_ -> test

xftpMemoryBracketClear :: XFTPTestBracketClear
xftpMemoryBracketClear = (xftpMemoryBracketWithLog, removeFile testXFTPLogFile `catch` \(_ :: SomeException) -> pure ())

xftpMemoryBracket2 :: XFTPTestBracket
xftpMemoryBracket2 = XFTPTestBracket $ \cfgF test -> withXFTPServerCfg_ (XSCMemory Nothing) (cfgF testXFTPServerConfig2) $ \_ -> test

#if defined(dbServerPostgres)
testXFTPDBConnectInfo :: ConnectInfo
testXFTPDBConnectInfo =
  defaultConnectInfo
    { connectUser = "test_xftp_server_user",
      connectDatabase = "test_xftp_server_db"
    }

testXFTPPostgresCfg :: PostgresFileStoreCfg
testXFTPPostgresCfg =
  PostgresFileStoreCfg
    { dbOpts = defaultXFTPDBOpts
        { connstr = "postgresql://test_xftp_server_user@/test_xftp_server_db",
          schema = "xftp_server_test",
          poolSize = 10,
          createSchema = True
        },
      dbStoreLogPath = Nothing,
      confirmMigrations = MCYesUp
    }

xftpPostgresBracket :: XFTPTestBracket
xftpPostgresBracket = XFTPTestBracket $ \cfgF test -> withXFTPServerCfg_ (XSCDatabase testXFTPPostgresCfg) (cfgF testXFTPServerConfig) $ \_ -> test

xftpPostgresBracket2 :: XFTPTestBracket
xftpPostgresBracket2 = XFTPTestBracket $ \cfgF test -> withXFTPServerCfg_ (XSCDatabase testXFTPPostgresCfg) (cfgF testXFTPServerConfig2) $ \_ -> test

xftpPostgresBracketClear :: XFTPTestBracketClear
xftpPostgresBracketClear = (xftpPostgresBracket, clearXFTPPostgresStore)

clearXFTPPostgresStore :: IO ()
clearXFTPPostgresStore = do
  let DBOpts {connstr} = dbOpts testXFTPPostgresCfg
  conn <- PSQL.connectPostgreSQL connstr
  void $ PSQL.execute_ conn "SET search_path TO xftp_server_test,public"
  void $ PSQL.execute_ conn "DELETE FROM files"
  PSQL.close conn
#endif

-- Core server bracket (store-parameterized)

withXFTPServerCfg_ :: (HasCallStack, FileStoreClass s) => XFTPStoreConfig s -> XFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfg_ storeCfg cfg =
  serverBracket
    (\started -> runXFTPServerBlocking started storeCfg cfg)
    (threadDelay 10000)

-- Memory-only server helpers (used by tests that don't parameterize)

withXFTPServerCfg :: HasCallStack => XFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfg cfg = withXFTPServerCfg_ (XSCMemory $ storeLogFile cfg) cfg

withXFTPServerCfgNoALPN :: HasCallStack => XFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfgNoALPN cfg = withXFTPServerCfg cfg {transportConfig = (transportConfig cfg) {serverALPN = Nothing}}

withXFTPServerStoreLogOn :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerStoreLogOn = withXFTPServerCfg testXFTPServerConfig {storeLogFile = Just testXFTPLogFile, serverStatsBackupFile = Just testXFTPStatsBackupFile}

withXFTPServerThreadOn :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerThreadOn = withXFTPServerCfg testXFTPServerConfig

-- Constants

xftpTestPort :: ServiceName
xftpTestPort = "8000"

xftpTestPort2 :: ServiceName
xftpTestPort2 = "8001"

testXFTPServer :: XFTPServer
testXFTPServer = fromString testXFTPServerStr

testXFTPServer2 :: XFTPServer
testXFTPServer2 = fromString testXFTPServerStr2

testXFTPServerStr :: String
testXFTPServerStr = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:8000"

testXFTPServerStr2 :: String
testXFTPServerStr2 = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:8001"

xftpServerFiles :: FilePath
xftpServerFiles = "tests/tmp/xftp-server-files"

xftpServerFiles2 :: FilePath
xftpServerFiles2 = "tests/tmp/xftp-server-files2"

testXFTPLogFile :: FilePath
testXFTPLogFile = "tests/tmp/xftp-server-store.log"

testXFTPStatsBackupFile :: FilePath
testXFTPStatsBackupFile = "tests/tmp/xftp-server-stats.log"

xftpTestPrometheusMetricsFile :: FilePath
xftpTestPrometheusMetricsFile = "tests/tmp/xftp-server-metrics.txt"

testXFTPServerConfig :: XFTPServerConfig
testXFTPServerConfig =
  XFTPServerConfig
    { xftpPort = xftpTestPort,
      controlPort = Nothing,
      fileIdSize = 16,
      storeLogFile = Nothing,
      filesPath = xftpServerFiles,
      fileSizeQuota = Nothing,
      allowedChunkSizes = [kb 64, kb 128, kb 256, mb 1, mb 4],
      allowNewFiles = True,
      newFileBasicAuth = Nothing,
      controlPortAdminAuth = Nothing,
      controlPortUserAuth = Nothing,
      fileExpiration = Just defaultFileExpiration,
      fileTimeout = 10000000,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      xftpCredentials =
        ServerCredentials
          { caCertificateFile = Just "tests/fixtures/ca.crt",
            privateKeyFile = "tests/fixtures/server.key",
            certificateFile = "tests/fixtures/server.crt"
          },
      httpCredentials = Nothing,
      xftpServerVRange = supportedFileServerVRange,
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/tmp/xftp-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      prometheusInterval = Nothing,
      prometheusMetricsFile = xftpTestPrometheusMetricsFile,
      transportConfig = mkTransportServerConfig True (Just alpnSupportedXFTPhandshakes) False,
      responseDelay = 0,
      webStaticPath = Nothing
    }

testXFTPServerConfig2 :: XFTPServerConfig
testXFTPServerConfig2 = testXFTPServerConfig {xftpPort = xftpTestPort2, filesPath = xftpServerFiles2}

testXFTPClientConfig :: XFTPClientConfig
testXFTPClientConfig = defaultXFTPClientConfig

testXFTPClient :: HasCallStack => (HasCallStack => XFTPClient -> IO a) -> IO a
testXFTPClient = testXFTPClientWith testXFTPClientConfig

testXFTPClientWith :: HasCallStack => XFTPClientConfig -> (HasCallStack => XFTPClient -> IO a) -> IO a
testXFTPClientWith cfg client = do
  ts <- getCurrentTime
  getXFTPClient (1, testXFTPServer, Nothing) cfg [] ts (\_ -> pure ()) >>= \case
    Right c -> client c
    Left e -> error $ show e

testXFTPServerConfigSNI :: XFTPServerConfig
testXFTPServerConfigSNI =
  testXFTPServerConfig
    { httpCredentials =
        Just
          ServerCredentials
            { caCertificateFile = Nothing,
              privateKeyFile = "tests/fixtures/web.key",
              certificateFile = "tests/fixtures/web.crt"
            },
      transportConfig =
        (mkTransportServerConfig True (Just $ alpnSupportedXFTPhandshakes <> httpALPN) False)
          { addCORSHeaders = True
          }
    }

withXFTPServerSNI :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerSNI = withXFTPServerCfg testXFTPServerConfigSNI

testXFTPServerConfigEd25519SNI :: XFTPServerConfig
testXFTPServerConfigEd25519SNI =
  testXFTPServerConfig
    { xftpCredentials =
        ServerCredentials
          { caCertificateFile = Just "tests/fixtures/ed25519/ca.crt",
            privateKeyFile = "tests/fixtures/ed25519/server.key",
            certificateFile = "tests/fixtures/ed25519/server.crt"
          },
      httpCredentials =
        Just
          ServerCredentials
            { caCertificateFile = Nothing,
              privateKeyFile = "tests/fixtures/web.key",
              certificateFile = "tests/fixtures/web.crt"
            },
      transportConfig =
        (mkTransportServerConfig True (Just $ alpnSupportedXFTPhandshakes <> httpALPN) False)
          { addCORSHeaders = True
          }
    }
