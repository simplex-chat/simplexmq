{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests where

import AgentTests.SQLite
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import SMPAgentClient
import Simplex.Messaging.Agent.Transmission
import Test.Hspec

agentTests :: Spec
agentTests = do
  describe "SQLite store" storeTests
  fdescribe "SMP agent protocol syntax" syntaxTests

(>#>) :: ARawTransmission -> ARawTransmission -> Expectation
command >#> response = smpAgentTest command `shouldReturn` response

(>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
command >#>= p = smpAgentTest command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))

syntaxTests :: Spec
syntaxTests = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR UNKNOWN")
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
      it "no parameters" $ ("221", "", "NEW") >#> ("221", "", "ERR SYNTAX 2")
      it "many parameters" $ ("222", "", "NEW localhost:5000 hi") >#> ("222", "", "ERR SYNTAX 2")
      it "invalid server keyHash" $ ("223", "", "NEW localhost:5000#1") >#> ("223", "", "ERR SYNTAX 10")

  describe "JOIN" do
    describe "valid" do
      -- TODO: ERROR no connection alias in the response (it does not generate it yet if not provided)
      -- TODO: add tests with defined connection alias
      -- TODO: JOIN is not merged yet - to be added
      it "using same server as in invitation" $
        ("311", "", "JOIN smp::localhost:5000::1234::5678") >#> ("311", "", "ERR SMP AUTH")
    describe "invalid" do
      -- TODO: JOIN is not merged yet - to be added
      it "no parameters" $ ("321", "", "JOIN") >#> ("321", "", "ERR SYNTAX 2")
