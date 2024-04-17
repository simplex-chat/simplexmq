{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module SMPProxyTests where

import AgentTests.FunctionalAPITests (runRight, runRight_)
import Control.Logger.Simple
import Control.Monad.Except (runExceptT)
import Debug.Trace
import SMPAgentClient (testSMPServer, testSMPServer2)
import SMPClient
import qualified SMPClient as SMP
import ServerTests (sendRecv)
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (tshow)
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec
import UnliftIO

smpProxyTests :: Spec
smpProxyTests = do
  describe "server configuration" $ do
    it "refuses proxy handshake unless enabled" testNoProxy
    it "checks basic auth in proxy requests" testProxyAuth
  describe "proxy requests" $ do
    describe "bad relay URIs" $ do
      xit "host not resolved" todo
      xit "when SMP port blackholed" todo
      xit "no SMP service at host/port" todo
      xit "bad SMP fingerprint" todo
    it "connects to relay" testProxyConnect
    xit "connects to itself as a relay" todo
    xit "batching proxy requests" todo
  describe "forwarding requests" $ do
    fit "deliver message via SMP proxy" deliverMessageViaProxy
    xit "sender-proxy-relay-recipient works" todo
    xit "similar timing for proxied and direct sends" todo

deliverMessageViaProxy :: IO ()
deliverMessageViaProxy = do
  withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ -> do
    let proxyServ = SMPServer SMP.testHost SMP.testPort SMP.testKeyHash
    let relayServ = proxyServ
    g <- C.newRandom
    msgQ <- newTBQueueIO 4
    Right c <- getProtocolClient g (1, proxyServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion} (Just msgQ) (\_ -> pure ())
    runRight_ $ do
      THAuthClient {serverPeerPubKey} <- maybe (fail "getProtocolClient returned no thAuth") pure $ thAuth $ thParams c

    -- mimic SndQueue
      -- (sndPublicKey, sndPrivateKey) <- atomically $ C.generateAuthKeyPair C.SX25519 g
    -- (e2ePubKey, e2ePrivKey) <- atomically $ C.generateKeyPair @C.Ed25519 g
      (rPub, rPriv) <- atomically $ C.generateAuthKeyPair C.SEd448 g
      (rdhPub, rdhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
      QIK {rcvId, sndId, rcvPublicDhKey = srvDh} <- createSMPQueue c (rPub, rPriv) rdhPub (Just "correct") SMSubscribe

      -- let dec = decryptMsgV3 $ C.dh' srvDh rdhPriv

      (sessId, v, relayKey) <- createSMPProxySession c relayServ (Just "correct")
      proxySMPMessage c sessId v relayKey Nothing sndId noMsgFlags "hello"
      msg <- atomically $ readTBQueue msgQ
      liftIO $ print msg

      -- logError $ tshow (sessId, v, sk)

    -- fail "TODO: getProtocolClient for client-proxy and proxy-server"

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

testProxyConnect :: IO ()
testProxyConnect = do
  withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 Nothing)
      case reply of
        Right PKEY {} -> pure ()
        _ -> fail $ "bad reply: " <> show reply

todo :: IO ()
todo = do
  fail "TODO"
