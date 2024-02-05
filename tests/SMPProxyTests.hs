{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPProxyTests where

import SMPAgentClient (testSMPServer, testSMPServer2)
import SMPClient
import ServerTests (sendRecv)
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport
import Test.Hspec
import Debug.Trace

smpProxyTests :: Spec
smpProxyTests = focus $ do
  describe "server configuration" $ do
    it "refuses proxy handshake unless enabled" testNoProxy
    it "checks basic auth in proxy requests" testProxyAuth
  describe "proxy requests" $ do
    xdescribe "bad relay URIs" $ do
      it "host not resolved" todo
      it "when SMP port blackholed" todo
      it "no SMP service at host/port" todo
      it "bad SMP fingerprint" todo
    it "connects to relay" testProxyConnect
    xit "connects to itself as a relay" todo
    xit "batching proxy requests" todo
  xdescribe "forwarding requests" $ do
    it "sender-proxy-relay-recipient works" todo
    it "similar timing for proxied and direct sends" todo

testNoProxy :: IO ()
testNoProxy = do
  withSmpServerConfigOn (transport @TLS) cfg testPort2 $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort2 $ \(th :: THandle TLS) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer Nothing)
      reply `shouldBe` Right (ERR AUTH)

testProxyAuth :: IO ()
testProxyAuth = do
  withSmpServerConfigOn (transport @TLS) proxyCfgAuth testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort $ \(th :: THandle TLS) -> do
      (_, s, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 $ Just "wrong")
      traceShowM s
      reply `shouldBe` Right (ERR AUTH)
  where
    proxyCfgAuth = proxyCfg {newQueueBasicAuth = Just "correct"}

testProxyConnect :: IO ()
testProxyConnect = do
  withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort $ \(th :: THandle TLS) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 Nothing)
      case reply of
        Right PKEY {} -> pure ()
        _ -> fail $ "bad reply: " <> show reply

todo :: IO ()
todo = do
  fail "TODO"
