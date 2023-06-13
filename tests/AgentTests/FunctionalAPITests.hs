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
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.FunctionalAPITests
  ( functionalAPITests,
    testServerMatrix2,
    getSMPAgentClient',
    makeConnection,
    exchangeGreetingsMsgId,
    switchComplete,
    runRight,
    runRight_,
    get,
    get',
    rfGet,
    sfGet,
    nGet,
    (##>),
    (=##>),
    pattern Msg,
  )
where

import AgentTests.ConnectionRequestTests (connReqData, queueAddr, testE2ERatchetParams)
import Control.Concurrent (killThread, threadDelay)
import Control.Monad
import Control.Monad.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (isRight)
import Data.Int (Int64)
import qualified Data.Map as M
import Data.Maybe (isNothing)
import qualified Data.Set as S
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Type.Equality
import SMPAgentClient
import SMPClient (cfg, testPort, testPort2, testStoreLogFile2, withSmpServer, withSmpServerConfigOn, withSmpServerOn, withSmpServerStoreLogOn, withSmpServerStoreMsgLogOn)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..))
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers (..), createAgentStore)
import Simplex.Messaging.Agent.Protocol as Agent
import Simplex.Messaging.Agent.Store.SQLite (MigrationConfirmation (..))
import Simplex.Messaging.Client (NetworkConfig (..), ProtocolClientConfig (..), TransportSessionMode (TSMEntity, TSMUser), defaultClientConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (BasicAuth, ErrorType (..), MsgBody, ProtocolServer (..), supportedSMPClientVRange)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ATransport (..))
import Simplex.Messaging.Util (tryError)
import Simplex.Messaging.Version
import System.Directory (copyFile, renameFile)
import Test.Hspec
import UnliftIO
import XFTPClient (testXFTPServer)

type AEntityTransmission e = (ACorrId, ConnId, ACommand 'Agent e)

(##>) :: (HasCallStack, MonadIO m) => m (AEntityTransmission e) -> AEntityTransmission e -> m ()
a ##> t = a >>= \t' -> liftIO (t' `shouldBe` t)

(=##>) :: (Show a, HasCallStack, MonadIO m) => m a -> (a -> Bool) -> m ()
a =##> p = a >>= \t -> liftIO (t `shouldSatisfy` p)

get :: MonadIO m => AgentClient -> m (AEntityTransmission 'AEConn)
get = get' @'AEConn

rfGet :: MonadIO m => AgentClient -> m (AEntityTransmission 'AERcvFile)
rfGet = get' @'AERcvFile

sfGet :: MonadIO m => AgentClient -> m (AEntityTransmission 'AESndFile)
sfGet = get' @'AESndFile

nGet :: MonadIO m => AgentClient -> m (AEntityTransmission 'AENone)
nGet = get' @'AENone

get' :: forall e m. (MonadIO m, AEntityI e) => AgentClient -> m (AEntityTransmission e)
get' c = do
  (corrId, connId, APC e cmd) <- pGet c
  case testEquality e (sAEntity @e) of
    Just Refl -> pure (corrId, connId, cmd)
    _ -> error $ "unexpected command " <> show cmd

pGet :: forall m. MonadIO m => AgentClient -> m (ATransmission 'Agent)
pGet c = do
  t@(_, _, APC _ cmd) <- atomically (readTBQueue $ subQ c)
  case cmd of
    CONNECT {} -> pGet c
    DISCONNECT {} -> pGet c
    _ -> pure t

pattern Msg :: MsgBody -> ACommand 'Agent e
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk} _ msgBody

smpCfgV1 :: ProtocolClientConfig
smpCfgV1 = (smpCfg agentCfg) {smpServerVRange = vr11}

agentCfgV1 :: AgentConfig
agentCfgV1 = agentCfg {smpAgentVRange = vr11, smpClientVRange = vr11, e2eEncryptVRange = vr11, smpCfg = smpCfgV1}

agentCfgRatchetV1 :: AgentConfig
agentCfgRatchetV1 = agentCfg {e2eEncryptVRange = vr11}

vr11 :: VersionRange
vr11 = mkVersionRange 1 1

runRight_ :: (Eq e, Show e, HasCallStack) => ExceptT e IO () -> Expectation
runRight_ action = runExceptT action `shouldReturn` Right ()

runRight :: HasCallStack => ExceptT AgentErrorType IO a -> IO a
runRight action =
  runExceptT action >>= \case
    Right x -> pure x
    Left e -> error $ "Unexpected error: " <> show e

getInAnyOrder :: HasCallStack => AgentClient -> [AEntityTransmission 'AEConn -> Bool] -> Expectation
getInAnyOrder _ [] = pure ()
getInAnyOrder c rs = do
  r <- get c
  let rest = filter (not . expected r) rs
  if length rest < length rs
    then getInAnyOrder c rest
    else error $ "unexpected event: " <> show r
  where
    expected :: AEntityTransmission 'AEConn -> (AEntityTransmission 'AEConn -> Bool) -> Bool
    expected r rp = rp r

functionalAPITests :: ATransport -> Spec
functionalAPITests t = do
  describe "Establishing duplex connection" $ do
    testMatrix2 t runAgentClientTest
    it "should connect when server with multiple identities is stored" $
      withSmpServer t testServerMultipleIdentities
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
  describe "Message delivery" $ do
    it "should deliver messages to the user once, even if repeat delivery is made by the server (no ACK)" $
      testDuplicateMessage t
    it "should report error via msg integrity on skipped messages" $
      testSkippedMessages t
    it "should report decryption error on ratchet becoming out of sync" $
      testDecryptionError t
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
    it "should subscribe to multiple (200) subscriptions with batching" $
      testBatchedSubscriptions 200 10 t
    -- 200 subscriptions gets very slow with test coverage, use below test instead
    xit "should subscribe to multiple (6) subscriptions with batching" $
      testBatchedSubscriptions 6 3 t
  describe "Async agent commands" $ do
    it "should connect using async agent commands" $
      withSmpServer t testAsyncCommands
    it "should restore and complete async commands on restart" $
      testAsyncCommandsRestore t
    it "should accept connection using async command" $
      withSmpServer t testAcceptContactAsync
    it "should delete connections using async command when server connection fails" $
      testDeleteConnectionAsync t
  describe "Users" $ do
    it "should create and delete user with connections" $
      withSmpServer t testUsers
    it "should create and delete user without connections" $
      withSmpServer t testDeleteUserQuietly
    it "should create and delete user with connections when server connection fails" $
      testUsersNoServer t
    it "should connect two users and switch session mode" $
      withSmpServer t testTwoUsers
  describe "Connection switch" $ do
    describe "should switch delivery to the new queue" $
      testServerMatrix2 t testSwitchConnection
    describe "should switch to new queue asynchronously" $
      testServerMatrix2 t testSwitchAsync
    describe "should delete connection during switch" $
      testServerMatrix2 t testSwitchDelete
    describe "should stop switch in Started phase" $
      testServerMatrix2 t testStopSwitchStarted
    describe "should stop switch in Started phase, reinitiate immediately" $
      testServerMatrix2 t testStopSwitchStartedReinitiate
    describe "should prohibit to stop switch in Secured phase" $
      testServerMatrix2 t testCannotStopSwitchSecured
    describe "should switch two connections simultaneously" $
      testServerMatrix2 t testSwitch2Connections
    describe "should switch two connections simultaneously, stop one" $
      testServerMatrix2 t testSwitch2ConnectionsStop1
  describe "SMP basic auth" $ do
    describe "with server auth" $ do
      --                                       allow NEW | server auth, v | clnt1 auth, v  | clnt2 auth, v    |  2 - success, 1 - JOIN fail, 0 - NEW fail
      it "success                " $ testBasicAuth t True (Just "abcd", 5) (Just "abcd", 5) (Just "abcd", 5) `shouldReturn` 2
      it "disabled               " $ testBasicAuth t False (Just "abcd", 5) (Just "abcd", 5) (Just "abcd", 5) `shouldReturn` 0
      it "NEW fail, no auth      " $ testBasicAuth t True (Just "abcd", 5) (Nothing, 5) (Just "abcd", 5) `shouldReturn` 0
      it "NEW fail, bad auth     " $ testBasicAuth t True (Just "abcd", 5) (Just "wrong", 5) (Just "abcd", 5) `shouldReturn` 0
      it "NEW fail, version      " $ testBasicAuth t True (Just "abcd", 5) (Just "abcd", 4) (Just "abcd", 5) `shouldReturn` 0
      it "JOIN fail, no auth     " $ testBasicAuth t True (Just "abcd", 5) (Just "abcd", 5) (Nothing, 5) `shouldReturn` 1
      it "JOIN fail, bad auth    " $ testBasicAuth t True (Just "abcd", 5) (Just "abcd", 5) (Just "wrong", 5) `shouldReturn` 1
      it "JOIN fail, version     " $ testBasicAuth t True (Just "abcd", 5) (Just "abcd", 5) (Just "abcd", 4) `shouldReturn` 1
    describe "no server auth" $ do
      it "success     " $ testBasicAuth t True (Nothing, 5) (Nothing, 5) (Nothing, 5) `shouldReturn` 2
      it "srv disabled" $ testBasicAuth t False (Nothing, 5) (Nothing, 5) (Nothing, 5) `shouldReturn` 0
      it "version srv " $ testBasicAuth t True (Nothing, 4) (Nothing, 5) (Nothing, 5) `shouldReturn` 2
      it "version fst " $ testBasicAuth t True (Nothing, 5) (Nothing, 4) (Nothing, 5) `shouldReturn` 2
      it "version snd " $ testBasicAuth t True (Nothing, 5) (Nothing, 5) (Nothing, 4) `shouldReturn` 2
      it "version both" $ testBasicAuth t True (Nothing, 5) (Nothing, 4) (Nothing, 4) `shouldReturn` 2
      it "version all " $ testBasicAuth t True (Nothing, 4) (Nothing, 4) (Nothing, 4) `shouldReturn` 2
      it "auth fst    " $ testBasicAuth t True (Nothing, 5) (Just "abcd", 5) (Nothing, 5) `shouldReturn` 2
      it "auth fst 2  " $ testBasicAuth t True (Nothing, 4) (Just "abcd", 5) (Nothing, 5) `shouldReturn` 2
      it "auth snd    " $ testBasicAuth t True (Nothing, 5) (Nothing, 5) (Just "abcd", 5) `shouldReturn` 2
      it "auth both   " $ testBasicAuth t True (Nothing, 5) (Just "abcd", 5) (Just "abcd", 5) `shouldReturn` 2
      it "auth, disabled" $ testBasicAuth t False (Nothing, 5) (Just "abcd", 5) (Just "abcd", 5) `shouldReturn` 0
  describe "SMP server test via agent API" $ do
    it "should pass without basic auth" $ testSMPServerConnectionTest t Nothing (noAuthSrv testSMPServer2) `shouldReturn` Nothing
    let srv1 = testSMPServer2 {keyHash = "1234"}
    it "should fail with incorrect fingerprint" $ do
      testSMPServerConnectionTest t Nothing (noAuthSrv srv1) `shouldReturn` Just (ProtocolTestFailure TSConnect $ BROKER (B.unpack $ strEncode srv1) NETWORK)
    describe "server with password" $ do
      let auth = Just "abcd"
          srv = ProtoServerWithAuth testSMPServer2
          authErr = Just (ProtocolTestFailure TSCreateQueue $ SMP AUTH)
      it "should pass with correct password" $ testSMPServerConnectionTest t auth (srv auth) `shouldReturn` Nothing
      it "should fail without password" $ testSMPServerConnectionTest t auth (srv Nothing) `shouldReturn` authErr
      it "should fail with incorrect password" $ testSMPServerConnectionTest t auth (srv $ Just "wrong") `shouldReturn` authErr
  describe "getRatchetAdHash" $
    it "should return the same data for both peers" $
      withSmpServer t testRatchetAdHash

testBasicAuth :: ATransport -> Bool -> (Maybe BasicAuth, Version) -> (Maybe BasicAuth, Version) -> (Maybe BasicAuth, Version) -> IO Int
testBasicAuth t allowNewQueues srv@(srvAuth, srvVersion) clnt1 clnt2 = do
  let testCfg = cfg {allowNewQueues, newQueueBasicAuth = srvAuth, smpServerVRange = mkVersionRange 4 srvVersion}
      canCreate1 = canCreateQueue allowNewQueues srv clnt1
      canCreate2 = canCreateQueue allowNewQueues srv clnt2
      expected
        | canCreate1 && canCreate2 = 2
        | canCreate1 = 1
        | otherwise = 0
  created <- withSmpServerConfigOn t testCfg testPort $ \_ -> testCreateQueueAuth clnt1 clnt2
  created `shouldBe` expected
  pure created

canCreateQueue :: Bool -> (Maybe BasicAuth, Version) -> (Maybe BasicAuth, Version) -> Bool
canCreateQueue allowNew (srvAuth, srvVersion) (clntAuth, clntVersion) =
  allowNew && (isNothing srvAuth || (srvVersion == 5 && clntVersion == 5 && srvAuth == clntAuth))

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

testServerMatrix2 :: ATransport -> (InitialAgentServers -> IO ()) -> Spec
testServerMatrix2 t runTest = do
  it "1 server" $ withSmpServer t $ runTest initAgentServers
  it "2 servers" $ withSmpServer t . withSmpServerOn t testPort2 $ runTest initAgentServers2

runTestCfg2 :: AgentConfig -> AgentConfig -> AgentMsgId -> (AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> IO ()
runTestCfg2 aliceCfg bobCfg baseMsgId runTest = do
  alice <- getSMPAgentClient' aliceCfg initAgentServers testDB
  bob <- getSMPAgentClient' bobCfg initAgentServers testDB2
  runTest alice bob baseMsgId

runAgentClientTest :: HasCallStack => AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientTest alice bob baseId = do
  runRight_ $ do
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo"
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
  where
    msgId = subtract baseId

runAgentClientContactTest :: HasCallStack => AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientContactTest alice bob baseId = do
  runRight_ $ do
    (_, qInfo) <- createConnection alice 1 True SCMContact Nothing
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo"
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
  where
    msgId = subtract baseId

noMessages :: HasCallStack => AgentClient -> String -> Expectation
noMessages c err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` get c >>= \case
        Just msg -> error $ err <> ": " <> show msg
        _ -> return ()

testAsyncInitiatingOffline :: HasCallStack => IO ()
testAsyncInitiatingOffline = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing
    disconnectAgentClient alice
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo"
    alice' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    get alice' ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob aliceId

testAsyncJoiningOfflineBeforeActivation :: HasCallStack => IO ()
testAsyncJoiningOfflineBeforeActivation = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo"
    disconnectAgentClient bob
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    get alice ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob' aliceId

testAsyncBothOffline :: HasCallStack => IO ()
testAsyncBothOffline = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing
    disconnectAgentClient alice
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo"
    disconnectAgentClient bob
    alice' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    get alice' ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob' aliceId

testAsyncServerOffline :: HasCallStack => ATransport -> IO ()
testAsyncServerOffline t = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  -- create connection and shutdown the server
  (bobId, cReq) <- withSmpServerStoreLogOn t testPort $ \_ ->
    runRight $ createConnection alice 1 True SCMInvitation Nothing
  -- connection fails
  Left (BROKER _ NETWORK) <- runExceptT $ joinConnection bob 1 True cReq "bob's connInfo"
  ("", "", DOWN srv conns) <- nGet alice
  srv `shouldBe` testSMPServer
  conns `shouldBe` [bobId]
  -- connection succeeds after server start
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    ("", "", UP srv1 conns1) <- nGet alice
    liftIO $ do
      srv1 `shouldBe` testSMPServer
      conns1 `shouldBe` [bobId]
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo"
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId

testAsyncHelloTimeout :: HasCallStack => IO ()
testAsyncHelloTimeout = do
  -- this test would only work if any of the agent is v1, there is no HELLO timeout in v2
  alice <- getSMPAgentClient' agentCfgV1 initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg {helloTimeout = 1} initAgentServers testDB2
  runRight_ $ do
    (_, cReq) <- createConnection alice 1 True SCMInvitation Nothing
    disconnectAgentClient alice
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo"
    get bob ##> ("", aliceId, ERR $ CONN NOT_ACCEPTED)

testDuplicateMessage :: HasCallStack => ATransport -> IO ()
testDuplicateMessage t = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aliceId, bobId, bob1) <- withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ makeConnection alice bob
    runRight_ $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    disconnectAgentClient bob

    -- if the agent user did not send ACK, the message will be delivered again
    bob1 <- getSMPAgentClient' agentCfg initAgentServers testDB2
    runRight_ $ do
      subscribeConnection bob1 aliceId
      get bob1 =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob1 aliceId 4
      5 <- sendMessage alice bobId SMP.noMsgFlags "hello 2"
      get alice ##> ("", bobId, SENT 5)
      get bob1 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False

    pure (aliceId, bobId, bob1)

  nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
  nGet bob1 =##> \case ("", "", DOWN _ [c]) -> c == aliceId; _ -> False
  -- commenting two lines below and uncommenting further two lines would also runRight_,
  -- it is the scenario tested above, when the message was not acknowledged by the user
  threadDelay 200000
  Left (BROKER _ TIMEOUT) <- runExceptT $ ackMessage bob1 aliceId 5

  disconnectAgentClient alice
  disconnectAgentClient bob1

  alice2 <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob2 <- getSMPAgentClient' agentCfg initAgentServers testDB2

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection bob2 aliceId
      subscribeConnection alice2 bobId
      -- get bob2 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False
      -- ackMessage bob2 aliceId 5
      -- message 2 is not delivered again, even though it was delivered to the agent
      6 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 3"
      get alice2 ##> ("", bobId, SENT 6)
      get bob2 =##> \case ("", c, Msg "hello 3") -> c == aliceId; _ -> False

testSkippedMessages :: HasCallStack => ATransport -> IO ()
testSkippedMessages t = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ makeConnection alice bob
    runRight_ $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob aliceId 4

    disconnectAgentClient bob

    runRight_ $ do
      5 <- sendMessage alice bobId SMP.noMsgFlags "hello 2"
      get alice ##> ("", bobId, SENT 5)
      6 <- sendMessage alice bobId SMP.noMsgFlags "hello 3"
      get alice ##> ("", bobId, SENT 6)
      7 <- sendMessage alice bobId SMP.noMsgFlags "hello 4"
      get alice ##> ("", bobId, SENT 7)

    pure (aliceId, bobId)

  nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
  threadDelay 200000

  disconnectAgentClient alice

  alice2 <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob2 <- getSMPAgentClient' agentCfg initAgentServers testDB2

  withSmpServerStoreLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection bob2 aliceId
      subscribeConnection alice2 bobId

      8 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 5"
      get alice2 ##> ("", bobId, SENT 8)
      get bob2 =##> \case ("", c, MSG MsgMeta {integrity = MsgError {errorInfo = MsgSkipped {fromMsgId = 4, toMsgId = 6}}} _ "hello 5") -> c == aliceId; _ -> False
      ackMessage bob2 aliceId 5

      9 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 6"
      get alice2 ##> ("", bobId, SENT 9)
      get bob2 =##> \case ("", c, Msg "hello 6") -> c == aliceId; _ -> False
      ackMessage bob2 aliceId 6

testDecryptionError :: HasCallStack => ATransport -> IO ()
testDecryptionError t = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ makeConnection alice bob
    runRight_ $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob aliceId 4

      5 <- sendMessage bob aliceId SMP.noMsgFlags "hello 2"
      get bob ##> ("", aliceId, SENT 5)
      get alice =##> \case ("", c, Msg "hello 2") -> c == bobId; _ -> False
      ackMessage alice bobId 5

      liftIO $ copyFile testDB2 (testDB2 <> ".bak")

      6 <- sendMessage alice bobId SMP.noMsgFlags "hello 3"
      get alice ##> ("", bobId, SENT 6)
      get bob =##> \case ("", c, Msg "hello 3") -> c == aliceId; _ -> False
      ackMessage bob aliceId 6

      7 <- sendMessage bob aliceId SMP.noMsgFlags "hello 4"
      get bob ##> ("", aliceId, SENT 7)
      get alice =##> \case ("", c, Msg "hello 4") -> c == bobId; _ -> False
      ackMessage alice bobId 7

    disconnectAgentClient bob

    -- importing database backup after progressing ratchet de-synchronizes ratchet,
    -- this will be fixed by ratchet re-negotiation
    liftIO $ renameFile (testDB2 <> ".bak") testDB2

    bob2 <- getSMPAgentClient' agentCfg initAgentServers testDB2

    runRight_ $ do
      subscribeConnection bob2 aliceId

      8 <- sendMessage alice bobId SMP.noMsgFlags "hello 5"
      get alice ##> ("", bobId, SENT 8)
      get bob2 =##> \case ("", c, ERR AGENT {agentErr = A_CRYPTO {cryptoErr = RATCHET_HEADER}}) -> c == aliceId; _ -> False

      6 <- sendMessage bob2 aliceId SMP.noMsgFlags "hello 6"
      get bob2 ##> ("", aliceId, SENT 6)
      get alice =##> \case ("", c, ERR AGENT {agentErr = A_CRYPTO {cryptoErr = RATCHET_HEADER}}) -> c == bobId; _ -> False

makeConnection :: AgentClient -> AgentClient -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnection alice bob = makeConnectionForUsers alice 1 bob 1

makeConnectionForUsers :: AgentClient -> UserId -> AgentClient -> UserId -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnectionForUsers alice aliceUserId bob bobUserId = do
  (bobId, qInfo) <- createConnection alice aliceUserId True SCMInvitation Nothing
  aliceId <- joinConnection bob bobUserId True qInfo "bob's connInfo"
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
    alice <- getSMPAgentClient' agentCfg initAgentServers testDB
    runRight_ $ do
      (connId, _cReq) <- createConnection alice 1 True SCMInvitation Nothing
      nGet alice ##> ("", "", DOWN testSMPServer [connId])

testActiveClientNotDisconnected :: ATransport -> IO ()
testActiveClientNotDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient' agentCfg initAgentServers testDB
    ts <- getSystemTime
    runRight_ $ do
      (connId, _cReq) <- createConnection alice 1 True SCMInvitation Nothing
      keepSubscribing alice connId ts
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
          nGet alice ##> ("", "", DOWN testSMPServer [connId])
    milliseconds ts = systemSeconds ts * 1000 + fromIntegral (systemNanoseconds ts `div` 1000000)

testSuspendingAgent :: IO ()
testSuspendingAgent = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    suspendAgent b 1000000
    get' b ##> ("", "", SUSPENDED)
    5 <- sendMessage a bId SMP.noMsgFlags "hello 2"
    get a ##> ("", bId, SENT 5)
    Nothing <- 100000 `timeout` get b
    foregroundAgent b
    get b =##> \case ("", c, Msg "hello 2") -> c == aId; _ -> False

testSuspendingAgentCompleteSending :: ATransport -> IO ()
testSuspendingAgentCompleteSending t = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    pure (aId, bId)

  runRight_ $ do
    ("", "", DOWN {}) <- nGet a
    ("", "", DOWN {}) <- nGet b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    liftIO $ threadDelay 100000
    suspendAgent b 5000000

  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ @AgentErrorType $ do
    pGet b =##> \case ("", c, APC _ (SENT 5)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet b =##> \case ("", c, APC _ (SENT 5)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet b =##> \case ("", c, APC _ (SENT 6)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    ("", "", SUSPENDED) <- nGet b

    pGet a =##> \case ("", c, APC _ (Msg "hello too")) -> c == bId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet a =##> \case ("", c, APC _ (Msg "hello too")) -> c == bId; ("", "", APC _ UP {}) -> True; _ -> False
    ackMessage a bId 5
    get a =##> \case ("", c, Msg "how are you?") -> c == bId; _ -> False
    ackMessage a bId 6

testSuspendingAgentTimeout :: ATransport -> IO ()
testSuspendingAgentTimeout t = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aId, _) <- withSmpServer t . runRight $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4
    pure (aId, bId)

  runRight_ $ do
    ("", "", DOWN {}) <- nGet a
    ("", "", DOWN {}) <- nGet b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    suspendAgent b 100000
    ("", "", SUSPENDED) <- nGet b
    pure ()

testBatchedSubscriptions :: Int -> Int -> ATransport -> IO ()
testBatchedSubscriptions nCreate nDel t = do
  a <- getSMPAgentClient' agentCfg initAgentServers2 testDB
  b <- getSMPAgentClient' agentCfg initAgentServers2 testDB2
  conns <- runServers $ do
    conns <- forM [1 .. nCreate :: Int] . const $ makeConnection a b
    forM_ conns $ \(aId, bId) -> exchangeGreetings a bId b aId
    let (aIds', bIds') = unzip $ take nDel conns
    delete a bIds'
    delete b aIds'
    liftIO $ threadDelay 1000000
    pure conns
  ("", "", DOWN {}) <- nGet a
  ("", "", DOWN {}) <- nGet a
  ("", "", DOWN {}) <- nGet b
  ("", "", DOWN {}) <- nGet b
  runServers $ do
    ("", "", UP {}) <- nGet a
    ("", "", UP {}) <- nGet a
    ("", "", UP {}) <- nGet b
    ("", "", UP {}) <- nGet b
    liftIO $ threadDelay 1000000
    let (aIds, bIds) = unzip conns
        conns' = drop nDel conns
        (aIds', bIds') = unzip conns'
    subscribe a bIds
    subscribe b aIds
    forM_ conns' $ \(aId, bId) -> exchangeGreetingsMsgId 6 a bId b aId
    void $ resubscribeConnections a bIds
    void $ resubscribeConnections b aIds
    forM_ conns' $ \(aId, bId) -> exchangeGreetingsMsgId 8 a bId b aId
    delete a bIds'
    delete b aIds'
    deleteFail a bIds'
    deleteFail b aIds'
  where
    subscribe :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    subscribe c cs = do
      r <- subscribeConnections c cs
      liftIO $ do
        let dc = S.fromList $ take nDel cs
        all isRight (M.withoutKeys r dc) `shouldBe` True
        all (== Left (CONN NOT_FOUND)) (M.restrictKeys r dc) `shouldBe` True
        M.keys r `shouldMatchList` cs
    delete :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    delete c cs = do
      r <- deleteConnections c cs
      liftIO $ do
        all isRight r `shouldBe` True
        M.keys r `shouldMatchList` cs
    deleteFail :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    deleteFail c cs = do
      r <- deleteConnections c cs
      liftIO $ do
        all (== Left (CONN NOT_FOUND)) r `shouldBe` True
        M.keys r `shouldMatchList` cs
    runServers :: ExceptT AgentErrorType IO a -> IO a
    runServers a = do
      withSmpServerStoreLogOn t testPort $ \t1 -> do
        res <- withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \t2 ->
          runRight a `finally` killThread t2
        killThread t1
        pure res

testAsyncCommands :: IO ()
testAsyncCommands = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    bobId <- createConnectionAsync alice 1 "1" True SCMInvitation
    ("1", bobId', INV (ACR _ qInfo)) <- get alice
    liftIO $ bobId' `shouldBe` bobId
    aliceId <- joinConnectionAsync bob 1 "2" True qInfo "bob's connInfo"
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
    deleteConnectionAsync alice bobId
    get alice =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bobId; _ -> False
    get alice =##> \case ("", c, DEL_CONN) -> c == bobId; _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  where
    baseId = 3
    msgId = subtract baseId

testAsyncCommandsRestore :: ATransport -> IO ()
testAsyncCommandsRestore t = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bobId <- runRight $ createConnectionAsync alice 1 "1" True SCMInvitation
  liftIO $ noMessages alice "alice doesn't receive INV because server is down"
  disconnectAgentClient alice
  alice' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB
  withSmpServerStoreLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection alice' bobId
      ("1", _, INV _) <- get alice'
      pure ()

testAcceptContactAsync :: IO ()
testAcceptContactAsync = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (_, qInfo) <- createConnection alice 1 True SCMContact Nothing
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo"
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
  where
    baseId = 3
    msgId = subtract baseId

testDeleteConnectionAsync :: ATransport -> IO ()
testDeleteConnectionAsync t = do
  a <- getSMPAgentClient' agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  connIds <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (bId1, _inv) <- createConnection a 1 True SCMInvitation Nothing
    (bId2, _inv) <- createConnection a 1 True SCMInvitation Nothing
    (bId3, _inv) <- createConnection a 1 True SCMInvitation Nothing
    pure ([bId1, bId2, bId3] :: [ConnId])
  runRight_ $ do
    deleteConnectionsAsync a connIds
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"

testUsers :: IO ()
testUsers = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    deleteUser a auId True
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId'; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId'; _ -> False
    nGet a =##> \case ("", "", DEL_USER u) -> u == auId; _ -> False
    exchangeGreetingsMsgId 6 a bId b aId
    liftIO $ noMessages a "nothing else should be delivered to alice"

testDeleteUserQuietly :: IO ()
testDeleteUserQuietly = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    deleteUser a auId False
    exchangeGreetingsMsgId 6 a bId b aId
    liftIO $ noMessages a "nothing else should be delivered to alice"

testUsersNoServer :: HasCallStack => ATransport -> IO ()
testUsersNoServer t = do
  a <- getSMPAgentClient' agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aId, bId, auId, _aId', bId') <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    pure (aId, bId, auId, aId', bId')
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId || c == bId'; _ -> False
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId || c == bId'; _ -> False
  nGet b =##> \case ("", "", DOWN _ cs) -> length cs == 2; _ -> False
  runRight_ $ do
    deleteUser a auId True
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c == bId' && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId'; _ -> False
    nGet a =##> \case ("", "", DEL_USER u) -> u == auId; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    nGet a =##> \case ("", "", UP _ [c]) -> c == bId; _ -> False
    nGet b =##> \case ("", "", UP _ cs) -> length cs == 2; _ -> False
    exchangeGreetingsMsgId 6 a bId b aId

testSwitchConnection :: InitialAgentServers -> IO ()
testSwitchConnection servers = do
  a <- getSMPAgentClient' agentCfg servers testDB
  b <- getSMPAgentClient' agentCfg {initialClientId = 1} servers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    testFullSwitch a bId b aId 10
    testFullSwitch a bId b aId 16

testFullSwitch :: AgentClient -> ByteString -> AgentClient -> ByteString -> Int64 -> ExceptT AgentErrorType IO ()
testFullSwitch a bId b aId msgId = do
  switchConnectionAsync a "" bId
  switchComplete a bId b aId
  exchangeGreetingsMsgId msgId a bId b aId

switchComplete :: AgentClient -> ByteString -> AgentClient -> ByteString -> ExceptT AgentErrorType IO ()
switchComplete a bId b aId = do
  phase a bId QDRcv SPStarted
  phase b aId QDSnd SPStarted
  phase a bId QDRcv SPConfirmed
  phase a bId QDRcv SPSecured
  phase b aId QDSnd SPConfirmed
  phase b aId QDSnd SPCompleted
  phase a bId QDRcv SPCompleted

phase :: AgentClient -> ByteString -> QueueDirection -> SwitchPhase -> ExceptT AgentErrorType IO ()
phase c connId d p =
  get c >>= \(_, connId', msg) -> do
    liftIO $ connId `shouldBe` connId'
    case msg of
      SWITCH d' p' _ -> liftIO $ do
        d `shouldBe` d'
        p `shouldBe` p'
      ERR (AGENT A_DUPLICATE) -> phase c connId d p
      r -> do
        liftIO . putStrLn $ "expected: " <> show p <> ", received: " <> show r
        SWITCH {} <- pure r
        pure ()

testSwitchAsync :: HasCallStack => InitialAgentServers -> IO ()
testSwitchAsync servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
  withB' $ \b -> phase b aId QDSnd SPStarted
  withA' $ \a -> do
    phase a bId QDRcv SPConfirmed
    phase a bId QDRcv SPSecured
  withB' $ \b -> do
    phase b aId QDSnd SPConfirmed
    phase b aId QDSnd SPCompleted
  withA' $ \a -> phase a bId QDRcv SPCompleted
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId
    exchangeGreetingsMsgId 10 a bId b aId
    testFullSwitch a bId b aId 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2

withAgent :: AgentConfig -> InitialAgentServers -> FilePath -> (AgentClient -> IO a) -> IO a
withAgent cfg' servers dbPath = bracket (getSMPAgentClient' cfg' servers dbPath) disconnectAgentClient

sessionSubscribe :: (forall a. (AgentClient -> IO a) -> IO a) -> [ConnId] -> (AgentClient -> ExceptT AgentErrorType IO ()) -> IO ()
sessionSubscribe withC connIds a =
  withC $ \c -> runRight_ $ do
    void $ subscribeConnections c connIds
    r <- a c
    liftIO $ threadDelay 500000
    liftIO $ noMessages c "nothing else should be delivered"
    pure r

testSwitchDelete :: InitialAgentServers -> IO ()
testSwitchDelete servers = do
  a <- getSMPAgentClient' agentCfg servers testDB
  b <- getSMPAgentClient' agentCfg {initialClientId = 1} servers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    disconnectAgentClient b
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
    deleteConnectionAsync a bId
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId; _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"

testStopSwitchStarted :: HasCallStack => InitialAgentServers -> IO ()
testStopSwitchStarted servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
    -- repeat switch is prohibited
    Left Agent.CMD {cmdErr = PROHIBITED} <- runExceptT $ switchConnectionAsync a "" bId
    -- stop current switch
    ConnectionStats {rcvQueuesInfo = [RcvQueueInfo {rcvSwitchStatus}]} <- stopConnectionSwitch a bId
    liftIO $ rcvSwitchStatus `shouldBe` Nothing
  withB' $ \b -> do
    phase b aId QDSnd SPStarted
  withA' $ \a -> do
    get a ##> ("", bId, ERR (AGENT {agentErr = A_QUEUE {queueErr = "QKEY: queue address not found in connection"}}))
    -- repeat switch
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    phase b aId QDSnd SPStarted

    phase a bId QDRcv SPConfirmed
    phase a bId QDRcv SPSecured

    phase b aId QDSnd SPConfirmed
    phase b aId QDSnd SPCompleted

    phase a bId QDRcv SPCompleted

    exchangeGreetingsMsgId 12 a bId b aId

    testFullSwitch a bId b aId 18
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2

testStopSwitchStartedReinitiate :: HasCallStack => InitialAgentServers -> IO ()
testStopSwitchStartedReinitiate servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
    -- stop current switch
    ConnectionStats {rcvQueuesInfo = [RcvQueueInfo {rcvSwitchStatus}]} <- stopConnectionSwitch a bId
    liftIO $ rcvSwitchStatus `shouldBe` Nothing
    -- repeat switch
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
  withB' $ \b -> do
    phase b aId QDSnd SPStarted
    phase b aId QDSnd SPStarted
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    liftIO . getInAnyOrder a $
      [ errQueueNotFound bId,
        switchPhaseConfirmed bId
      ]

    phase a bId QDRcv SPSecured

    phase b aId QDSnd SPConfirmed
    phase b aId QDSnd SPCompleted

    phase a bId QDRcv SPCompleted

    exchangeGreetingsMsgId 12 a bId b aId

    testFullSwitch a bId b aId 18
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2
    errQueueNotFound :: ConnId -> AEntityTransmission 'AEConn -> Bool
    errQueueNotFound cId = \case
      (_, cId', ERR AGENT {agentErr = A_QUEUE {queueErr = "QKEY: queue address not found in connection"}}) -> cId' == cId
      _ -> False
    switchPhaseConfirmed :: ConnId -> AEntityTransmission 'AEConn -> Bool
    switchPhaseConfirmed cId = \case
      (_, cId', SWITCH QDRcv SPConfirmed _) -> cId' == cId
      _ -> False

testCannotStopSwitchSecured :: HasCallStack => InitialAgentServers -> IO ()
testCannotStopSwitchSecured servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    switchConnectionAsync a "" bId
    phase a bId QDRcv SPStarted
  withB' $ \b -> do
    phase b aId QDSnd SPStarted
  withA' $ \a -> do
    phase a bId QDRcv SPConfirmed
    phase a bId QDRcv SPSecured
    Left Agent.CMD {cmdErr = PROHIBITED} <- runExceptT $ stopConnectionSwitch a bId
    pure ()
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    phase b aId QDSnd SPConfirmed
    phase b aId QDSnd SPCompleted

    phase a bId QDRcv SPCompleted

    exchangeGreetingsMsgId 10 a bId b aId

    testFullSwitch a bId b aId 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2

testSwitch2Connections :: HasCallStack => InitialAgentServers -> IO ()
testSwitch2Connections servers = do
  (aId1, bId1, aId2, bId2) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId1, bId1) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId1 b aId1
    (aId2, bId2) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId2 b aId2
    pure (aId1, bId1, aId2, bId2)
  withA $ \a -> runRight_ $ do
    void $ subscribeConnections a [bId1, bId2]
    switchConnectionAsync a "" bId1
    phase a bId1 QDRcv SPStarted
    switchConnectionAsync a "" bId2
    phase a bId2 QDRcv SPStarted
  withA $ \a -> withB $ \b -> runRight_ $ do
    void $ subscribeConnections a [bId1, bId2]
    void $ subscribeConnections b [aId1, aId2]

    liftIO . getInAnyOrder b $
      [ switchPhase aId1 QDSnd SPStarted,
        switchPhase aId2 QDSnd SPStarted
      ]

    liftIO . getInAnyOrder a $
      [ switchPhase bId1 QDRcv SPConfirmed,
        switchPhase bId1 QDRcv SPSecured,
        switchPhase bId2 QDRcv SPConfirmed,
        switchPhase bId2 QDRcv SPSecured
      ]

    liftIO . getInAnyOrder b $
      [ switchPhase aId1 QDSnd SPConfirmed,
        switchPhase aId1 QDSnd SPCompleted,
        switchPhase aId2 QDSnd SPConfirmed,
        switchPhase aId2 QDSnd SPCompleted
      ]

    liftIO . getInAnyOrder a $
      [ switchPhase bId1 QDRcv SPCompleted,
        switchPhase bId2 QDRcv SPCompleted
      ]

    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 10 a bId2 b aId2

    testFullSwitch a bId1 b aId1 16
    testFullSwitch a bId2 b aId2 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2
    switchPhase :: ConnId -> QueueDirection -> SwitchPhase -> AEntityTransmission 'AEConn -> Bool
    switchPhase cId qd sphase = \case
      (_, cId', SWITCH qd' sphase' _) -> cId' == cId && qd' == qd && sphase' == sphase
      _ -> False

testSwitch2ConnectionsStop1 :: HasCallStack => InitialAgentServers -> IO ()
testSwitch2ConnectionsStop1 servers = do
  (aId1, bId1, aId2, bId2) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId1, bId1) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId1 b aId1
    (aId2, bId2) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId2 b aId2
    pure (aId1, bId1, aId2, bId2)
  let withA' = sessionSubscribe withA [bId1, bId2]
      withB' = sessionSubscribe withB [aId1, aId2]
  withA' $ \a -> do
    switchConnectionAsync a "" bId1
    phase a bId1 QDRcv SPStarted
    switchConnectionAsync a "" bId2
    phase a bId2 QDRcv SPStarted
    -- stop switch of second connection
    ConnectionStats {rcvQueuesInfo = [RcvQueueInfo {rcvSwitchStatus}]} <- stopConnectionSwitch a bId2
    liftIO $ rcvSwitchStatus `shouldBe` Nothing
  withB' $ \b -> do
    liftIO . getInAnyOrder b $
      [ switchPhase aId1 QDSnd SPStarted,
        switchPhase aId2 QDSnd SPStarted
      ]
  withA' $ \a -> do
    liftIO . getInAnyOrder a $
      [ switchPhase bId1 QDRcv SPConfirmed,
        switchPhase bId1 QDRcv SPSecured,
        errQueueNotFound bId2
      ]
  withA $ \a -> withB $ \b -> runRight_ $ do
    void $ subscribeConnections a [bId1, bId2]
    void $ subscribeConnections b [aId1, aId2]

    phase b aId1 QDSnd SPConfirmed
    phase b aId1 QDSnd SPCompleted

    phase a bId1 QDRcv SPCompleted

    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 8 a bId2 b aId2

    testFullSwitch a bId1 b aId1 16
    testFullSwitch a bId2 b aId2 14
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent agentCfg {initialClientId = 1} servers testDB2
    switchPhase :: ConnId -> QueueDirection -> SwitchPhase -> AEntityTransmission 'AEConn -> Bool
    switchPhase cId qd sphase = \case
      (_, cId', SWITCH qd' sphase' _) -> cId' == cId && qd' == qd && sphase' == sphase
      _ -> False
    errQueueNotFound :: ConnId -> AEntityTransmission 'AEConn -> Bool
    errQueueNotFound cId = \case
      (_, cId', ERR AGENT {agentErr = A_QUEUE {queueErr = "QKEY: queue address not found in connection"}}) -> cId' == cId
      _ -> False

testCreateQueueAuth :: (Maybe BasicAuth, Version) -> (Maybe BasicAuth, Version) -> IO Int
testCreateQueueAuth clnt1 clnt2 = do
  a <- getClient clnt1
  b <- getClient clnt2
  runRight $ do
    tryError (createConnection a 1 True SCMInvitation Nothing) >>= \case
      Left (SMP AUTH) -> pure 0
      Left e -> throwError e
      Right (bId, qInfo) ->
        tryError (joinConnection b 1 True qInfo "bob's connInfo") >>= \case
          Left (SMP AUTH) -> pure 1
          Left e -> throwError e
          Right aId -> do
            ("", _, CONF confId _ "bob's connInfo") <- get a
            allowConnection a bId confId "alice's connInfo"
            get a ##> ("", bId, CON)
            get b ##> ("", aId, INFO "alice's connInfo")
            get b ##> ("", aId, CON)
            exchangeGreetings a bId b aId
            pure 2
  where
    getClient (clntAuth, clntVersion) =
      let servers = initAgentServers {smp = userServers [ProtoServerWithAuth testSMPServer clntAuth]}
          smpCfg = (defaultClientConfig :: ProtocolClientConfig) {smpServerVRange = mkVersionRange 4 clntVersion}
       in getSMPAgentClient' agentCfg {smpCfg} servers testDB

testSMPServerConnectionTest :: ATransport -> Maybe BasicAuth -> SMPServerWithAuth -> IO (Maybe ProtocolTestFailure)
testSMPServerConnectionTest t newQueueBasicAuth srv =
  withSmpServerConfigOn t cfg {newQueueBasicAuth} testPort2 $ \_ -> do
    a <- getSMPAgentClient' agentCfg initAgentServers testDB -- initially passed server is not running
    runRight $ testProtocolServer a 1 srv

testRatchetAdHash :: IO ()
testRatchetAdHash = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    ad1 <- getConnectionRatchetAdHash a bId
    ad2 <- getConnectionRatchetAdHash b aId
    liftIO $ ad1 `shouldBe` ad2

testTwoUsers :: HasCallStack => IO ()
testTwoUsers = do
  let nc = netCfg initAgentServers
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  b <- getSMPAgentClient' agentCfg initAgentServers testDB2
  sessionMode nc `shouldBe` TSMUser
  runRight_ $ do
    (aId1, bId1) <- makeConnectionForUsers a 1 b 1
    exchangeGreetings a bId1 b aId1
    (aId1', bId1') <- makeConnectionForUsers a 1 b 1
    exchangeGreetings a bId1' b aId1'
    a `hasClients` 1
    b `hasClients` 1
    setNetworkConfig a nc {sessionMode = TSMEntity}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 2

    exchangeGreetingsMsgId 6 a bId1 b aId1
    exchangeGreetingsMsgId 6 a bId1' b aId1'
    liftIO $ threadDelay 250000
    setNetworkConfig a nc {sessionMode = TSMUser}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 1

    aUserId2 <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId2, bId2) <- makeConnectionForUsers a aUserId2 b 1
    exchangeGreetings a bId2 b aId2
    (aId2', bId2') <- makeConnectionForUsers a aUserId2 b 1
    exchangeGreetings a bId2' b aId2'
    a `hasClients` 2
    b `hasClients` 1
    setNetworkConfig a nc {sessionMode = TSMEntity}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 4
    exchangeGreetingsMsgId 8 a bId1 b aId1
    exchangeGreetingsMsgId 8 a bId1' b aId1'
    exchangeGreetingsMsgId 6 a bId2 b aId2
    exchangeGreetingsMsgId 6 a bId2' b aId2'
    liftIO $ threadDelay 250000
    setNetworkConfig a nc {sessionMode = TSMUser}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 2
    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 10 a bId1' b aId1'
    exchangeGreetingsMsgId 8 a bId2 b aId2
    exchangeGreetingsMsgId 8 a bId2' b aId2'
  where
    hasClients :: HasCallStack => AgentClient -> Int -> ExceptT AgentErrorType IO ()
    hasClients c n = liftIO $ M.size <$> readTVarIO (smpClients c) `shouldReturn` n

getSMPAgentClient' :: AgentConfig -> InitialAgentServers -> FilePath -> IO AgentClient
getSMPAgentClient' cfg' initServers dbPath = do
  Right st <- liftIO $ createAgentStore dbPath "" MCError
  getSMPAgentClient cfg' initServers st

testServerMultipleIdentities :: HasCallStack => IO ()
testServerMultipleIdentities = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo"
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId
    -- this saves queue with second server identity
    Left (BROKER _ NETWORK) <- runExceptT $ joinConnection bob 1 True secondIdentityCReq "bob's connInfo"
    disconnectAgentClient bob
    bob' <- liftIO $ getSMPAgentClient' agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    exchangeGreetingsMsgId 6 alice bobId bob' aliceId
  where
    secondIdentityCReq :: ConnectionRequestUri 'CMInvitation
    secondIdentityCReq =
      CRInvitationUri
        connReqData
          { crSmpQueues =
              [ SMPQueueUri
                  supportedSMPClientVRange
                  queueAddr
                    { smpServer = SMPServer "localhost" "5001" (C.KeyHash "\215m\248\251")
                    }
              ]
          }
        testE2ERatchetParams

exchangeGreetings :: HasCallStack => AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings = exchangeGreetingsMsgId 4

exchangeGreetingsMsgId :: HasCallStack => Int64 -> AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
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
