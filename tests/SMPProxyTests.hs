{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module SMPProxyTests where

import AgentTests.FunctionalAPITests
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import SMPAgentClient
import SMPClient
import ServerTests (decryptMsgV3, sendRecv)
import Simplex.Messaging.Agent hiding (createConnection, joinConnection, sendMessage)
import qualified Simplex.Messaging.Agent as A
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers (..))
import Simplex.Messaging.Agent.Protocol hiding (CON, CONF, INFO, REQ)
import qualified Simplex.Messaging.Agent.Protocol as A
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (pattern PQSupportOn)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport
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
    xit "batching proxy requests" todo
  describe "deliver message via SMP proxy" $ do
    let srv1 = SMPServer testHost testPort testKeyHash
        srv2 = SMPServer testHost testPort2 testKeyHash
    describe "client API" $ do
      let maxLen = maxMessageLength sendingProxySMPVersion
      describe "one server" $ do
        it "deliver via proxy" . oneServer $ do
          deliverMessageViaProxy srv1 srv1 C.SEd448 "hello 1" "hello 2"
      describe "two servers" $ do
        let proxyServ = srv1
            relayServ = srv2
        (msg1, msg2) <- runIO $ do
          g <- C.newRandom
          atomically $ (,) <$> C.randomBytes maxLen g <*> C.randomBytes maxLen g
        it "deliver via proxy" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd448 "hello 1" "hello 2"
        it "max message size, Ed448 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd448 msg1 msg2
        it "max message size, Ed25519 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SEd25519 msg1 msg2
        it "max message size, X25519 keys" . twoServersFirstProxy $
          deliverMessageViaProxy proxyServ relayServ C.SX25519 msg1 msg2
    describe "agent API" $ do
      describe "one server" $ do
        it "always via proxy" . oneServer $
          agentDeliverMessageViaProxy ([srv1], SPMAlways, True) ([srv1], SPMAlways, True) C.SEd448 "hello 1" "hello 2"
        it "without proxy" . oneServer $
          agentDeliverMessageViaProxy ([srv1], SPMNever, False) ([srv1], SPMNever, False) C.SEd448 "hello 1" "hello 2"
      describe "two servers" $ do
        it "always via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMAlways, True) ([srv2], SPMAlways, True) C.SEd448 "hello 1" "hello 2"
        it "both via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv2], SPMUnknown, True) C.SEd448 "hello 1" "hello 2"
        it "first via proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv2], SPMNever, False) C.SEd448 "hello 1" "hello 2"
        it "without proxy" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMNever, False) ([srv2], SPMNever, False) C.SEd448 "hello 1" "hello 2"
        it "first via proxy for unknown" . twoServers $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, True) ([srv1, srv2], SPMUnknown, False) C.SEd448 "hello 1" "hello 2"
        it "without proxy with fallback" . twoServers_ proxyCfg cfgV7 $
          agentDeliverMessageViaProxy ([srv1], SPMUnknown, False) ([srv2], SPMUnknown, False) C.SEd448 "hello 1" "hello 2"
        it "fails when fallback is prohibited" . twoServers_ proxyCfg cfgV7 $
          agentViaProxyVersionError
  where
    oneServer = withSmpServerConfigOn (transport @TLS) proxyCfg testPort . const
    twoServers = twoServers_ proxyCfg proxyCfg
    twoServersFirstProxy = twoServers_ proxyCfg cfgV8
    twoServers_ cfg1 cfg2 runTest =
      withSmpServerConfigOn (transport @TLS) cfg1 testPort $ \_ ->
        withSmpServerConfigOn (transport @TLS) cfg2 testPort2 $ const runTest

deliverMessageViaProxy :: (C.AlgorithmI a, C.AuthAlgorithm a) => SMPServer -> SMPServer -> C.SAlgorithm a -> ByteString -> ByteString -> IO ()
deliverMessageViaProxy proxyServ relayServ alg msg msg' = do
  g <- C.newRandom
  -- set up proxy
  Right pc <- getProtocolClient g (1, proxyServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion sendingProxySMPVersion} Nothing (\_ -> pure ())
  THAuthClient {} <- maybe (fail "getProtocolClient returned no thAuth") pure $ thAuth $ thParams pc
  -- set up relay
  msgQ <- newTBQueueIO 4
  Right rc <- getProtocolClient g (2, relayServ, Nothing) defaultSMPClientConfig {serverVRange = mkVersionRange batchCmdsSMPVersion authCmdsSMPVersion} (Just msgQ) (\_ -> pure ())
  runRight_ $ do
    -- prepare receiving queue
    (rPub, rPriv) <- atomically $ C.generateAuthKeyPair alg g
    (rdhPub, rdhPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
    QIK {rcvId, sndId, rcvPublicDhKey = srvDh} <- createSMPQueue rc (rPub, rPriv) rdhPub (Just "correct") SMSubscribe
    let dec = decryptMsgV3 $ C.dh' srvDh rdhPriv
    -- get proxy session
    sess <- connectSMPProxiedRelay pc relayServ (Just "correct")
    -- send via proxy to unsecured queue
    Right () <- proxySMPMessage pc sess Nothing sndId noMsgFlags msg
    -- receive 1
    (_tSess, _v, _sid, [(_entId, STEvent (Right (SMP.MSG RcvMessage {msgId, msgBody = EncRcvMsgBody encBody})))]) <- atomically $ readTBQueue msgQ
    liftIO $ dec msgId encBody `shouldBe` Right msg
    ackSMPMessage rc rPriv rcvId msgId
    -- secure queue
    (sPub, sPriv) <- atomically $ C.generateAuthKeyPair alg g
    secureSMPQueue rc rPriv rcvId sPub
    -- send via proxy to secured queue
    Right () <- proxySMPMessage pc sess (Just sPriv) sndId noMsgFlags msg'
    -- receive 2
    (_tSess, _v, _sid, [(_entId, STEvent (Right (SMP.MSG RcvMessage {msgId = msgId', msgBody = EncRcvMsgBody encBody'})))]) <- atomically $ readTBQueue msgQ
    liftIO $ dec msgId' encBody' `shouldBe` Right msg'
    ackSMPMessage rc rPriv rcvId msgId'

agentDeliverMessageViaProxy :: (C.AlgorithmI a, C.AuthAlgorithm a) => (NonEmpty SMPServer, SMPProxyMode, Bool) -> (NonEmpty SMPServer, SMPProxyMode, Bool) -> C.SAlgorithm a -> ByteString -> ByteString -> IO ()
agentDeliverMessageViaProxy aTestCfg@(aSrvs, _, aViaProxy) bTestCfg@(bSrvs, _, bViaProxy) alg msg1 msg2 =
  withAgent 1 aCfg (servers aTestCfg) testDB $ \alice ->
    withAgent 2 aCfg (servers bTestCfg) testDB2 $ \bob -> runRight_ $ do
      (bobId, qInfo) <- A.createConnection alice 1 True SCMInvitation Nothing (CR.IKNoPQ PQSupportOn) SMSubscribe
      aliceId <- A.joinConnection bob 1 Nothing True qInfo "bob's connInfo" PQSupportOn SMSubscribe
      ("", _, A.CONF confId pqSup' _ "bob's connInfo") <- get alice
      liftIO $ pqSup' `shouldBe` PQSupportOn
      allowConnection alice bobId confId "alice's connInfo"
      let pqEnc = CR.PQEncOn
      get alice ##> ("", bobId, A.CON pqEnc)
      get bob ##> ("", aliceId, A.INFO PQSupportOn "alice's connInfo")
      get bob ##> ("", aliceId, A.CON pqEnc)
      -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
      let aProxySrv = if aViaProxy then Just $ L.head aSrvs else Nothing
      1 <- msgId <$> A.sendMessage alice bobId pqEnc noMsgFlags msg1
      get alice ##> ("", bobId, A.SENT (baseId + 1) aProxySrv)
      2 <- msgId <$> A.sendMessage alice bobId pqEnc noMsgFlags msg2
      get alice ##> ("", bobId, A.SENT (baseId + 2) aProxySrv)
      get bob =##> \case ("", c, Msg' _ pq msg1') -> c == aliceId && pq == pqEnc && msg1 == msg1'; _ -> False
      ackMessage bob aliceId (baseId + 1) Nothing
      get bob =##> \case ("", c, Msg' _ pq msg2') -> c == aliceId && pq == pqEnc && msg2 == msg2'; _ -> False
      ackMessage bob aliceId (baseId + 2) Nothing
      let bProxySrv = if bViaProxy then Just $ L.head bSrvs else Nothing
      3 <- msgId <$> A.sendMessage bob aliceId pqEnc noMsgFlags msg1
      get bob ##> ("", aliceId, A.SENT (baseId + 3) bProxySrv)
      4 <- msgId <$> A.sendMessage bob aliceId pqEnc noMsgFlags msg2
      get bob ##> ("", aliceId, A.SENT (baseId + 4) bProxySrv)
      get alice =##> \case ("", c, Msg' _ pq msg1') -> c == bobId && pq == pqEnc && msg1 == msg1'; _ -> False
      ackMessage alice bobId (baseId + 3) Nothing
      get alice =##> \case ("", c, Msg' _ pq msg2') -> c == bobId && pq == pqEnc && msg2 == msg2'; _ -> False
      ackMessage alice bobId (baseId + 4) Nothing
  where
    baseId = 3
    msgId = subtract baseId . fst
    aCfg = agentProxyCfg {sndAuthAlg = C.AuthAlg alg, rcvAuthAlg = C.AuthAlg alg}
    servers (srvs, smpProxyMode, _) = (initAgentServersProxy smpProxyMode SPFAllow) {smp = userServers $ L.map noAuthSrv srvs}

agentViaProxyVersionError :: IO ()
agentViaProxyVersionError =
  withAgent 1 agentProxyCfg (servers [SMPServer testHost testPort testKeyHash]) testDB $ \alice -> do
    Left (A.BROKER _ (TRANSPORT TEVersion)) <-
      withAgent 2 agentProxyCfg (servers [SMPServer testHost testPort2 testKeyHash]) testDB2 $ \bob -> runExceptT $ do
        (_bobId, qInfo) <- A.createConnection alice 1 True SCMInvitation Nothing (CR.IKNoPQ PQSupportOn) SMSubscribe
        A.joinConnection bob 1 Nothing True qInfo "bob's connInfo" PQSupportOn SMSubscribe
    pure ()
  where
    servers srvs = (initAgentServersProxy SPMUnknown SPFProhibit) {smp = userServers $ L.map noAuthSrv srvs}

testNoProxy :: IO ()
testNoProxy = do
  withSmpServerConfigOn (transport @TLS) cfg testPort2 $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort2 proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer Nothing)
      reply `shouldBe` Right (SMP.ERR $ SMP.PROXY SMP.BASIC_AUTH)

testProxyAuth :: IO ()
testProxyAuth = do
  withSmpServerConfigOn (transport @TLS) proxyCfgAuth testPort $ \_ -> do
    testSMPClient_ "127.0.0.1" testPort proxyVRange $ \(th :: THandleSMP TLS 'TClient) -> do
      (_, _s, (_corrId, _entityId, reply)) <- sendRecv th (Nothing, "0", "", PRXY testSMPServer2 $ Just "wrong")
      reply `shouldBe` Right (SMP.ERR $ SMP.PROXY SMP.BASIC_AUTH)
  where
    proxyCfgAuth = proxyCfg {newQueueBasicAuth = Just "correct"}

todo :: IO ()
todo = do
  fail "TODO"
