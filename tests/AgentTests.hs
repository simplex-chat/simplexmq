{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests where

import AgentTests.SQLite
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Types (ErrorType (..))
import System.IO (Handle)
import System.Timeout
import Test.Hspec

agentTests :: Spec
agentTests = do
  describe "SQLite store" storeTests
  describe "SMP agent protocol syntax" syntaxTests
  describe "Establishing duplex connection" do
    it "should connect via one server and one agent" $
      smpAgentTest2_1 testDuplexConnection1
    it "should connect via one server and two agents" $
      smpAgentTest2 testDuplexConnection1

sendRecv :: Handle -> (ByteString, ByteString, ByteString) -> IO (ATransmissionOrError 'Agent)
sendRecv h (corrId, connAlias, cmd) = tPutRaw h (corrId, connAlias, cmd) >> tGet SAgent h

(>#>) :: ARawTransmission -> ARawTransmission -> Expectation
command >#> response = smpAgentTest command `shouldReturn` response

(>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
command >#>= p = smpAgentTest command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))

testDuplexConnection1 :: Handle -> Handle -> IO ()
testDuplexConnection1 alice bob = do
  ("1", "bob", Right (INV qInfo)) <- sendRecv alice ("1", "bob", "NEW localhost:5000")
  ("11", "alice", Right CON) <- sendRecv bob ("11", "alice", "JOIN " <> serializeSmpQueueInfo qInfo)
  ("", "bob", Right CON) <- tGet SAgent alice
  ("2", "bob", Right OK) <- sendRecv alice ("2", "bob", "SEND :hello")
  ("3", "bob", Right OK) <- sendRecv alice ("3", "bob", "SEND :how are you?")
  ("", "alice", Right (MSG _ _ _ _ "hello")) <- tGet SAgent bob
  ("12", "alice", Right OK) <- sendRecv bob ("12", "alice", "ACK 0")
  ("", "alice", Right (MSG _ _ _ _ "how are you?")) <- tGet SAgent bob
  ("13", "alice", Right OK) <- sendRecv bob ("13", "alice", "ACK 0")
  ("14", "alice", Right OK) <- sendRecv bob ("14", "alice", "SEND 9\nhello too")
  ("", "bob", Right (MSG _ _ _ _ "hello too")) <- tGet SAgent alice
  ("4", "bob", Right OK) <- sendRecv alice ("4", "bob", "ACK 0")
  ("15", "alice", Right OK) <- sendRecv bob ("15", "alice", "SEND 9\nmessage 1")
  ("16", "alice", Right OK) <- sendRecv bob ("16", "alice", "SEND 9\nmessage 2")
  ("", "bob", Right (MSG _ _ _ _ "message 1")) <- tGet SAgent alice
  ("5", "bob", Right OK) <- sendRecv alice ("5", "bob", "OFF")
  ("17", "alice", Right (ERR (SMP AUTH))) <- sendRecv bob ("17", "alice", "SEND 9\nmessage 3")
  ("6", "bob", Right OK) <- sendRecv alice ("6", "bob", "DEL")
  10000 `timeout` tGet SAgent alice >>= \case
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
