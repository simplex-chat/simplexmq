{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPClient where

import Control.Concurrent (ThreadId, threadDelay)
import Control.Monad (void)
import Data.String (fromString)
import Data.Time.Clock (getCurrentTime)
import Network.Socket (ServiceName)
import SMPClient (serverBracket)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Server (runXFTPServerBlocking)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..), XFTPStoreConfig (..), AFStoreType (..), defaultFileExpiration, defaultInactiveClientExpiration)
import Simplex.FileTransfer.Server.Store (FileStoreClass, SFSType (..), STMFileStore)
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

data AXFTPServerConfig = forall s. FileStoreClass s => AXFTPSrvCfg (XFTPServerConfig s)

updateXFTPCfg :: AXFTPServerConfig -> (forall s. XFTPServerConfig s -> XFTPServerConfig s) -> AXFTPServerConfig
updateXFTPCfg (AXFTPSrvCfg cfg) f = AXFTPSrvCfg (f cfg)

cfgFS :: AFStoreType -> AXFTPServerConfig
cfgFS (AFSType fs) = case fs of
  SFSMemory -> AXFTPSrvCfg testXFTPServerConfig
#if defined(dbServerPostgres)
  SFSPostgres -> AXFTPSrvCfg testXFTPServerConfig {serverStoreCfg = XSCDatabase testXFTPPostgresCfg}
#endif

cfgFS2 :: AFStoreType -> AXFTPServerConfig
cfgFS2 (AFSType fs) = case fs of
  SFSMemory -> AXFTPSrvCfg testXFTPServerConfig2
#if defined(dbServerPostgres)
  SFSPostgres -> AXFTPSrvCfg testXFTPServerConfig2 {serverStoreCfg = XSCDatabase testXFTPPostgresCfg}
#endif

withXFTPServerConfigOn :: HasCallStack => AXFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerConfigOn (AXFTPSrvCfg cfg) = withXFTPServerCfg cfg

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

clearXFTPPostgresStore :: IO ()
clearXFTPPostgresStore = do
  let DBOpts {connstr} = dbOpts testXFTPPostgresCfg
  conn <- PSQL.connectPostgreSQL connstr
  void $ PSQL.execute_ conn "SET search_path TO xftp_server_test,public"
  void $ PSQL.execute_ conn "DELETE FROM files"
  PSQL.close conn
#endif

xftpTest :: HasCallStack => (HasCallStack => XFTPClient -> IO ()) -> AFStoreType -> Expectation
xftpTest test fsType = withXFTPServerConfigOn (cfgFS fsType) (\_ -> testXFTPClient test) `shouldReturn` ()

xftpTestN :: HasCallStack => Int -> (HasCallStack => [XFTPClient] -> IO ()) -> AFStoreType -> Expectation
xftpTestN nClients test fsType = withXFTPServerConfigOn (cfgFS fsType) (\_ -> run nClients []) `shouldReturn` ()
  where
    run :: Int -> [XFTPClient] -> IO ()
    run 0 hs = test hs
    run n hs = testXFTPClient $ \h -> run (n - 1) (h : hs)

xftpTest2 :: HasCallStack => (HasCallStack => XFTPClient -> XFTPClient -> IO ()) -> AFStoreType -> Expectation
xftpTest2 test = xftpTestN 2 _test
  where
    _test [h1, h2] = test h1 h2
    _test _ = error "expected 2 handles"

xftpTest4 :: HasCallStack => (HasCallStack => XFTPClient -> XFTPClient -> XFTPClient -> XFTPClient -> IO ()) -> AFStoreType -> Expectation
xftpTest4 test = xftpTestN 4 _test
  where
    _test [h1, h2, h3, h4] = test h1 h2 h3 h4
    _test _ = error "expected 4 handles"

withXFTPServerCfg :: (HasCallStack, FileStoreClass s) => XFTPServerConfig s -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfg cfg =
  serverBracket
    (\started -> runXFTPServerBlocking started cfg)
    (threadDelay 10000)

withXFTPServerCfgNoALPN :: (HasCallStack, FileStoreClass s) => XFTPServerConfig s -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfgNoALPN cfg = withXFTPServerCfg cfg {transportConfig = (transportConfig cfg) {serverALPN = Nothing}}

withXFTPServer :: HasCallStack => AFStoreType -> IO a -> IO a
withXFTPServer fsType = withXFTPServerConfigOn (cfgFS fsType) . const

withXFTPServer2 :: HasCallStack => AFStoreType -> IO a -> IO a
withXFTPServer2 fsType = withXFTPServerConfigOn (cfgFS2 fsType) . const

withXFTPServerStoreLogOn :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerStoreLogOn = withXFTPServerCfg testXFTPServerConfig {serverStoreCfg = XSCMemory (Just testXFTPLogFile), storeLogFile = Just testXFTPLogFile, serverStatsBackupFile = Just testXFTPStatsBackupFile}

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

testXFTPServerConfig :: XFTPServerConfig STMFileStore
testXFTPServerConfig =
  XFTPServerConfig
    { xftpPort = xftpTestPort,
      controlPort = Nothing,
      fileIdSize = 16,
      serverStoreCfg = XSCMemory Nothing,
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

testXFTPServerConfig2 :: XFTPServerConfig STMFileStore
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

testXFTPServerConfigSNI :: XFTPServerConfig STMFileStore
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

testXFTPServerConfigEd25519SNI :: XFTPServerConfig STMFileStore
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
