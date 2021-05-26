{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
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
    it "should connect via one server and 2 agents" $
      smpAgentTest2_2_1 $ testDuplexConnection t
    it "should connect via 2 servers and 2 agents" $
      smpAgentTest2_2_2 $ testDuplexConnection t
  describe "Connection subscriptions" do
    it "should connect via one server and one agent" $
      smpAgentTest3_1_1 $ testSubscription t
    it "should send notifications to client when server disconnects" $
      smpAgentServerTest $ testSubscrNotification t

type TestTransmission p = (ACorrId, ByteString, APartyCmd p)

type TestTransmissionOrError p = (ACorrId, ByteString, Either AgentErrorType (APartyCmd p))

testTE :: ATransmissionOrError p -> TestTransmissionOrError p
testTE (ATransmissionOrError corrId entity cmdOrErr) =
  (corrId,serializeEntity entity,) $ case cmdOrErr of
    Right cmd -> Right $ Pc cmd
    Left e -> Left e

-- | send transmission `t` to handle `h` and get response
(#:) :: Transport c => c -> (ByteString, ByteString, ByteString) -> IO (TestTransmissionOrError 'Agent)
h #: t = tPutRaw h t >> testTE <$> tGet SAgent h

-- | action and expected response
-- `h #:t #> r` is the test that sends `t` to `h` and validates that the response is `r`
(#>) :: IO (TestTransmissionOrError 'Agent) -> TestTransmission 'Agent -> Expectation
action #> (corrId, cAlias, cmd) = action `shouldReturn` (corrId, cAlias, Right cmd)

-- | action and predicate for the response
-- `h #:t =#> p` is the test that sends `t` to `h` and validates the response using `p`
(=#>) :: IO (TestTransmissionOrError 'Agent) -> (TestTransmission 'Agent -> Bool) -> Expectation
action =#> p = action >>= (`shouldSatisfy` p . correctTransmission)

correctTransmission :: TestTransmissionOrError p -> TestTransmission p
correctTransmission (corrId, cAlias, cmdOrErr) = case cmdOrErr of
  Right cmd -> (corrId, cAlias, cmd)
  Left e -> error $ show e

-- | receive message to handle `h` and validate that it is the expected one
(<#) :: Transport c => c -> TestTransmission 'Agent -> Expectation
h <# (corrId, cAlias, cmd) = tGet SAgent h >>= (`shouldBe` (corrId, cAlias, Right cmd)) . testTE

-- | receive message to handle `h` and validate it using predicate `p`
(<#=) :: Transport c => c -> (TestTransmission 'Agent -> Bool) -> Expectation
h <#= p = tGet SAgent h >>= (`shouldSatisfy` p . correctTransmission . testTE)

-- | test that nothing is delivered to handle `h` during 10ms
(#:#) :: Transport c => c -> String -> Expectation
h #:# err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` tGet SAgent h >>= \case
        Just _ -> error err
        _ -> return ()

pattern Msg :: MsgBody -> APartyCmd 'Agent
pattern Msg msgBody <- APartyCmd MSG {msgBody, msgIntegrity = MsgOk}

pattern Pc :: ACommand p c -> APartyCmd p
pattern Pc cmd = APartyCmd cmd

testDuplexConnection :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnection _ alice bob = do
  ("1", "bob", Right (Pc (INV qInfo))) <- alice #: ("1", "bob", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "alice", "JOIN " <> qInfo') #> ("", "alice", Pc CON)
  alice <# ("", "bob", Pc CON)
  alice #: ("2", "bob", "SEND :hello") =#> \case ("2", "bob", Pc (SENT 1)) -> True; _ -> False
  alice #: ("3", "bob", "SEND :how are you?") =#> \case ("3", "bob", Pc (SENT 2)) -> True; _ -> False
  bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
  bob <#= \case ("", "alice", Msg "how are you?") -> True; _ -> False
  bob #: ("14", "alice", "SEND 9\nhello too") =#> \case ("14", "alice", Pc (SENT 3)) -> True; _ -> False
  alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
  bob #: ("15", "alice", "SEND 9\nmessage 1") =#> \case ("15", "alice", Pc (SENT 4)) -> True; _ -> False
  alice <#= \case ("", "bob", Msg "message 1") -> True; _ -> False
  alice #: ("5", "bob", "OFF") #> ("5", "bob", Pc OK)
  bob #: ("17", "alice", "SEND 9\nmessage 3") #> ("17", "alice", Pc $ ERR (SMP AUTH))
  alice #: ("6", "bob", "DEL") #> ("6", "bob", Pc OK)
  alice #:# "nothing else should be delivered to alice"

testSubscription :: Transport c => TProxy c -> c -> c -> c -> IO ()
testSubscription _ alice1 alice2 bob = do
  ("1", "bob", Right (Pc (INV qInfo))) <- alice1 #: ("1", "bob", "NEW")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "alice", "JOIN " <> qInfo') #> ("", "alice", Pc CON)
  bob #: ("12", "alice", "SEND 5\nhello") =#> \case ("12", "alice", Pc (SENT _)) -> True; _ -> False
  bob #: ("13", "alice", "SEND 11\nhello again") =#> \case ("13", "alice", Pc (SENT _)) -> True; _ -> False
  alice1 <# ("", "bob", Pc CON)
  alice1 <#= \case ("", "bob", Msg "hello") -> True; _ -> False
  alice1 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice2 #: ("21", "bob", "SUB") #> ("21", "bob", Pc OK)
  alice1 <# ("", "bob", Pc END)
  bob #: ("14", "alice", "SEND 2\nhi") =#> \case ("14", "alice", Pc (SENT _)) -> True; _ -> False
  alice2 <#= \case ("", "bob", Msg "hi") -> True; _ -> False
  alice1 #:# "nothing else should be delivered to alice1"

testSubscrNotification :: Transport c => TProxy c -> (ThreadId, ThreadId) -> c -> IO ()
testSubscrNotification _ (server, _) client = do
  client #: ("1", "conn1", "NEW") =#> \case ("1", "conn1", Pc (INV _)) -> True; _ -> False
  client #:# "nothing should be delivered to client before the server is killed"
  killThread server
  client <# ("", "conn1", Pc END)

samplePublicKey :: ByteString
samplePublicKey = "rsa:MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAtn1NI2tPoOGSGfad0aUg0tJ0kG2nzrIPGLiz8wb3dQSJC9xkRHyzHhEE8Kmy2cM4q7rNZIlLcm4M7oXOTe7SC4x59bLQG9bteZPKqXu9wk41hNamV25PWQ4zIcIRmZKETVGbwN7jFMpH7wxLdI1zzMArAPKXCDCJ5ctWh4OWDI6OR6AcCtEj+toCI6N6pjxxn5VigJtwiKhxYpoUJSdNM60wVEDCSUrZYBAuDH8pOxPfP+Tm4sokaFDTIG3QJFzOjC+/9nW4MUjAOFll9PCp9kaEFHJ/YmOYKMWNOCCPvLS6lxA83i0UaardkNLNoFS5paWfTlroxRwOC2T6PwO2ywKBgDjtXcSED61zK1seocQMyGRINnlWdhceD669kIHju/f6kAayvYKW3/lbJNXCmyinAccBosO08/0sUxvtuniIo18kfYJE0UmP1ReCjhMP+O+yOmwZJini/QelJk/Pez8IIDDWnY1qYQsN/q7ocjakOYrpGG7mig6JMFpDJtD6istR"

syntaxTests :: forall c. Transport c => TProxy c -> Spec
syntaxTests t = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR CMD SYNTAX")
  describe "NEW" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      xit "without parameters" $ ("211", "", "NEW") >#>= \case ("211", "", "INV" : _) -> True; _ -> False
    describe "invalid" do
      -- TODO: add tests with defined connection alias
      it "with parameters" $ ("222", "", "NEW hi") >#> ("222", "", "ERR CMD SYNTAX")

  describe "JOIN" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      it "using same server as in invitation" $
        ("311", "", "JOIN smp::localhost:5000::1234::" <> samplePublicKey) >#> ("311", "", "ERR SMP AUTH")
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
