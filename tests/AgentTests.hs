{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module AgentTests where

import AgentTests.SQLiteTests (storeTests)
import Control.Concurrent
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store (InvitationId)
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import Simplex.Messaging.Transport (ATransport (..), TProxy (..), Transport (..))
import System.Timeout
import Test.Hspec

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
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
  describe "Broadcast" do
    it "should create broadcast and send messages" $
      smpAgentTest3 $ testBroadcast t
    it "should create broadcast and send messages (random IDs)" $
      smpAgentTest3 $ testBroadcastRandomIds t
  describe "Introduction" do
    it "should send and accept introduction" $
      smpAgentTest3 $ testIntroduction t
    it "should send and accept introduction (random IDs)" $
      smpAgentTest3 $ testIntroductionRandomIds t

type TestTransmission p = (ACorrId, ByteString, APartyCmd p)

type TestTransmission' p c = (ACorrId, ByteString, ACommand p c)

type TestTransmissionOrError p = (ACorrId, ByteString, Either AgentErrorType (APartyCmd p))

testTE :: ATransmissionOrError p -> TestTransmissionOrError p
testTE (ATransmissionOrError corrId entity cmdOrErr) =
  (corrId,serializeEntity entity,) $ case cmdOrErr of
    Right cmd -> Right $ APartyCmd cmd
    Left e -> Left e

-- | receive message to handle `h`
(<#:) :: Transport c => c -> IO (TestTransmissionOrError 'Agent)
(<#:) h = testTE <$> tGet SAgent h

-- | send transmission `t` to handle `h` and get response
(#:) :: Transport c => c -> (ByteString, ByteString, ByteString) -> IO (TestTransmissionOrError 'Agent)
h #: t = tPutRaw h t >> (h <#:)

-- | action and expected response
-- `h #:t #> r` is the test that sends `t` to `h` and validates that the response is `r`
(#>) :: IO (TestTransmissionOrError 'Agent) -> TestTransmission' 'Agent c -> Expectation
action #> (corrId, cAlias, cmd) = action `shouldReturn` (corrId, cAlias, Right (APartyCmd cmd))

-- | action and predicate for the response
-- `h #:t =#> p` is the test that sends `t` to `h` and validates the response using `p`
(=#>) :: IO (TestTransmissionOrError 'Agent) -> (TestTransmission 'Agent -> Bool) -> Expectation
action =#> p = action >>= (`shouldSatisfy` p . correctTransmission)

correctTransmission :: TestTransmissionOrError p -> TestTransmission p
correctTransmission (corrId, cAlias, cmdOrErr) = case cmdOrErr of
  Right cmd -> (corrId, cAlias, cmd)
  Left e -> error $ show e

-- | receive message to handle `h` and validate that it is the expected one
(<#) :: Transport c => c -> TestTransmission' 'Agent c' -> Expectation
h <# (corrId, cAlias, cmd) = (h <#:) >>= (`shouldBe` (corrId, cAlias, Right (APartyCmd cmd)))

-- | receive message to handle `h` and validate it using predicate `p`
(<#=) :: Transport c => c -> (TestTransmission 'Agent -> Bool) -> Expectation
h <#= p = (h <#:) >>= (`shouldSatisfy` p . correctTransmission)

-- | test that nothing is delivered to handle `h` during 10ms
(#:#) :: Transport c => c -> String -> Expectation
h #:# err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` tGet SAgent h >>= \case
        Just _ -> error err
        _ -> return ()

pattern Sent :: AgentMsgId -> APartyCmd 'Agent
pattern Sent msgId <- APartyCmd (SENT msgId)

pattern Msg :: MsgBody -> APartyCmd 'Agent
pattern Msg msgBody <- APartyCmd MSG {msgBody, msgIntegrity = MsgOk}

pattern Inv :: SMPQueueInfo -> Either AgentErrorType (APartyCmd 'Agent)
pattern Inv invitation <- Right (APartyCmd (INV invitation))

pattern Req :: InvitationId -> EntityInfo -> Either AgentErrorType (APartyCmd 'Agent)
pattern Req invId eInfo <- Right (APartyCmd (REQ (IE (Conn invId)) eInfo))

testDuplexConnection :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnection _ alice bob = do
  ("1", "C:bob", Inv qInfo) <- alice #: ("1", "C:bob", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "C:alice", "JOIN " <> qInfo') #> ("", "C:alice", CON)
  alice <# ("", "C:bob", CON)
  alice #: ("2", "C:bob", "SEND :hello") #> ("2", "C:bob", SENT 1)
  alice #: ("3", "C:bob", "SEND :how are you?") #> ("3", "C:bob", SENT 2)
  bob <#= \case ("", "C:alice", Msg "hello") -> True; _ -> False
  bob <#= \case ("", "C:alice", Msg "how are you?") -> True; _ -> False
  bob #: ("14", "C:alice", "SEND 9\nhello too") #> ("14", "C:alice", SENT 3)
  alice <#= \case ("", "C:bob", Msg "hello too") -> True; _ -> False
  bob #: ("15", "C:alice", "SEND 9\nmessage 1") #> ("15", "C:alice", SENT 4)
  alice <#= \case ("", "C:bob", Msg "message 1") -> True; _ -> False
  alice #: ("5", "C:bob", "OFF") #> ("5", "C:bob", OK)
  bob #: ("17", "C:alice", "SEND 9\nmessage 3") #> ("17", "C:alice", ERR (SMP AUTH))
  alice #: ("6", "C:bob", "DEL") #> ("6", "C:bob", OK)
  alice #:# "nothing else should be delivered to alice"

testDuplexConnRandomIds :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnRandomIds _ alice bob = do
  ("1", bobConn, Inv qInfo) <- alice #: ("1", "C:", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  ("", aliceConn, Right (APartyCmd CON)) <- bob #: ("11", "C:", "JOIN " <> qInfo')
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
  ("1", "C:bob", Inv qInfo) <- alice1 #: ("1", "C:bob", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "C:alice", "JOIN " <> qInfo') #> ("", "C:alice", CON)
  bob #: ("12", "C:alice", "SEND 5\nhello") #> ("12", "C:alice", SENT 1)
  bob #: ("13", "C:alice", "SEND 11\nhello again") #> ("13", "C:alice", SENT 2)
  alice1 <# ("", "C:bob", CON)
  alice1 <#= \case ("", "C:bob", Msg "hello") -> True; _ -> False
  alice1 <#= \case ("", "C:bob", Msg "hello again") -> True; _ -> False
  alice2 #: ("21", "C:bob", "SUB") #> ("21", "C:bob", OK)
  alice1 <# ("", "C:bob", END)
  bob #: ("14", "C:alice", "SEND 2\nhi") #> ("14", "C:alice", SENT 3)
  alice2 <#= \case ("", "C:bob", Msg "hi") -> True; _ -> False
  alice1 #:# "nothing else should be delivered to alice1"

testSubscrNotification :: Transport c => TProxy c -> (ThreadId, ThreadId) -> c -> IO ()
testSubscrNotification _ (server, _) client = do
  client #: ("1", "C:conn1", "NEW") =#> \case ("1", "C:conn1", APartyCmd INV {}) -> True; _ -> False
  client #:# "nothing should be delivered to client before the server is killed"
  killThread server
  client <# ("", "C:conn1", END)

testBroadcast :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testBroadcast _ alice bob tom = do
  -- establish connections
  (alice, "alice") `connect` (bob, "bob")
  (alice, "alice") `connect` (tom, "tom")
  -- create and set up broadcast
  alice #: ("1", "B:team", "NEW") #> ("1", "B:team", OK)
  alice #: ("2", "B:team", "ADD C:bob") #> ("2", "B:team", OK)
  alice #: ("3", "B:team", "ADD C:tom") #> ("3", "B:team", OK)
  -- commands with errors
  alice #: ("e1", "B:team", "NEW") #> ("e1", "B:team", ERR $ BCAST B_DUPLICATE)
  alice #: ("e2", "B:group", "ADD C:bob") #> ("e2", "B:group", ERR $ BCAST B_NOT_FOUND)
  alice #: ("e3", "B:team", "ADD C:unknown") #> ("e3", "B:team", ERR $ CONN NOT_FOUND)
  alice #: ("e4", "B:team", "ADD C:bob") #> ("e4", "B:team", ERR $ CONN DUPLICATE)
  -- send message
  alice #: ("4", "B:team", "SEND 5\nhello") =#> \case ("4", c, Sent 1) -> c == "C:bob" || c == "C:tom"; _ -> False
  alice <#= \case ("4", c, Sent 1) -> c == "C:bob" || c == "C:tom"; _ -> False
  alice <# ("4", "B:team", SENT 0)
  bob <#= \case ("", "C:alice", Msg "hello") -> True; _ -> False
  tom <#= \case ("", "C:alice", Msg "hello") -> True; _ -> False
  -- remove one connection
  alice #: ("5", "B:team", "REM C:tom") #> ("5", "B:team", OK)
  alice #: ("6", "B:team", "SEND 11\nhello again") #> ("6", "C:bob", SENT 2)
  alice <# ("6", "B:team", SENT 0)
  bob <#= \case ("", "C:alice", Msg "hello again") -> True; _ -> False
  tom #:# "nothing delivered to tom"
  -- commands with errors
  alice #: ("e5", "B:group", "REM C:bob") #> ("e5", "B:group", ERR $ BCAST B_NOT_FOUND)
  alice #: ("e6", "B:team", "REM C:unknown") #> ("e6", "B:team", ERR $ CONN NOT_FOUND)
  alice #: ("e7", "B:team", "REM C:tom") #> ("e7", "B:team", ERR $ CONN NOT_FOUND)
  -- delete broadcast
  alice #: ("7", "B:team", "DEL") #> ("7", "B:team", OK)
  alice #: ("8", "B:team", "SEND 11\ntry sending") #> ("8", "B:team", ERR $ BCAST B_NOT_FOUND)
  -- commands with errors
  alice #: ("e8", "B:team", "DEL") #> ("e8", "B:team", ERR $ BCAST B_NOT_FOUND)
  alice #: ("e9", "B:group", "DEL") #> ("e9", "B:group", ERR $ BCAST B_NOT_FOUND)

testBroadcastRandomIds :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testBroadcastRandomIds _ alice bob tom = do
  -- establish connections
  (aliceB, bobA) <- alice `connect'` bob
  (aliceT, tomA) <- alice `connect'` tom
  -- create and set up broadcast
  ("1", team, Right (APartyCmd OK)) <- alice #: ("1", "B:", "NEW")
  alice #: ("2", team, "ADD " <> bobA) #> ("2", team, OK)
  alice #: ("3", team, "ADD " <> tomA) #> ("3", team, OK)
  -- commands with errors
  alice #: ("e1", team, "NEW") #> ("e1", team, ERR $ BCAST B_DUPLICATE)
  alice #: ("e2", "B:group", "ADD " <> bobA) #> ("e2", "B:group", ERR $ BCAST B_NOT_FOUND)
  alice #: ("e3", team, "ADD C:unknown") #> ("e3", team, ERR $ CONN NOT_FOUND)
  alice #: ("e4", team, "ADD " <> bobA) #> ("e4", team, ERR $ CONN DUPLICATE)
  -- send message
  alice #: ("4", team, "SEND 5\nhello") =#> \case ("4", c, Sent 1) -> c == bobA || c == tomA; _ -> False
  alice <#= \case ("4", c, Sent 1) -> c == bobA || c == tomA; _ -> False
  alice <# ("4", team, SENT 0)
  bob <#= \case ("", c, Msg "hello") -> c == aliceB; _ -> False
  tom <#= \case ("", c, Msg "hello") -> c == aliceT; _ -> False
  -- remove one connection
  alice #: ("5", team, "REM " <> tomA) #> ("5", team, OK)
  alice #: ("6", team, "SEND 11\nhello again") #> ("6", bobA, SENT 2)
  alice <# ("6", team, SENT 0)
  bob <#= \case ("", c, Msg "hello again") -> c == aliceB; _ -> False
  tom #:# "nothing delivered to tom"
  -- commands with errors
  alice #: ("e5", "B:group", "REM " <> bobA) #> ("e5", "B:group", ERR $ BCAST B_NOT_FOUND)
  alice #: ("e6", team, "REM C:unknown") #> ("e6", team, ERR $ CONN NOT_FOUND)
  alice #: ("e7", team, "REM " <> tomA) #> ("e7", team, ERR $ CONN NOT_FOUND)
  -- delete broadcast
  alice #: ("7", team, "DEL") #> ("7", team, OK)
  alice #: ("8", team, "SEND 11\ntry sending") #> ("8", team, ERR $ BCAST B_NOT_FOUND)
  -- commands with errors
  alice #: ("e8", team, "DEL") #> ("e8", team, ERR $ BCAST B_NOT_FOUND)
  alice #: ("e9", "B:group", "DEL") #> ("e9", "B:group", ERR $ BCAST B_NOT_FOUND)

testIntroduction :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testIntroduction _ alice bob tom = do
  -- establish connections
  (alice, "alice") `connect` (bob, "bob")
  (alice, "alice") `connect` (tom, "tom")
  -- send introduction of tom to bob
  alice #: ("1", "C:bob", "INTRO C:tom 8\nmeet tom") #> ("1", "C:bob", OK)
  ("", "C:alice", Req invId1 "meet tom") <- (bob <#:)
  bob #: ("2", "C:tom_via_alice", "ACPT C:" <> invId1 <> " 7\nI'm bob") #> ("2", "C:tom_via_alice", OK)
  ("", "C:alice", Req invId2 "I'm bob") <- (tom <#:)
  -- TODO info "tom here" is not used, either JOIN command also should have eInfo parameter
  -- or this should be another command, not ACPT
  tom #: ("3", "C:bob_via_alice", "ACPT C:" <> invId2 <> " 8\ntom here") #> ("3", "C:bob_via_alice", OK)
  tom <# ("", "C:bob_via_alice", CON)
  bob <# ("", "C:tom_via_alice", CON)
  alice <# ("", "C:bob", ICON (IE (Conn "tom")))
  -- they can message each other now
  tom #: ("4", "C:bob_via_alice", "SEND :hello") #> ("4", "C:bob_via_alice", SENT 1)
  bob <#= \case ("", "C:tom_via_alice", Msg "hello") -> True; _ -> False
  bob #: ("5", "C:tom_via_alice", "SEND 9\nhello too") #> ("5", "C:tom_via_alice", SENT 2)
  tom <#= \case ("", "C:bob_via_alice", Msg "hello too") -> True; _ -> False

testIntroductionRandomIds :: forall c. Transport c => TProxy c -> c -> c -> c -> IO ()
testIntroductionRandomIds _ alice bob tom = do
  -- establish connections
  (aliceB, bobA) <- alice `connect'` bob
  (aliceT, tomA) <- alice `connect'` tom
  -- send introduction of tom to bob
  alice #: ("1", bobA, "INTRO " <> tomA <> " 8\nmeet tom") #> ("1", bobA, OK)
  ("", aliceB', Req invId1 "meet tom") <- (bob <#:)
  aliceB' `shouldBe` aliceB
  ("2", tomB, Right (APartyCmd OK)) <- bob #: ("2", "C:", "ACPT C:" <> invId1 <> " 7\nI'm bob")
  ("", aliceT', Req invId2 "I'm bob") <- (tom <#:)
  aliceT' `shouldBe` aliceT
  -- TODO info "tom here" is not used, either JOIN command also should have eInfo parameter
  -- or this should be another command, not ACPT
  ("3", bobT, Right (APartyCmd OK)) <- tom #: ("3", "C:", "ACPT C:" <> invId2 <> " 8\ntom here")
  tom <# ("", bobT, CON)
  bob <# ("", tomB, CON)
  alice <# ("", bobA, ICON . IE . Conn $ B.drop 2 tomA)
  -- they can message each other now
  tom #: ("4", bobT, "SEND :hello") #> ("4", bobT, SENT 1)
  bob <#= \case ("", c, Msg "hello") -> c == tomB; _ -> False
  bob #: ("5", tomB, "SEND 9\nhello too") #> ("5", tomB, SENT 2)
  tom <#= \case ("", c, Msg "hello too") -> c == bobT; _ -> False

connect :: forall c. Transport c => (c, ByteString) -> (c, ByteString) -> IO ()
connect (h1, name1) (h2, name2) = do
  ("c1", _, Inv qInfo) <- h1 #: ("c1", "C:" <> name2, "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  h2 #: ("c2", "C:" <> name1, "JOIN " <> qInfo') #> ("", "C:" <> name1, CON)
  h1 <# ("", "C:" <> name2, CON)

connect' :: forall c. Transport c => c -> c -> IO (ByteString, ByteString)
connect' h1 h2 = do
  ("c1", conn2, Inv qInfo) <- h1 #: ("c1", "C:", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  ("", conn1, Right (APartyCmd CON)) <- h2 #: ("c2", "C:", "JOIN " <> qInfo')
  h1 <# ("", conn2, CON)
  pure (conn1, conn2)

samplePublicKey :: ByteString
samplePublicKey = "rsa:MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAtn1NI2tPoOGSGfad0aUg0tJ0kG2nzrIPGLiz8wb3dQSJC9xkRHyzHhEE8Kmy2cM4q7rNZIlLcm4M7oXOTe7SC4x59bLQG9bteZPKqXu9wk41hNamV25PWQ4zIcIRmZKETVGbwN7jFMpH7wxLdI1zzMArAPKXCDCJ5ctWh4OWDI6OR6AcCtEj+toCI6N6pjxxn5VigJtwiKhxYpoUJSdNM60wVEDCSUrZYBAuDH8pOxPfP+Tm4sokaFDTIG3QJFzOjC+/9nW4MUjAOFll9PCp9kaEFHJ/YmOYKMWNOCCPvLS6lxA83i0UaardkNLNoFS5paWfTlroxRwOC2T6PwO2ywKBgDjtXcSED61zK1seocQMyGRINnlWdhceD669kIHju/f6kAayvYKW3/lbJNXCmyinAccBosO08/0sUxvtuniIo18kfYJE0UmP1ReCjhMP+O+yOmwZJini/QelJk/Pez8IIDDWnY1qYQsN/q7ocjakOYrpGG7mig6JMFpDJtD6istR"

syntaxTests :: forall c. Transport c => TProxy c -> Spec
syntaxTests t = do
  it "unknown command" $ ("1", "C:5678", "HELLO") >#> ("1", "C:5678", "ERR CMD SYNTAX")
  describe "NEW" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      xit "without parameters" $ ("211", "C:", "NEW") >#>= \case ("211", "C:", "INV" : _) -> True; _ -> False
    describe "invalid" do
      -- TODO: add tests with defined connection alias
      it "with parameters" $ ("222", "C:", "NEW hi") >#> ("222", "C:", "ERR CMD SYNTAX")

  describe "JOIN" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      it "using same server as in invitation" $
        ("311", "C:a", "JOIN smp::localhost:5000::1234::" <> samplePublicKey) >#> ("311", "C:a", "ERR SMP AUTH")
    describe "invalid" do
      -- TODO: JOIN is not merged yet - to be added
      it "no parameters" $ ("321", "C:", "JOIN") >#> ("321", "C:", "ERR CMD SYNTAX")
  where
    -- simple test for one command with the expected response
    (>#>) :: ARawTransmission -> ARawTransmission -> Expectation
    command >#> response = smpAgentTest t command `shouldReturn` response

    -- simple test for one command with a predicate for the expected response
    (>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
    command >#>= p = smpAgentTest t command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))
