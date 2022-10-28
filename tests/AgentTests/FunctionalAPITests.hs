{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.FunctionalAPITests
  ( functionalAPITests,
    makeConnection,
    get,
    (##>),
    (=##>),
    pattern Msg,
  )
where

import Control.Concurrent (killThread, threadDelay)
import Control.Monad
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.IO.Unlift
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import SMPAgentClient
import SMPClient (cfg, testPort, testPort2, testStoreLogFile2, withSmpServer, withSmpServerConfigOn, withSmpServerOn, withSmpServerStoreLogOn, withSmpServerStoreMsgLogOn)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers)
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Client (ProtocolClientConfig (..))
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ATransport (..))
import Simplex.Messaging.Version
import Test.Hspec
import UnliftIO

(##>) :: MonadIO m => m (ATransmission 'Agent) -> ATransmission 'Agent -> m ()
a ##> t = a >>= \t' -> liftIO (t' `shouldBe` t)

(=##>) :: MonadIO m => m (ATransmission 'Agent) -> (ATransmission 'Agent -> Bool) -> m ()
a =##> p = a >>= \t -> liftIO (t `shouldSatisfy` p)

get :: MonadIO m => AgentClient -> m (ATransmission 'Agent)
get c = do
  t@(_, _, cmd) <- atomically (readTBQueue $ subQ c)
  case cmd of
    CONNECT {} -> get c
    DISCONNECT {} -> get c
    _ -> pure t

pattern Msg :: MsgBody -> ACommand 'Agent
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk} _ msgBody

smpCfgV1 :: ProtocolClientConfig
smpCfgV1 = (smpCfg agentCfg) {smpServerVRange = vr11}

agentCfgV1 :: AgentConfig
agentCfgV1 = agentCfg {smpAgentVRange = vr11, smpClientVRange = vr11, e2eEncryptVRange = vr11, smpCfg = smpCfgV1}

agentCfgRatchetV1 :: AgentConfig
agentCfgRatchetV1 = agentCfg {e2eEncryptVRange = vr11}

vr11 :: VersionRange
vr11 = mkVersionRange 1 1

functionalAPITests :: ATransport -> Spec
functionalAPITests t = do
  describe "Establishing duplex connection" $
    testMatrix2 t runAgentClientTest
  describe "Establishing duplex connection v2, different Ratchet versions" $
    testRatchetMatrix2 t runAgentClientTest
  describe "Establish duplex connection via contact address" $
    testMatrix2 t runAgentClientContactTest
  describe "Establish duplex connection via contact address v2, different Ratchet versions" $
    testRatchetMatrix2 t runAgentClientContactTest
  describe "Establishing connection asynchronously" $ do
    it "should connect with initiating client going offline" $
      withSmpServer t testAsyncInitiatingOffline
    it "should connect with joining client going offline before its queue activation" $
      withSmpServer t testAsyncJoiningOfflineBeforeActivation
    it "should connect with both clients going offline" $
      withSmpServer t testAsyncBothOffline
    it "should connect on the second attempt if server was offline" $
      testAsyncServerOffline t
    it "should notify after HELLO timeout" $
      withSmpServer t testAsyncHelloTimeout
  describe "Duplicate message delivery" $
    it "should deliver messages to the user once, even if repeat delivery is made by the server (no ACK)" $
      testDuplicateMessage t
  describe "Inactive client disconnection" $ do
    it "should disconnect clients if it was inactive longer than TTL" $
      testInactiveClientDisconnected t
    it "should NOT disconnect active clients" $
      testActiveClientNotDisconnected t
  describe "Suspending agent" $ do
    it "should update client when agent is suspended" $
      withSmpServer t testSuspendingAgent
    it "should complete sending messages when agent is suspended" $
      testSuspendingAgentCompleteSending t
    it "should suspend agent on timeout, even if pending messages not sent" $
      testSuspendingAgentTimeout t
  describe "Batching SMP commands" $ do
    it "should subscribe to multiple subscriptions with batching" $
      testBatchedSubscriptions t
  describe "Async agent commands" $ do
    it "should connect using async agent commands" $
      withSmpServer t testAsyncCommands
    it "should restore and complete async commands on restart" $
      testAsyncCommandsRestore t
    it "should accept connection using async command" $
      withSmpServer t testAcceptContactAsync
  describe "Queue rotation" $ do
    it "should switch delivery to the new queue (1 server)" $
      withSmpServer t $ testSwitchConnection initAgentServers
    it "should switch delivery to the new queue (2 servers)" $
      withSmpServer t . withSmpServerOn t testPort2 $ testSwitchConnection initAgentServers2
    it "should switch to new queue asynchronously (1 server)" $
      withSmpServer t $ testSwitchAsync initAgentServers
    it "should switch to new queue asynchronously (2 servers)" $
      withSmpServer t . withSmpServerOn t testPort2 $ testSwitchAsync initAgentServers2

testMatrix2 :: ATransport -> (AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> Spec
testMatrix2 t runTest = do
  it "v2" $ withSmpServer t $ runTestCfg2 agentCfg agentCfg 3 runTest
  it "v1" $ withSmpServer t $ runTestCfg2 agentCfgV1 agentCfgV1 4 runTest
  it "v1 to v2" $ withSmpServer t $ runTestCfg2 agentCfgV1 agentCfg 4 runTest
  it "v2 to v1" $ withSmpServer t $ runTestCfg2 agentCfg agentCfgV1 4 runTest

testRatchetMatrix2 :: ATransport -> (AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> Spec
testRatchetMatrix2 t runTest = do
  it "ratchet v2" $ withSmpServer t $ runTestCfg2 agentCfg agentCfg 3 runTest
  it "ratchet v1" $ withSmpServer t $ runTestCfg2 agentCfgRatchetV1 agentCfgRatchetV1 3 runTest
  it "ratchets v1 to v2" $ withSmpServer t $ runTestCfg2 agentCfgRatchetV1 agentCfg 3 runTest
  it "ratchets v2 to v1" $ withSmpServer t $ runTestCfg2 agentCfg agentCfgRatchetV1 3 runTest

runTestCfg2 :: AgentConfig -> AgentConfig -> AgentMsgId -> (AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> IO ()
runTestCfg2 aliceCfg bobCfg baseMsgId runTest = do
  alice <- getSMPAgentClient aliceCfg initAgentServers
  bob <- getSMPAgentClient bobCfg {database = testDB2} initAgentServers
  runTest alice bob baseMsgId

runAgentClientTest :: AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientTest alice bob baseId = do
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice True SCMInvitation
    aliceId <- joinConnection bob True qInfo "bob's connInfo"
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 1
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 2
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 3
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 4
    suspendConnection alice bobId
    5 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  pure ()
  where
    msgId = subtract baseId

runAgentClientContactTest :: AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientContactTest alice bob baseId = do
  Right () <- runExceptT $ do
    (_, qInfo) <- createConnection alice True SCMContact
    aliceId <- joinConnection bob True qInfo "bob's connInfo"
    ("", _, REQ invId _ "bob's connInfo") <- get alice
    bobId <- acceptContact alice True invId "alice's connInfo"
    ("", _, CONF confId _ "alice's connInfo") <- get bob
    allowConnection bob aliceId confId "bob's connInfo"
    get alice ##> ("", bobId, INFO "bob's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 1
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 2
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 3
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 4
    suspendConnection alice bobId
    5 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  pure ()
  where
    msgId = subtract baseId

noMessages :: AgentClient -> String -> Expectation
noMessages c err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` get c >>= \case
        Just _ -> error err
        _ -> return ()

testAsyncInitiatingOffline :: IO ()
testAsyncInitiatingOffline = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice True SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob True cReq "bob's connInfo"
    alice' <- liftIO $ getSMPAgentClient agentCfg initAgentServers
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    get alice' ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob aliceId
  pure ()

testAsyncJoiningOfflineBeforeActivation :: IO ()
testAsyncJoiningOfflineBeforeActivation = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice True SCMInvitation
    aliceId <- joinConnection bob True qInfo "bob's connInfo"
    disconnectAgentClient bob
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient agentCfg {database = testDB2} initAgentServers
    subscribeConnection bob' aliceId
    get alice ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob' aliceId
  pure ()

testAsyncBothOffline :: IO ()
testAsyncBothOffline = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice True SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob True cReq "bob's connInfo"
    disconnectAgentClient bob
    alice' <- liftIO $ getSMPAgentClient agentCfg initAgentServers
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient agentCfg {database = testDB2} initAgentServers
    subscribeConnection bob' aliceId
    get alice' ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob' aliceId
  pure ()

testAsyncServerOffline :: ATransport -> IO ()
testAsyncServerOffline t = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  -- create connection and shutdown the server
  Right (bobId, cReq) <- withSmpServerStoreLogOn t testPort $ \_ ->
    runExceptT $ createConnection alice True SCMInvitation
  -- connection fails
  Left (BROKER NETWORK) <- runExceptT $ joinConnection bob True cReq "bob's connInfo"
  ("", "", DOWN srv conns) <- get alice
  srv `shouldBe` testSMPServer
  conns `shouldBe` [bobId]
  -- connection succeeds after server start
  Right () <- withSmpServerStoreLogOn t testPort $ \_ -> runExceptT $ do
    ("", "", UP srv1 conns1) <- get alice
    liftIO $ do
      srv1 `shouldBe` testSMPServer
      conns1 `shouldBe` [bobId]
    aliceId <- joinConnection bob True cReq "bob's connInfo"
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId
  pure ()

testAsyncHelloTimeout :: IO ()
testAsyncHelloTimeout = do
  -- this test would only work if any of the agent is v1, there is no HELLO timeout in v2
  alice <- getSMPAgentClient agentCfgV1 initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2, helloTimeout = 1} initAgentServers
  Right () <- runExceptT $ do
    (_, cReq) <- createConnection alice True SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob True cReq "bob's connInfo"
    get bob ##> ("", aliceId, ERR $ CONN NOT_ACCEPTED)
  pure ()

testDuplicateMessage :: ATransport -> IO ()
testDuplicateMessage t = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  (aliceId, bobId, bob1) <- withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    Right (aliceId, bobId) <- runExceptT $ makeConnection alice bob
    Right () <- runExceptT $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    disconnectAgentClient bob

    -- if the agent user did not send ACK, the message will be delivered again
    bob1 <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
    Right () <- runExceptT $ do
      subscribeConnection bob1 aliceId
      get bob1 =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob1 aliceId 4
      5 <- sendMessage alice bobId SMP.noMsgFlags "hello 2"
      get alice ##> ("", bobId, SENT 5)
      get bob1 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False

    pure (aliceId, bobId, bob1)

  get alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
  get bob1 =##> \case ("", "", DOWN _ [c]) -> c == aliceId; _ -> False
  -- commenting two lines below and uncommenting further two lines would also pass,
  -- it is the scenario tested above, when the message was not acknowledged by the user
  threadDelay 200000
  Left (BROKER TIMEOUT) <- runExceptT $ ackMessage bob1 aliceId 5

  disconnectAgentClient alice
  disconnectAgentClient bob1

  alice2 <- getSMPAgentClient agentCfg initAgentServers
  bob2 <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    Right () <- runExceptT $ do
      subscribeConnection bob2 aliceId
      subscribeConnection alice2 bobId
      -- get bob2 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False
      -- ackMessage bob2 aliceId 5
      -- message 2 is not delivered again, even though it was delivered to the agent
      6 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 3"
      get alice2 ##> ("", bobId, SENT 6)
      get bob2 =##> \case ("", c, Msg "hello 3") -> c == aliceId; _ -> False
    pure ()

makeConnection :: AgentClient -> AgentClient -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnection alice bob = do
  (bobId, qInfo) <- createConnection alice True SCMInvitation
  aliceId <- joinConnection bob True qInfo "bob's connInfo"
  ("", _, CONF confId _ "bob's connInfo") <- get alice
  allowConnection alice bobId confId "alice's connInfo"
  get alice ##> ("", bobId, CON)
  get bob ##> ("", aliceId, INFO "alice's connInfo")
  get bob ##> ("", aliceId, CON)
  pure (aliceId, bobId)

testInactiveClientDisconnected :: ATransport -> IO ()
testInactiveClientDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient agentCfg initAgentServers
    Right () <- runExceptT $ do
      (connId, _cReq) <- createConnection alice True SCMInvitation
      get alice ##> ("", "", DOWN testSMPServer [connId])
    pure ()

testActiveClientNotDisconnected :: ATransport -> IO ()
testActiveClientNotDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient agentCfg initAgentServers
    ts <- getSystemTime
    Right () <- runExceptT $ do
      (connId, _cReq) <- createConnection alice True SCMInvitation
      keepSubscribing alice connId ts
    pure ()
  where
    keepSubscribing :: AgentClient -> ConnId -> SystemTime -> ExceptT AgentErrorType IO ()
    keepSubscribing alice connId ts = do
      ts' <- liftIO getSystemTime
      if milliseconds ts' - milliseconds ts < 2200
        then do
          -- keep sending SUB for 2.2 seconds
          liftIO $ threadDelay 200000
          subscribeConnection alice connId
          keepSubscribing alice connId ts
        else do
          -- check that nothing is sent from agent
          Nothing <- 800000 `timeout` get alice
          liftIO $ threadDelay 1200000
          -- and after 2 sec of inactivity DOWN is sent
          get alice ##> ("", "", DOWN testSMPServer [connId])
    milliseconds ts = systemSeconds ts * 1000 + fromIntegral (systemNanoseconds ts `div` 1000000)

testSuspendingAgent :: IO ()
testSuspendingAgent = do
  a <- getSMPAgentClient agentCfg initAgentServers
  b <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    suspendAgent b 1000000
    get b ##> ("", "", SUSPENDED)
    5 <- sendMessage a bId SMP.noMsgFlags "hello 2"
    get a ##> ("", bId, SENT 5)
    Nothing <- 100000 `timeout` get b
    activateAgent b
    get b =##> \case ("", c, Msg "hello 2") -> c == aId; _ -> False
  pure ()

testSuspendingAgentCompleteSending :: ATransport -> IO ()
testSuspendingAgentCompleteSending t = do
  a <- getSMPAgentClient agentCfg initAgentServers
  b <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runExceptT $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    pure (aId, bId)

  Right () <- runExceptT $ do
    ("", "", DOWN {}) <- get a
    ("", "", DOWN {}) <- get b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    liftIO $ threadDelay 100000
    suspendAgent b 5000000

  Right () <- withSmpServerStoreLogOn t testPort $ \_ -> runExceptT $ do
    get b =##> \case ("", c, SENT 5) -> c == aId; ("", "", UP {}) -> True; _ -> False
    get b =##> \case ("", c, SENT 5) -> c == aId; ("", "", UP {}) -> True; _ -> False
    get b =##> \case ("", c, SENT 6) -> c == aId; ("", "", UP {}) -> True; _ -> False
    ("", "", SUSPENDED) <- get b

    r <- get a
    liftIO $ print r
    ("", "", UP {}) <- pure r
    get a =##> \case ("", c, Msg "hello too") -> c == bId; _ -> False
    ackMessage a bId 5
    get a =##> \case ("", c, Msg "how are you?") -> c == bId; _ -> False
    ackMessage a bId 6

  pure ()

testSuspendingAgentTimeout :: ATransport -> IO ()
testSuspendingAgentTimeout t = do
  a <- getSMPAgentClient agentCfg initAgentServers
  b <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right (aId, _) <- withSmpServer t . runExceptT $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    pure (aId, bId)

  Right () <- runExceptT $ do
    ("", "", DOWN {}) <- get a
    ("", "", DOWN {}) <- get b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    suspendAgent b 100000
    ("", "", SUSPENDED) <- get b
    pure ()

  pure ()

testBatchedSubscriptions :: ATransport -> IO ()
testBatchedSubscriptions t = do
  a <- getSMPAgentClient agentCfg initAgentServers2
  b <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers2
  Right conns <- runServers $ do
    conns <- forM [1 .. 200 :: Int] . const $ makeConnection a b
    forM_ conns $ \(aId, bId) -> exchangeGreetings a bId b aId
    forM_ (take 10 conns) $ \(aId, bId) -> do
      deleteConnection a bId
      deleteConnection b aId
    liftIO $ threadDelay 1000000
    pure conns
  ("", "", DOWN {}) <- get a
  ("", "", DOWN {}) <- get a
  ("", "", DOWN {}) <- get b
  ("", "", DOWN {}) <- get b
  Right () <- runServers $ do
    ("", "", UP {}) <- get a
    ("", "", UP {}) <- get a
    ("", "", UP {}) <- get b
    ("", "", UP {}) <- get b
    liftIO $ threadDelay 1000000
    subscribe a $ map snd conns
    subscribe b $ map fst conns
    forM_ (drop 10 conns) $ \(aId, bId) -> exchangeGreetingsMsgId 6 a bId b aId
  pure ()
  where
    subscribe :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    subscribe c cs = do
      r <- subscribeConnections c cs
      liftIO $ do
        let dc = S.fromList $ take 10 cs
        all (== Right ()) (M.withoutKeys r dc) `shouldBe` True
        all (== Left (CONN NOT_FOUND)) (M.restrictKeys r dc) `shouldBe` True
        M.keys r `shouldMatchList` cs
    runServers :: ExceptT AgentErrorType IO a -> IO (Either AgentErrorType a)
    runServers a = do
      withSmpServerStoreLogOn t testPort $ \t1 -> do
        res <- withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \t2 -> do
          res <- runExceptT a
          killThread t2
          pure res
        killThread t1
        pure res

testAsyncCommands :: IO ()
testAsyncCommands = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    bobId <- createConnectionAsync alice "1" True SCMInvitation
    ("1", bobId', INV (ACR _ qInfo)) <- get alice
    liftIO $ bobId' `shouldBe` bobId
    aliceId <- joinConnectionAsync bob "2" True qInfo "bob's connInfo"
    ("2", aliceId', OK) <- get bob
    liftIO $ aliceId' `shouldBe` aliceId
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnectionAsync alice "3" bobId confId "alice's connInfo"
    ("3", _, OK) <- get alice
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessageAsync bob "4" aliceId $ baseId + 1
    ("4", _, OK) <- get bob
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessageAsync bob "5" aliceId $ baseId + 2
    ("5", _, OK) <- get bob
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessageAsync alice "6" bobId $ baseId + 3
    ("6", _, OK) <- get alice
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessageAsync alice "7" bobId $ baseId + 4
    ("7", _, OK) <- get alice
    deleteConnectionAsync alice "8" bobId
    ("8", _, OK) <- get alice
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

testAsyncCommandsRestore :: ATransport -> IO ()
testAsyncCommandsRestore t = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  Right bobId <- runExceptT $ createConnectionAsync alice "1" True SCMInvitation
  liftIO $ noMessages alice "alice doesn't receive INV because server is down"
  disconnectAgentClient alice
  alice' <- liftIO $ getSMPAgentClient agentCfg initAgentServers
  withSmpServerStoreLogOn t testPort $ \_ -> do
    Right () <- runExceptT $ do
      subscribeConnection alice' bobId
      ("1", _, INV _) <- get alice'
      pure ()
    pure ()

testAcceptContactAsync :: IO ()
testAcceptContactAsync = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {database = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (_, qInfo) <- createConnection alice True SCMContact
    aliceId <- joinConnection bob True qInfo "bob's connInfo"
    ("", _, REQ invId _ "bob's connInfo") <- get alice
    bobId <- acceptContactAsync alice "1" True invId "alice's connInfo"
    ("1", bobId', OK) <- get alice
    liftIO $ bobId' `shouldBe` bobId
    ("", _, CONF confId _ "alice's connInfo") <- get bob
    allowConnection bob aliceId confId "bob's connInfo"
    get alice ##> ("", bobId, INFO "bob's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 1
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 2
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 3
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 4
    suspendConnection alice bobId
    5 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

testSwitchConnection :: InitialAgentServers -> IO ()
testSwitchConnection servers = do
  a <- getSMPAgentClient agentCfg servers
  b <- getSMPAgentClient agentCfg {database = testDB2} servers
  Right () <- runExceptT $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    switchConnectionAsync a "" bId
    phase a bId SPStarted
    phase b aId SPStarted
    phase a bId SPConfirmed
    phase b aId SPConfirmed
    phase a bId SPTested
    phase b aId SPTested
    phase b aId SPCompleted
    phase a bId SPCompleted
    exchangeGreetingsMsgId 12 a bId b aId
  pure ()

phase :: AgentClient -> ByteString -> SwitchPhase -> ExceptT AgentErrorType IO ()
phase c connId p =
  get c >>= \(_, connId', msg) -> do
    liftIO $ connId `shouldBe` connId'
    case msg of
      SWITCH p' _ -> liftIO $ p `shouldBe` p'
      ERR (AGENT A_DUPLICATE) -> phase c connId p
      r -> do
        liftIO . putStrLn $ "expected: " <> show p <> ", received: " <> show r
        SWITCH _ _ <- pure r
        pure ()

testSwitchAsync :: InitialAgentServers -> IO ()
testSwitchAsync servers = do
  Right (aId, bId) <- withA $ \a -> withB $ \b -> runExceptT $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let phaseA = withA . phase' bId
      phaseB = withB . phase' aId
  Right () <- withA $ \a -> runExceptT $ do
    subscribeConnection a bId
    switchConnectionAsync a "" bId
    phase a bId SPStarted
    liftIO $ threadDelay 250000
  phaseB SPStarted
  phaseA SPConfirmed
  phaseB SPConfirmed
  phaseA SPTested
  Right () <- withB $ \b -> runExceptT $ do
    subscribeConnection b aId
    phase b aId SPTested
    phase b aId SPCompleted
  phaseA SPCompleted
  Right () <- withA $ \a -> withB $ \b -> runExceptT $ do
    subscribeConnection a bId
    subscribeConnection b aId
    exchangeGreetingsMsgId 12 a bId b aId
  pure ()
  where
    withAgent :: AgentConfig -> (AgentClient -> IO a) -> IO a
    withAgent cfg' = bracket (getSMPAgentClient cfg' servers) disconnectAgentClient
    phase' connId p c = do
      Right () <- runExceptT $ do
        subscribeConnection c connId
        phase c connId p
        liftIO $ threadDelay 250000
      pure ()
    withA = withAgent agentCfg
    withB = withAgent agentCfg {database = testDB2, initialClientId = 1}

exchangeGreetings :: AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings = exchangeGreetingsMsgId 4

exchangeGreetingsMsgId :: Int64 -> AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetingsMsgId msgId alice bobId bob aliceId = do
  msgId1 <- sendMessage alice bobId SMP.noMsgFlags "hello"
  liftIO $ msgId1 `shouldBe` msgId
  get alice ##> ("", bobId, SENT msgId)
  get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
  ackMessage bob aliceId msgId
  msgId2 <- sendMessage bob aliceId SMP.noMsgFlags "hello too"
  let msgId' = msgId + 1
  liftIO $ msgId2 `shouldBe` msgId'
  get bob ##> ("", aliceId, SENT msgId')
  get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
  ackMessage alice bobId msgId'
