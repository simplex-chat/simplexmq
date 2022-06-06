{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.FunctionalAPITests (functionalAPITests) where

import Control.Concurrent (threadDelay)
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.IO.Unlift
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import SMPAgentClient
import SMPClient (cfg, testPort, withSmpServer, withSmpServerConfigOn, withSmpServerStoreLogOn)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..))
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec
import UnliftIO

(##>) :: MonadIO m => m (ATransmission 'Agent) -> ATransmission 'Agent -> m ()
a ##> t = a >>= \t' -> liftIO (t' `shouldBe` t)

(=##>) :: MonadIO m => m (ATransmission 'Agent) -> (ATransmission 'Agent -> Bool) -> m ()
a =##> p = a >>= \t -> liftIO (t `shouldSatisfy` p)

get :: MonadIO m => AgentClient -> m (ATransmission 'Agent)
get c = atomically (readTBQueue $ subQ c)

pattern Msg :: MsgBody -> ACommand 'Agent
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk} _ msgBody

functionalAPITests :: ATransport -> Spec
functionalAPITests t = do
  describe "Establishing duplex connection" $
    it "should connect via one server using SMP agent clients" $
      withSmpServer t testAgentClient
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
  describe "Inactive client disconnection" $ do
    it "should disconnect clients if it was inactive longer than TTL" $
      testInactiveClientDisconnected t
    it "should NOT disconnect active clients" $
      testActiveClientNotDisconnected t

testAgentClient :: IO ()
testAgentClient = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 4 get assigned to control messages, so first MSG is assigned ID 5
    5 <- sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT 5)
    6 <- sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT 6)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId 5
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId 6
    7 <- sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT 7)
    8 <- sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT 8)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId 7
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId 8
    suspendConnection alice bobId
    9 <- sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR 9 (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  pure ()
  where
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
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    alice' <- liftIO $ getSMPAgentClient agentCfg initAgentServers
    subscribeConnection alice' bobId
    ("", _, CONF confId "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    get alice' ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob aliceId
  pure ()

testAsyncJoiningOfflineBeforeActivation :: IO ()
testAsyncJoiningOfflineBeforeActivation = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    disconnectAgentClient bob
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
    subscribeConnection bob' aliceId
    get alice ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob' aliceId
  pure ()

testAsyncBothOffline :: IO ()
testAsyncBothOffline = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    disconnectAgentClient bob
    alice' <- liftIO $ getSMPAgentClient agentCfg initAgentServers
    subscribeConnection alice' bobId
    ("", _, CONF confId "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
    subscribeConnection bob' aliceId
    get alice' ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob' aliceId
  pure ()

testAsyncServerOffline :: ATransport -> IO ()
testAsyncServerOffline t = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  -- create connection and shutdown the server
  Right (bobId, cReq) <- withSmpServerStoreLogOn t testPort $ \_ ->
    runExceptT $ createConnection alice SCMInvitation
  -- connection fails
  Left (BROKER NETWORK) <- runExceptT $ joinConnection bob cReq "bob's connInfo"
  ("", "", DOWN srv conns) <- get alice
  srv `shouldBe` testSMPServer
  conns `shouldBe` [bobId]
  -- connection succeeds after server start
  Right () <- withSmpServerStoreLogOn t testPort $ \_ -> runExceptT $ do
    ("", "", UP srv1 conns1) <- get alice
    liftIO $ do
      srv1 `shouldBe` testSMPServer
      conns1 `shouldBe` [bobId]
    aliceId <- joinConnection bob cReq "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId
  pure ()

testAsyncHelloTimeout :: IO ()
testAsyncHelloTimeout = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2, helloTimeout = 1} initAgentServers
  Right () <- runExceptT $ do
    (_, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    get bob ##> ("", aliceId, ERR $ CONN NOT_ACCEPTED)
  pure ()

testInactiveClientDisconnected :: ATransport -> IO ()
testInactiveClientDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient agentCfg initAgentServers
    Right () <- runExceptT $ do
      (connId, _cReq) <- createConnection alice SCMInvitation
      get alice ##> ("", "", DOWN testSMPServer [connId])
    pure ()

testActiveClientNotDisconnected :: ATransport -> IO ()
testActiveClientNotDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient agentCfg initAgentServers
    ts <- getSystemTime
    Right () <- runExceptT $ do
      (connId, _cReq) <- createConnection alice SCMInvitation
      keepSubscribing alice connId ts
    pure ()
  where
    keepSubscribing :: AgentClient -> ConnId -> SystemTime -> ExceptT AgentErrorType IO ()
    keepSubscribing alice connId ts = do
      ts' <- liftIO $ getSystemTime
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

exchangeGreetings :: AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings alice bobId bob aliceId = do
  5 <- sendMessage alice bobId SMP.noMsgFlags "hello"
  get alice ##> ("", bobId, SENT 5)
  get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
  ackMessage bob aliceId 5
  6 <- sendMessage bob aliceId SMP.noMsgFlags "hello too"
  get bob ##> ("", aliceId, SENT 6)
  get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
  ackMessage alice bobId 6
