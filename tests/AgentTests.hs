{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module AgentTests where

import AgentTests.SQLiteTests (storeTests)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Types (ErrorType (..), MsgBody)
import System.IO (Handle)
import System.Timeout
import Test.Hspec

agentTests :: Spec
agentTests = do
  describe "SQLite store" storeTests
  describe "SMP agent protocol syntax" syntaxTests
  describe "Establishing duplex connection" do
    it "should connect via one server and one agent" $
      smpAgentTest2_1 testDuplexConnection
    it "should connect via one server and 2 agents" $
      smpAgentTest2 testDuplexConnection
  describe "Connection subscriptions" do
    it "should connect via one server and one agent" $
      smpAgentTest3_1 testSubscription

-- | simple test for one command with the expected response
(>#>) :: ARawTransmission -> ARawTransmission -> Expectation
command >#> response = smpAgentTest command `shouldReturn` response

-- | simple test for one command with a predicate for the expected response
(>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
command >#>= p = smpAgentTest command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))

-- | send transmission `t` to handle `h` and get response
(#:) :: Handle -> (ByteString, ByteString, ByteString) -> IO (ATransmissionOrError 'Agent)
h #: t = tPutRaw h t >> tGet SAgent h

-- | action and expected response
-- `h #:t #> r` is the test that sends `t` to `h` and validates that the response is `r`
(#>) :: IO (ATransmissionOrError 'Agent) -> ATransmission 'Agent -> Expectation
action #> (corrId, cAlias, cmd) = action `shouldReturn` (corrId, cAlias, Right cmd)

-- | receive message to handle `h` and validate that it is the expected one
(<#) :: Handle -> ATransmission 'Agent -> Expectation
h <# (corrId, cAlias, cmd) = tGet SAgent h `shouldReturn` (corrId, cAlias, Right cmd)

-- | receive message to handle `h` and validate it using predicate `p`
(<#=) :: Handle -> (ATransmissionOrError 'Agent -> Bool) -> Expectation
h <#= p = tGet SAgent h >>= (`shouldSatisfy` p)

pattern Msg :: MsgBody -> Either AgentErrorType (ACommand 'Agent)
pattern Msg msg <- Right (MSG _ _ _ _ msg)

testDuplexConnection :: Handle -> Handle -> IO ()
testDuplexConnection alice bob = do
  ("1", "bob", Right (INV qInfo)) <- alice #: ("1", "bob", "NEW localhost:5000")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "alice", "JOIN " <> qInfo') #> ("11", "alice", CON)
  alice <# ("", "bob", CON)
  alice #: ("2", "bob", "SEND :hello") #> ("2", "bob", OK)
  alice #: ("3", "bob", "SEND :how are you?") #> ("3", "bob", OK)
  bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
  bob #: ("12", "alice", "ACK 0") #> ("12", "alice", OK)
  bob <#= \case ("", "alice", Msg "how are you?") -> True; _ -> False
  bob #: ("13", "alice", "ACK 0") #> ("13", "alice", OK)
  bob #: ("14", "alice", "SEND 9\nhello too") #> ("14", "alice", OK)
  alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
  alice #: ("4", "bob", "ACK 0") #> ("4", "bob", OK)
  bob #: ("15", "alice", "SEND 9\nmessage 1") #> ("15", "alice", OK)
  bob #: ("16", "alice", "SEND 9\nmessage 2") #> ("16", "alice", OK)
  alice <#= \case ("", "bob", Msg "message 1") -> True; _ -> False
  alice #: ("5", "bob", "OFF") #> ("5", "bob", OK)
  bob #: ("17", "alice", "SEND 9\nmessage 3") #> ("17", "alice", ERR (SMP AUTH))
  alice #: ("6", "bob", "DEL") #> ("6", "bob", OK)
  10000 `timeout` tGet SAgent alice >>= \case
    Nothing -> return ()
    Just _ -> error "nothing else should be delivered to alice"

testSubscription :: Handle -> Handle -> Handle -> IO ()
testSubscription alice1 alice2 bob = do
  ("1", "bob", Right (INV qInfo)) <- alice1 #: ("1", "bob", "NEW localhost:5000")
  let qInfo' = serializeSmpQueueInfo qInfo
  bob #: ("11", "alice", "JOIN " <> qInfo') #> ("11", "alice", CON)
  bob #: ("12", "alice", "SEND 5\nhello") #> ("12", "alice", OK)
  bob #: ("13", "alice", "SEND 11\nhello again") #> ("13", "alice", OK)
  alice1 <# ("", "bob", CON)
  alice1 <#= \case ("", "bob", Msg "hello") -> True; _ -> False
  alice1 #: ("2", "bob", "ACK 0") #> ("2", "bob", OK)
  alice1 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice2 #: ("21", "bob", "SUB") #> ("21", "bob", OK)
  alice2 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice1 <# ("", "bob", END)
  alice2 #: ("22", "bob", "ACK 0") #> ("22", "bob", OK)
  bob #: ("14", "alice", "SEND 2\nhi") #> ("14", "alice", OK)
  alice2 <#= \case ("", "bob", Msg "hi") -> True; _ -> False
  10000 `timeout` tGet SAgent alice1 >>= \case
    Nothing -> return ()
    Just _ -> error "nothing else should be delivered to alice"

syntaxTests :: Spec
syntaxTests = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR SYNTAX 11")
  describe "NEW" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      xit "only server" $ ("211", "", "NEW localhost") >#>= \case ("211", "", "INV" : _) -> True; _ -> False
      it "with port" $ ("212", "", "NEW localhost:5000") >#>= \case ("212", "", "INV" : _) -> True; _ -> False
      xit "with keyHash" $ ("213", "", "NEW localhost#1234") >#>= \case ("213", "", "INV" : _) -> True; _ -> False
      it "with port and keyHash" $ ("214", "", "NEW localhost:5000#1234") >#>= \case ("214", "", "INV" : _) -> True; _ -> False
    describe "invalid" do
      -- TODO: add tests with defined connection alias
      it "no parameters" $ ("221", "", "NEW") >#> ("221", "", "ERR SYNTAX 11")
      it "many parameters" $ ("222", "", "NEW localhost:5000 hi") >#> ("222", "", "ERR SYNTAX 11")
      it "invalid server keyHash" $ ("223", "", "NEW localhost:5000#1") >#> ("223", "", "ERR SYNTAX 11")

  describe "JOIN" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      it "using same server as in invitation" $
        ("311", "", "JOIN smp::localhost:5000::1234::5678") >#> ("311", "", "ERR SMP AUTH")
    describe "invalid" do
      -- TODO: JOIN is not merged yet - to be added
      it "no parameters" $ ("321", "", "JOIN") >#> ("321", "", "ERR SYNTAX 11")
