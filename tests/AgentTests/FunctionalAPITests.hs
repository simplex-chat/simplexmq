{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.FunctionalAPITests (functionalAPITests) where

import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.IO.Unlift
import SMPAgentClient
import SMPClient (withSmpServer)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.Postgres (AgentConfig (..))
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import Simplex.Messaging.Transport (ATransport (..))
import System.Timeout
import Test.Hspec
import UnliftIO.STM

(##>) :: MonadIO m => m (ATransmission 'Agent) -> ATransmission 'Agent -> m ()
a ##> t = a >>= \t' -> liftIO (t' `shouldBe` t)

(=##>) :: MonadIO m => m (ATransmission 'Agent) -> (ATransmission 'Agent -> Bool) -> m ()
a =##> p = a >>= \t -> liftIO (t `shouldSatisfy` p)

get :: MonadIO m => AgentClient -> m (ATransmission 'Agent)
get c = atomically (readTBQueue $ subQ c)

pattern Msg :: MsgBody -> ACommand 'Agent
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk} msgBody

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
    it "should notify after HELLO timeout" $
      withSmpServer t testAsyncHelloTimeout

testAgentClient :: IO ()
testAgentClient = do
  alice <- getSMPAgentClient cfg
  bob <- getSMPAgentClient cfg {dbConnInfo = testDB2}
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 get assigned to control messages, so first MSG is assigned ID 4
    4 <- sendMessage alice bobId "hello"
    get alice ##> ("", bobId, SENT 4)
    5 <- sendMessage alice bobId "how are you?"
    get alice ##> ("", bobId, SENT 5)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId 4
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId 5
    6 <- sendMessage bob aliceId "hello too"
    get bob ##> ("", aliceId, SENT 6)
    7 <- sendMessage bob aliceId "message 1"
    get bob ##> ("", aliceId, SENT 7)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId 6
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId 7
    suspendConnection alice bobId
    8 <- sendMessage bob aliceId "message 2"
    get bob ##> ("", aliceId, MERR 8 (SMP AUTH))
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
  alice <- getSMPAgentClient cfg
  bob <- getSMPAgentClient cfg {dbConnInfo = testDB2}
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    alice' <- liftIO $ getSMPAgentClient cfg
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
  alice <- getSMPAgentClient cfg
  bob <- getSMPAgentClient cfg {dbConnInfo = testDB2}
  Right () <- runExceptT $ do
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    disconnectAgentClient bob
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient cfg {dbConnInfo = testDB2}
    subscribeConnection bob' aliceId
    get alice ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob' aliceId
  pure ()

testAsyncBothOffline :: IO ()
testAsyncBothOffline = do
  alice <- getSMPAgentClient cfg
  bob <- getSMPAgentClient cfg {dbConnInfo = testDB2}
  Right () <- runExceptT $ do
    (bobId, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    disconnectAgentClient bob
    alice' <- liftIO $ getSMPAgentClient cfg
    subscribeConnection alice' bobId
    ("", _, CONF confId "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient cfg {dbConnInfo = testDB2}
    subscribeConnection bob' aliceId
    get alice' ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob' aliceId
  pure ()

testAsyncHelloTimeout :: IO ()
testAsyncHelloTimeout = do
  alice <- getSMPAgentClient cfg
  bob <- getSMPAgentClient cfg {dbConnInfo = testDB2, helloTimeout = 1}
  Right () <- runExceptT $ do
    (_, cReq) <- createConnection alice SCMInvitation
    disconnectAgentClient alice
    aliceId <- joinConnection bob cReq "bob's connInfo"
    get bob ##> ("", aliceId, ERR $ CONN NOT_ACCEPTED)
  pure ()

exchangeGreetings :: AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings alice bobId bob aliceId = do
  4 <- sendMessage alice bobId "hello"
  get alice ##> ("", bobId, SENT 4)
  get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
  ackMessage bob aliceId 4
  5 <- sendMessage bob aliceId "hello too"
  get bob ##> ("", aliceId, SENT 5)
  get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
  ackMessage alice bobId 5
