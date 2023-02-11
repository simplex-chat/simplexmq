{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module XFTPClient where

import Control.Concurrent (ThreadId)
import Network.Socket (ServiceName)
import SMPClient (serverBracket)
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Server (runXFTPServerBlocking)
import Simplex.FileTransfer.Server.Env (XFTPServerConfig (..))
import Simplex.Messaging.Protocol (XFTPServer)
import Test.Hspec

xftpTest :: HasCallStack => (HasCallStack => XFTPClient -> IO ()) -> Expectation
xftpTest test = runXFTPTest test `shouldReturn` ()

runXFTPTest :: HasCallStack => (HasCallStack => XFTPClient -> IO a) -> IO a
runXFTPTest test = withXFTPServer $ testXFTPClient test

withXFTPServerCfg :: HasCallStack => XFTPServerConfig -> (HasCallStack => ThreadId -> IO a) -> IO a
withXFTPServerCfg cfg =
  serverBracket
    (`runXFTPServerBlocking` cfg)
    (pure ())

withXFTPServer :: IO a -> IO a
withXFTPServer = withXFTPServerCfg testXFTPServerConfig . const

xftpTestPort :: ServiceName
xftpTestPort = "7000"

testXFTPServer :: XFTPServer
testXFTPServer = "xftp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:7000"

testXFTPServerConfig :: XFTPServerConfig
testXFTPServerConfig =
  XFTPServerConfig
    { xftpPort = xftpTestPort,
      fileIdSize = 16,
      storeLogFile = Nothing,
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
