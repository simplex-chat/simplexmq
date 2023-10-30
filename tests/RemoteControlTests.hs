{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module RemoteControlTests where

import Control.Logger.Simple
import Data.List.NonEmpty (NonEmpty (..))
import Network.HTTP.Types (ok200)
import qualified Network.HTTP2.Client as C
import qualified Network.HTTP2.Server as S
import qualified Network.Socket as N
import qualified Network.TLS as TLS
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding (smpDecode)
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import qualified Simplex.Messaging.Transport as Transport
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2Response (..), closeHTTP2Client, sendRequest)
import Simplex.Messaging.Transport.HTTP2.Server (HTTP2Request (..))
import Simplex.Messaging.Util (tshow)
import qualified Simplex.RemoteControl.Discovery as Discovery
import Simplex.RemoteControl.Types
import Test.Hspec
import UnliftIO

remoteControlTests :: Spec
remoteControlTests = do
  it "generates usable credentials" genCredentialsTest
  it "connects announcer with discoverer over reverse-http2" announceDiscoverHttp2Test
  it "OOB encoding, decoding, and signatures are correct" oobCodecTest

-- * Low-level TLS with ephemeral credentials

genCredentialsTest :: HasCallStack => IO ()
genCredentialsTest = do
  (fingerprint, credentials) <- genTestCredentials
  started <- newEmptyTMVarIO
  bracket (Discovery.startTLSServer started credentials serverHandler) cancel $ \_server -> do
    ok <- atomically (readTMVar started)
    port <- maybe (error "TLS server failed to start") pure ok
    logNote $ "Assigned port: " <> tshow port
    Discovery.connectTLSClient ("127.0.0.1", fromIntegral port) fingerprint clientHandler
  where
    serverHandler serverTls = do
      logNote "Sending from server"
      Transport.putLn serverTls "hi client"
      logNote "Reading from server"
      Transport.getLn serverTls `shouldReturn` "hi server"
    clientHandler clientTls = do
      logNote "Sending from client"
      Transport.putLn clientTls "hi server"
      logNote "Reading from client"
      Transport.getLn clientTls `shouldReturn` "hi client"

-- * UDP discovery and rever HTTP2

oobCodecTest :: HasCallStack => IO ()
oobCodecTest = do
  subscribers <- newTMVarIO 0
  localAddr <- Discovery.getLocalAddress subscribers >>= maybe (fail "unable to get local address") pure
  (fingerprint, _credentials) <- genTestCredentials
  (_dhKey, _sigKey, _ann, signedOOB@(SignedOOB oob _sig)) <- Discovery.startSession (Just "Desktop") (localAddr, read Discovery.DISCOVERY_PORT) fingerprint
  verifySignedOOB signedOOB `shouldBe` True
  strDecode (strEncode oob) `shouldBe` Right oob
  strDecode (strEncode signedOOB) `shouldBe` Right signedOOB

announceDiscoverHttp2Test :: HasCallStack => IO ()
announceDiscoverHttp2Test = do
  subscribers <- newTMVarIO 0
  localAddr <- Discovery.getLocalAddress subscribers >>= maybe (fail "unable to get local address") pure
  (fingerprint, credentials) <- genTestCredentials
  (_dhKey, sigKey, ann, _oob) <- Discovery.startSession (Just "Desktop") (localAddr, read Discovery.DISCOVERY_PORT) fingerprint
  tasks <- newTVarIO []
  finished <- newEmptyMVar
  controller <- async $ do
    logNote "Controller: starting"
    bracket
      (Discovery.announceRevHTTP2 tasks (sigKey, ann) credentials (putMVar finished ()) >>= either (fail . show) pure)
      closeHTTP2Client
      ( \http -> do
          logNote "Controller: got client"
          sendRequest http (C.requestNoBody "GET" "/" []) (Just 10000000) >>= \case
            Left err -> do
              logNote "Controller: got error"
              fail $ show err
            Right HTTP2Response {} ->
              logNote "Controller: got response"
      )
  host <- async $ Discovery.withListener subscribers $ \sock -> do
    (N.SockAddrInet _port addr, sigAnn) <- Discovery.recvAnnounce sock
    SignedAnnounce Announce {caFingerprint, serviceAddress = (hostAddr, port)} _sig <- either fail pure $ smpDecode sigAnn
    caFingerprint `shouldBe` fingerprint
    addr `shouldBe` hostAddr
    let service = (THIPv4 $ N.hostAddressToTuple hostAddr, port)
    logNote $ "Host: connecting to " <> tshow service
    server <- async $ Discovery.connectTLSClient service fingerprint $ \tls -> do
      logNote "Host: got tls"
      flip Discovery.attachHTTP2Server tls $ \HTTP2Request {sendResponse} -> do
        logNote "Host: got request"
        sendResponse $ S.responseNoBody ok200 []
        logNote "Host: sent response"
    takeMVar finished `finally` cancel server
    logNote "Host: finished"
  tasks `registerAsync` controller
  tasks `registerAsync` host
  (waitBoth host controller `shouldReturn` ((), ())) `finally` cancelTasks tasks

genTestCredentials :: IO (C.KeyHash, TLS.Credentials)
genTestCredentials = do
  caCreds <- liftIO $ genCredentials Nothing (0, 24) "CA"
  sessionCreds <- liftIO $ genCredentials (Just caCreds) (0, 24) "Session"
  pure . tlsCredentials $ sessionCreds :| [caCreds]
