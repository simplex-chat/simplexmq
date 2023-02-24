{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module XFTPClient where

import Control.Concurrent (ThreadId)
import Data.String (fromString)
import Network.Socket (ServiceName)
import SMPClient (serverBracket)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Server (runXFTPServerBlocking)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..), defaultFileExpiration)
import Simplex.Messaging.Protocol (XFTPServer)
import Test.Hspec

xftpTest :: HasCallStack => (HasCallStack => XFTPClient -> IO ()) -> Expectation
xftpTest test = runXFTPTest test `shouldReturn` ()

xftpTestN :: HasCallStack => Int -> (HasCallStack => [XFTPClient] -> IO ()) -> Expectation
xftpTestN n test = runXFTPTestN n test `shouldReturn` ()

xftpTest2 :: HasCallStack => (HasCallStack => XFTPClient -> XFTPClient -> IO ()) -> Expectation
xftpTest2 test = xftpTestN 2 _test
  where
    _test [h1, h2] = test h1 h2
    _test _ = error "expected 2 handles"

runXFTPTest :: HasCallStack => (HasCallStack => XFTPClient -> IO a) -> IO a
runXFTPTest test = withXFTPServer $ testXFTPClient test

runXFTPTestN :: forall a. HasCallStack => Int -> (HasCallStack => [XFTPClient] -> IO a) -> IO a
runXFTPTestN nClients test = withXFTPServer $ run nClients []
  where
    run :: Int -> [XFTPClient] -> IO a
    run 0 hs = test hs
    run n hs = testXFTPClient $ \h -> run (n - 1) (h : hs)

-- withSmpServerStoreLogOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
-- withSmpServerStoreLogOn t = withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile, serverStatsBackupFile = Just testServerStatsBackupFile}

-- withSmpServerConfigOn :: HasCallStack => ATransport -> ServerConfig -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
-- withSmpServerConfigOn t cfg' port' =
--   serverBracket
--     (\started -> runSMPServerBlocking started cfg' {transports = [(port', t)]})
--     (pure ())

-- withSmpServerThreadOn :: HasCallStack => ATransport -> ServiceName -> (HasCallStack => ThreadId -> IO a) -> IO a
-- withSmpServerThreadOn t = withSmpServerConfigOn t cfg

withXFTPServerStoreLogOn :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerStoreLogOn = withXFTPServerCfg testXFTPServerConfig {storeLogFile = Just testXFTPLogFile}

withXFTPServerCfg :: HasCallStack => XFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfg cfg =
  serverBracket
    (`runXFTPServerBlocking` cfg)
    (pure ())

withXFTPServerThreadOn :: HasCallStack => (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerThreadOn = withXFTPServerCfg testXFTPServerConfig

withXFTPServer :: IO a -> IO a
withXFTPServer = withXFTPServerCfg testXFTPServerConfig . const

withXFTPServer2 :: IO a -> IO a
withXFTPServer2 = withXFTPServerCfg testXFTPServerConfig {xftpPort = xftpTestPort2, filesPath = xftpServerFiles2} . const

xftpTestPort :: ServiceName
xftpTestPort = "7000"

xftpTestPort2 :: ServiceName
xftpTestPort2 = "7001"

testXFTPServer :: XFTPServer
testXFTPServer = fromString testXFTPServerStr

testXFTPServerStr :: String
testXFTPServerStr = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:7000"

testXFTPServerStr2 :: String
testXFTPServerStr2 = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:7001"

xftpServerFiles :: FilePath
xftpServerFiles = "tests/tmp/xftp-server-files"

xftpServerFiles2 :: FilePath
xftpServerFiles2 = "tests/tmp/xftp-server-files2"

testXFTPLogFile :: FilePath
testXFTPLogFile = "tests/tmp/xftp-server-store.log"

testXFTPServerConfig :: XFTPServerConfig
testXFTPServerConfig =
  XFTPServerConfig
    { xftpPort = xftpTestPort,
      fileIdSize = 16,
      storeLogFile = Nothing,
      filesPath = xftpServerFiles,
      fileSizeQuota = Nothing,
      allowNewFiles = True,
      newFileBasicAuth = Nothing,
      fileExpiration = Just defaultFileExpiration,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt",
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/xftp-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      logTLSErrors = True
    }

testXFTPClientConfig :: XFTPClientConfig
testXFTPClientConfig = defaultXFTPClientConfig

testXFTPClient :: HasCallStack => (HasCallStack => XFTPClient -> IO a) -> IO a
testXFTPClient client =
  getXFTPClient (1, testXFTPServer, Nothing) testXFTPClientConfig (pure ()) >>= \case
    Right c -> client c
    Left e -> error $ show e
