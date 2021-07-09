{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests (agentTests) where

import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.SQLiteTests (storeTests)
import Control.Concurrent
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import Simplex.Messaging.Transport (ATransport (..), TProxy (..), Transport (..))
import System.Timeout
import Test.Hspec

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "SQLite store" storeTests
  describe "SMP agent protocol syntax" $ syntaxTests t
  describe "Establishing duplex connection" do
    it "should connect via one server and one agent" $
      smpAgentTest2_1_1 $ testDuplexConnection t
    it "should connect via one server and one agent (random IDs)" $
      smpAgentTest2_1_1 $ testDuplexConnRandomIds t
    it "should connect via one server and 2 agents" $
      smpAgentTest2_2_1 $ testDuplexConnection t
    it "should connect via one server and 2 agents (random IDs)" $
      smpAgentTest2_2_1 $ testDuplexConnRandomIds t
    it "should connect via 2 servers and 2 agents" $
      smpAgentTest2_2_2 $ testDuplexConnection t
    it "should connect via 2 servers and 2 agents (random IDs)" $
      smpAgentTest2_2_2 $ testDuplexConnRandomIds t
  describe "Connection subscriptions" do
    it "should connect via one server and one agent" $
      smpAgentTest3_1_1 $ testSubscription t
    it "should send notifications to client when server disconnects" $
      smpAgentServerTest $ testSubscrNotification t
  describe "Introduction" do
    it "should send and accept introduction" $
      smpAgentTest3 $ testIntroduction t
    it "should send and accept introduction (random IDs)" $
      smpAgentTest3 $ testIntroductionRandomIds t

-- | receive message to handle `h`
(<#:) :: Transport c => c -> IO (ATransmissionOrError 'Agent)
(<#:) = tGet SAgent

-- | send transmission `t` to handle `h` and get response
(#:) :: Transport c => c -> (ByteString, ByteString, ByteString) -> IO (ATransmissionOrError 'Agent)
h #: t = tPutRaw h t >> (<#:) h

-- | action and expected response
-- `h #:t #> r` is the test that sends `t` to `h` and validates that the response is `r`
(#>) :: IO (ATransmissionOrError 'Agent) -> ATransmission 'Agent -> Expectation
action #> (corrId, cAlias, cmd) = action `shouldReturn` (corrId, cAlias, Right cmd)

-- | action and predicate for the response
-- `h #:t =#> p` is the test that sends `t` to `h` and validates the response using `p`
(=#>) :: IO (ATransmissionOrError 'Agent) -> (ATransmission 'Agent -> Bool) -> Expectation
action =#> p = action >>= (`shouldSatisfy` p . correctTransmission)

correctTransmission :: ATransmissionOrError a -> ATransmission a
correctTransmission (corrId, cAlias, cmdOrErr) = case cmdOrErr of
  Right cmd -> (corrId, cAlias, cmd)
  Left e -> error $ show e

-- | receive message to handle `h` and validate that it is the expected one
(<#) :: Transport c => c -> ATransmission 'Agent -> Expectation
h <# (corrId, cAlias, cmd) = (h <#:) `shouldReturn` (corrId, cAlias, Right cmd)

-- | receive message to handle `h` and validate it using predicate `p`
(<#=) :: Transport c => c -> (ATransmission 'Agent -> Bool) -> Expectation
h <#= p = (h <#:) >>= (`shouldSatisfy` p . correctTransmission)

-- | test that nothing is delivered to handle `h` during 10ms
(#:#) :: Transport c => c -> String -> Expectation
h #:# err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` tGet SAgent h >>= \case
        Just _ -> error err
        _ -> return ()

pattern Msg :: MsgBody -> ACommand 'Agent
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk} msgBody

testDuplexConnection :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnection _ alice bob = do
  ("1", "bob", Right (INV qInfo)) <- alice #: ("1", "bob", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "alice", "JOIN " <> qInfo' <> " 14\nbob's connInfo") #> ("11", "alice", OK)
  ("", "bob", Right (CONF confId "bob's connInfo")) <- (alice <#:)
  alice #: ("2", "bob", "LET " <> confId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  bob <# ("", "alice", INFO "alice's connInfo")
  bob <# ("", "alice", CON)
  alice <# ("", "bob", CON)
  alice #: ("3", "bob", "SEND :hello") #> ("3", "bob", SENT 1)
  alice #: ("4", "bob", "SEND :how are you?") #> ("4", "bob", SENT 2)
  bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
  bob <#= \case ("", "alice", Msg "how are you?") -> True; _ -> False
  bob #: ("14", "alice", "SEND 9\nhello too") #> ("14", "alice", SENT 3)
  alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
  bob #: ("15", "alice", "SEND 9\nmessage 1") #> ("15", "alice", SENT 4)
  alice <#= \case ("", "bob", Msg "message 1") -> True; _ -> False
  alice #: ("5", "bob", "OFF") #> ("5", "bob", OK)
  bob #: ("17", "alice", "SEND 9\nmessage 3") #> ("17", "alice", ERR (SMP AUTH))
  alice #: ("6", "bob", "DEL") #> ("6", "bob", OK)
  alice #:# "nothing else should be delivered to alice"

testDuplexConnRandomIds :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnRandomIds _ alice bob = do
  ("1", bobConn, Right (INV qInfo)) <- alice #: ("1", "", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  ("11", aliceConn, Right OK) <- bob #: ("11", "", "JOIN " <> qInfo' <> " 14\nbob's connInfo")
  ("", bobConn', Right (CONF confId "bob's connInfo")) <- (alice <#:)
  bobConn' `shouldBe` bobConn
  alice #: ("2", bobConn, "LET " <> confId <> " 16\nalice's connInfo") =#> \case ("2", c, OK) -> c == bobConn; _ -> False
  bob <# ("", aliceConn, INFO "alice's connInfo")
  bob <# ("", aliceConn, CON)
  alice <# ("", bobConn, CON)
  alice #: ("2", bobConn, "SEND :hello") #> ("2", bobConn, SENT 1)
  alice #: ("3", bobConn, "SEND :how are you?") #> ("3", bobConn, SENT 2)
  bob <#= \case ("", c, Msg "hello") -> c == aliceConn; _ -> False
  bob <#= \case ("", c, Msg "how are you?") -> c == aliceConn; _ -> False
  bob #: ("14", aliceConn, "SEND 9\nhello too") #> ("14", aliceConn, SENT 3)
  alice <#= \case ("", c, Msg "hello too") -> c == bobConn; _ -> False
  bob #: ("15", aliceConn, "SEND 9\nmessage 1") #> ("15", aliceConn, SENT 4)
  alice <#= \case ("", c, Msg "message 1") -> c == bobConn; _ -> False
  alice #: ("5", bobConn, "OFF") #> ("5", bobConn, OK)
  bob #: ("17", aliceConn, "SEND 9\nmessage 3") #> ("17", aliceConn, ERR (SMP AUTH))
  alice #: ("6", bobConn, "DEL") #> ("6", bobConn, OK)
  alice #:# "nothing else should be delivered to alice"

testSubscription :: Transport c => TProxy c -> c -> c -> c -> IO ()
testSubscription _ alice1 alice2 bob = do
  (alice1, "alice") `connect` (bob, "bob")
  bob #: ("12", "alice", "SEND 5\nhello") #> ("12", "alice", SENT 1)
  bob #: ("13", "alice", "SEND 11\nhello again") #> ("13", "alice", SENT 2)
  alice1 <#= \case ("", "bob", Msg "hello") -> True; _ -> False
  alice1 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice2 #: ("21", "bob", "SUB") #> ("21", "bob", OK)
  alice1 <# ("", "bob", END)
  bob #: ("14", "alice", "SEND 2\nhi") #> ("14", "alice", SENT 3)
  alice2 <#= \case ("", "bob", Msg "hi") -> True; _ -> False
  alice1 #:# "nothing else should be delivered to alice1"

testSubscrNotification :: Transport c => TProxy c -> (ThreadId, ThreadId) -> c -> IO ()
testSubscrNotification _ (server, _) client = do
  client #: ("1", "conn1", "NEW") =#> \case ("1", "conn1", INV {}) -> True; _ -> False
  client #:# "nothing should be delivered to client before the server is killed"
  killThread server
  client <# ("", "conn1", END)

testIntroduction :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testIntroduction _ alice bob tom = do
  -- establish connections
  (alice, "alice") `connect` (bob, "bob")
  (alice, "alice") `connect` (tom, "tom")
  -- send introduction of tom to bob
  alice #: ("1", "bob", "INTRO tom 8\nmeet tom") #> ("1", "bob", OK)
  ("", "alice", Right (REQ invId1 "meet tom")) <- (bob <#:)
  bob #: ("2", "tom_via_alice", "ACPT " <> invId1 <> " 7\nI'm bob") #> ("2", "tom_via_alice", OK)
  ("", "alice", Right (REQ invId2 "I'm bob")) <- (tom <#:)
  tom #: ("3", "bob_via_alice", "ACPT " <> invId2 <> " 8\ntom here") #> ("3", "bob_via_alice", OK)
  ("", "tom_via_alice", Right (CONF confId "tom here")) <- (bob <#:)
  bob #: ("3.1", "tom_via_alice", "LET " <> confId <> " 7\nI'm bob") #> ("3.1", "tom_via_alice", OK)
  bob <# ("", "tom_via_alice", CON)
  tom <# ("", "bob_via_alice", INFO "I'm bob")
  tom <# ("", "bob_via_alice", CON)
  alice <# ("", "bob", ICON "tom")
  -- they can message each other now
  tom #: ("4", "bob_via_alice", "SEND :hello") #> ("4", "bob_via_alice", SENT 1)
  bob <#= \case ("", "tom_via_alice", Msg "hello") -> True; _ -> False
  bob #: ("5", "tom_via_alice", "SEND 9\nhello too") #> ("5", "tom_via_alice", SENT 2)
  tom <#= \case ("", "bob_via_alice", Msg "hello too") -> True; _ -> False

testIntroductionRandomIds :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testIntroductionRandomIds _ alice bob tom = do
  -- establish connections
  (aliceB, bobA) <- alice `connect'` bob
  (aliceT, tomA) <- alice `connect'` tom
  -- send introduction of tom to bob
  alice #: ("1", bobA, "INTRO " <> tomA <> " 8\nmeet tom") #> ("1", bobA, OK)
  ("", aliceB', Right (REQ invId1 "meet tom")) <- (bob <#:)
  aliceB' `shouldBe` aliceB
  ("2", tomB, Right OK) <- bob #: ("2", "", "ACPT " <> invId1 <> " 7\nI'm bob")
  ("", aliceT', Right (REQ invId2 "I'm bob")) <- (tom <#:)
  aliceT' `shouldBe` aliceT
  ("3", bobT, Right OK) <- tom #: ("3", "", "ACPT " <> invId2 <> " 8\ntom here")
  ("", tomB', Right (CONF confId "tom here")) <- (bob <#:)
  tomB' `shouldBe` tomB
  bob #: ("3.1", tomB, "LET " <> confId <> " 7\nI'm bob") =#> \case ("3.1", c, OK) -> c == tomB; _ -> False
  bob <# ("", tomB, CON)
  tom <# ("", bobT, INFO "I'm bob")
  tom <# ("", bobT, CON)
  alice <# ("", bobA, ICON tomA)
  -- they can message each other now
  tom #: ("4", bobT, "SEND :hello") #> ("4", bobT, SENT 1)
  bob <#= \case ("", c, Msg "hello") -> c == tomB; _ -> False
  bob #: ("5", tomB, "SEND 9\nhello too") #> ("5", tomB, SENT 2)
  tom <#= \case ("", c, Msg "hello too") -> c == bobT; _ -> False

connect :: forall c. Transport c => (c, ByteString) -> (c, ByteString) -> IO ()
connect (h1, name1) (h2, name2) = do
  ("c1", _, Right (INV qInfo)) <- h1 #: ("c1", name2, "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  h2 #: ("c2", name1, "JOIN " <> qInfo' <> " 5\ninfo2") #> ("c2", name1, OK)
  ("", _, Right (CONF connId "info2")) <- (h1 <#:)
  h1 #: ("c3", name2, "LET " <> connId <> " 5\ninfo1") #> ("c3", name2, OK)
  h2 <# ("", name1, INFO "info1")
  h2 <# ("", name1, CON)
  h1 <# ("", name2, CON)

connect' :: forall c. Transport c => c -> c -> IO (ByteString, ByteString)
connect' h1 h2 = do
  ("c1", conn2, Right (INV qInfo)) <- h1 #: ("c1", "", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  ("c2", conn1, Right OK) <- h2 #: ("c2", "", "JOIN " <> qInfo' <> " 5\ninfo2")
  ("", _, Right (CONF connId "info2")) <- (h1 <#:)
  h1 #: ("c3", conn2, "LET " <> connId <> " 5\ninfo1") =#> \case ("c3", c, OK) -> c == conn2; _ -> False
  h2 <# ("", conn1, INFO "info1")
  h2 <# ("", conn1, CON)
  h1 <# ("", conn2, CON)
  pure (conn1, conn2)

samplePublicKey :: ByteString
samplePublicKey = "rsa:MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAtn1NI2tPoOGSGfad0aUg0tJ0kG2nzrIPGLiz8wb3dQSJC9xkRHyzHhEE8Kmy2cM4q7rNZIlLcm4M7oXOTe7SC4x59bLQG9bteZPKqXu9wk41hNamV25PWQ4zIcIRmZKETVGbwN7jFMpH7wxLdI1zzMArAPKXCDCJ5ctWh4OWDI6OR6AcCtEj+toCI6N6pjxxn5VigJtwiKhxYpoUJSdNM60wVEDCSUrZYBAuDH8pOxPfP+Tm4sokaFDTIG3QJFzOjC+/9nW4MUjAOFll9PCp9kaEFHJ/YmOYKMWNOCCPvLS6lxA83i0UaardkNLNoFS5paWfTlroxRwOC2T6PwO2ywKBgDjtXcSED61zK1seocQMyGRINnlWdhceD669kIHju/f6kAayvYKW3/lbJNXCmyinAccBosO08/0sUxvtuniIo18kfYJE0UmP1ReCjhMP+O+yOmwZJini/QelJk/Pez8IIDDWnY1qYQsN/q7ocjakOYrpGG7mig6JMFpDJtD6istR"

syntaxTests :: forall c. Transport c => TProxy c -> Spec
syntaxTests t = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR CMD SYNTAX")
  describe "NEW" do
    describe "valid" do
      -- TODO: add tests with defined connection alias
      it "without parameters" $ ("211", "", "NEW") >#>= \case ("211", _, "INV" : _) -> True; _ -> False
    describe "invalid" do
      -- TODO: add tests with defined connection alias
      it "with parameters" $ ("222", "", "NEW hi") >#> ("222", "", "ERR CMD SYNTAX")

  describe "JOIN" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      it "using same server as in invitation" $
        ("311", "a", "JOIN smp::localhost:5000::1234::" <> samplePublicKey <> " 14\nbob's connInfo") >#> ("311", "a", "ERR SMP AUTH")
    describe "invalid" do
      -- TODO: JOIN is not merged yet - to be added
      it "no parameters" $ ("321", "", "JOIN") >#> ("321", "", "ERR CMD SYNTAX")
  where
    -- simple test for one command with the expected response
    (>#>) :: ARawTransmission -> ARawTransmission -> Expectation
    command >#> response = smpAgentTest t command `shouldReturn` response

    -- simple test for one command with a predicate for the expected response
    (>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
    command >#>= p = smpAgentTest t command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))
