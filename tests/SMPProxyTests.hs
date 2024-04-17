{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module SMPProxyTests where

import AgentTests.FunctionalAPITests (runRight_)
import Debug.Trace
import SMPAgentClient (testSMPServer, testSMPServer2)
import SMPClient
import qualified SMPClient as SMP
import ServerTests (decryptMsgV3, sendRecv)
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec
import UnliftIO

smpProxyTests :: Spec
smpProxyTests = focus $ do
  describe "server configuration" $ do
    it "refuses proxy handshake unless enabled" testNoProxy
    it "checks basic auth in proxy requests" testProxyAuth
  describe "proxy requests" $ do
    describe "bad relay URIs" $ do
      xit "host not resolved" todo
      xit "when SMP port blackholed" todo
      xit "no SMP service at host/port" todo
      xit "bad SMP fingerprint" todo
    xit "batching proxy requests" todo
  describe "forwarding requests" $ do
    describe "deliver message via SMP proxy" $ do
      it "same server" $
        withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ -> do
          let proxyServ = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
          let relayServ = proxyServ
          deliverMessageViaProxy proxyServ relayServ
      it "different servers" $
        withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ ->
          withSmpServerConfigOn (transport @TLS) cfgV7 testPort2 $ \_ -> do
            let proxyServ = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
            let relayServ = SMPServer SMP.testHost SMP.testPort2 SMP.testKeyHash
            deliverMessageViaProxy proxyServ relayServ
    xit "sender-proxy-relay-recipient works" todo
    xit "similar timing for proxied and direct sends" todo

deliverMessageViaProxy :: SMPServer -> SMPServer -> IO ()
deliverMessageViaProxy proxyServ relayServ = do
  g <- C.newRandom
  -- set up proxy
  Right pc <- getProtocolClient g (1, proxyServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion} Nothing (\_ -> pure ())
  THAuthClient {} <- maybe (fail "getProtocolClient returned no thAuth") pure $ thAuth $ thParams pc
  -- set up relay
  msgQ <- newTBQueueIO 4
  Right rc <- getProtocolClient g (2, relayServ, Nothing) defaultSMPClientConfig (Just msgQ) (\_ -> pure ())
  runRight_ $ do
    -- prepare receiving queue
    (rPub, rPriv) <- atomically $ C.generateAuthKeyPair C.SEd448 g
    (rdhPub, rdhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    QIK {sndId, rcvPublicDhKey = srvDh} <- createSMPQueue rc (rPub, rPriv) rdhPub (Just "correct") SMSubscribe
    let dec = decryptMsgV3 $ C.dh' srvDh rdhPriv
    -- run proxy test
    (sessId, v, relayKey) <- createSMPProxySession pc relayServ (Just "correct")
    proxySMPMessage pc sessId v relayKey Nothing sndId noMsgFlags "hello"
    -- check delivery
    (_tSess, _v, _sid, _ety, MSG RcvMessage {msgId, msgBody = EncRcvMsgBody encBody}) <- atomically $ readTBQueue msgQ
    liftIO $ dec msgId encBody `shouldBe` Right "hello"

proxyVRange :: VersionRangeSMP
proxyVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion

testNoProxy :: IO ()
testNoProxy = do
  withSmpServerConfigOn (transport @TLS) cfg testPort2 $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort2 proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer Nothing)
      reply `shouldBe` Right (ERR AUTH)

testProxyAuth :: IO ()
testProxyAuth = do
  withSmpServerConfigOn (transport @TLS) proxyCfgAuth testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, s, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 $ Just "wrong")
      traceShowM s
      reply `shouldBe` Right (ERR AUTH)
  where
    proxyCfgAuth = proxyCfg {newQueueBasicAuth = Just "correct"}

todo :: IO ()
todo = do
  fail "TODO"
