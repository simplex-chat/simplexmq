{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.TransportTests (transportTests) where

import Control.Concurrent (threadDelay)
import Control.Exception (uninterruptibleMask_)
import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.Either (isLeft)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (ServiceName, Socket, SocketOption (KeepAlive), getSocketOption)
import SMPClient (serverBracket)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (defaultTransportClientConfig, runTLSTransportClient)
import Simplex.Messaging.Transport.KeepAlive (KeepAliveOpts, defaultKeepAliveOpts)
import Simplex.Messaging.Transport.Server
import Test.Hspec hiding (fit, it)
import UnliftIO.Async (async, wait, waitCatch)
import UnliftIO.STM
import UnliftIO.Timeout (timeout)
import Util

transportTests :: Spec
transportTests = do
  describe "TLS connection close" $
    it "should close connection while a sender is blocked by a peer that stopped reading" testCloseBlockedTLS
  describe "TCP keep-alive" $ do
    it "should enable keep-alive on accepted sockets when configured" $
      testServerKeepAlive (Just defaultKeepAliveOpts) True
    it "should not enable keep-alive on accepted sockets by default" $
      testServerKeepAlive Nothing False

transportTestPort :: HasTestEnv => ServiceName
transportTestPort = testServerPort 9

testCredentials :: ServerCredentials
testCredentials =
  ServerCredentials
    { caCertificateFile = Just "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

-- | Runs the client action with the server socket and TLS of the same connection
withTLSConnection :: HasTestEnv => TransportServerConfig -> (TLS 'TClient -> (Socket, TLS 'TServer) -> IO a) -> IO a
withTLSConnection cfg action = do
  credential <- loadServerCredential testCredentials
  Fingerprint fp <- loadFingerprint testCredentials
  ss <- newSocketState
  serverConn <- newEmptyTMVarIO
  let creds = TLSServerCredential {credential, sniCredential = Nothing}
      server sock (_, tls) = atomically (putTMVar serverConn (sock, tls)) >> threadDelay maxBound
  serverBracket
    (\started -> runTransportServerState_ ss started transportTestPort defaultSupportedParams creds cfg server)
    (pure ())
    $ \_ ->
      runTLSTransportClient defaultSupportedParams Nothing defaultTransportClientConfig Nothing "localhost" transportTestPort (Just $ C.KeyHash fp) $ \client ->
        atomically (takeTMVar serverConn) >>= action client

testCloseBlockedTLS :: HasTestEnv => Expectation
testCloseBlockedTLS = withTLSConnection (mkTransportServerConfig True Nothing False) $ \_client (_, server) -> do
  sent <- newTVarIO (0 :: Int)
  sender <- async . forever $ cPut server block >> atomically (modifyTVar' sent (+ 1))
  waitBlocked sent 0
  -- bracket release closes connections with exceptions masked
  closing <- async . uninterruptibleMask_ $ closeConnection server
  timeout 5000000 (wait closing) `shouldReturn` Just ()
  timeout 5000000 (isLeft <$> waitCatch sender) `shouldReturn` Just True
  where
    block = B.replicate 1048576 'x'
    -- the sender holds the TLS write lock once the socket buffers are full and it stops sending
    waitBlocked sent n = do
      threadDelay 500000
      n' <- readTVarIO sent
      unless (n' == n) $ waitBlocked sent n'

testServerKeepAlive :: HasTestEnv => Maybe KeepAliveOpts -> Bool -> Expectation
testServerKeepAlive tcpKeepAlive enabled =
  withTLSConnection (mkTransportServerConfig True Nothing False) {tcpKeepAlive} $ \_client (sock, _) ->
    ((/= 0) <$> getSocketOption sock KeepAlive) `shouldReturn` enabled
