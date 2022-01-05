{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests (agentTests) where

import AgentTests.ConnectionRequestTests
import AgentTests.DoubleRatchetTests (doubleRatchetTests)
import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.SQLiteTests (storeTests)
import Control.Concurrent
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.HTTP.Types (urlEncode)
import SMPAgentClient
import SMPClient (testPort, testPort2, testStoreLogFile, withSmpServer, withSmpServerStoreLogOn)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Agent.Protocol as A
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import Simplex.Messaging.Transport (ATransport (..), TProxy (..), Transport (..))
import System.Directory (removeFile)
import System.Timeout
import Test.Hspec

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "SQLite store" storeTests
  describe "SMP agent protocol syntax" $ syntaxTests t
  describe "Establishing duplex connection" $ do
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
  describe "Establishing connections via `contact connection`" $ do
    it "should connect via contact connection with one server and 3 agents" $
      smpAgentTest3 $ testContactConnection t
    it "should connect via contact connection with one server and 2 agents (random IDs)" $
      smpAgentTest2_2_1 $ testContactConnRandomIds t
    it "should support rejecting contact request" $
      smpAgentTest2_2_1 $ testRejectContactRequest t
  describe "Connection subscriptions" $ do
    it "should connect via one server and one agent" $
      smpAgentTest3_1_1 $ testSubscription t
    it "should send notifications to client when server disconnects" $
      smpAgentServerTest $ testSubscrNotification t
  describe "Message delivery" $ do
    it "should deliver messages after losing server connection and re-connecting" $
      smpAgentTest2_2_2_needs_server $ testMsgDeliveryServerRestart t
    it "should deliver pending messages after agent restarting" $
      smpAgentTest1_1_1 $ testMsgDeliveryAgentRestart t

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
  ("1", "bob", Right (INV cReq)) <- alice #: ("1", "bob", "NEW INV")
  let cReq' = strEncode cReq
  bob #: ("11", "alice", "JOIN " <> cReq' <> " 14\nbob's connInfo") #> ("11", "alice", OK)
  ("", "bob", Right (CONF confId "bob's connInfo")) <- (alice <#:)
  alice #: ("2", "bob", "LET " <> confId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  bob <# ("", "alice", INFO "alice's connInfo")
  bob <# ("", "alice", CON)
  alice <# ("", "bob", CON)
  alice #: ("3", "bob", "SEND :hello") #> ("3", "bob", MID 1)
  alice <# ("", "bob", SENT 1)
  bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
  bob #: ("12", "alice", "ACK 1") #> ("12", "alice", OK)
  alice #: ("4", "bob", "SEND :how are you?") #> ("4", "bob", MID 2)
  alice <# ("", "bob", SENT 2)
  bob <#= \case ("", "alice", Msg "how are you?") -> True; _ -> False
  bob #: ("13", "alice", "ACK 2") #> ("13", "alice", OK)
  bob #: ("14", "alice", "SEND 9\nhello too") #> ("14", "alice", MID 3)
  bob <# ("", "alice", SENT 3)
  alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
  alice #: ("3a", "bob", "ACK 3") #> ("3a", "bob", OK)
  bob #: ("15", "alice", "SEND 9\nmessage 1") #> ("15", "alice", MID 4)
  bob <# ("", "alice", SENT 4)
  alice <#= \case ("", "bob", Msg "message 1") -> True; _ -> False
  alice #: ("4a", "bob", "ACK 4") #> ("4a", "bob", OK)
  alice #: ("5", "bob", "OFF") #> ("5", "bob", OK)
  bob #: ("17", "alice", "SEND 9\nmessage 3") #> ("17", "alice", MID 5)
  bob <# ("", "alice", MERR 5 (SMP AUTH))
  alice #: ("6", "bob", "DEL") #> ("6", "bob", OK)
  alice #:# "nothing else should be delivered to alice"

testDuplexConnRandomIds :: Transport c => TProxy c -> c -> c -> IO ()
testDuplexConnRandomIds _ alice bob = do
  ("1", bobConn, Right (INV cReq)) <- alice #: ("1", "", "NEW INV")
  let cReq' = strEncode cReq
  ("11", aliceConn, Right OK) <- bob #: ("11", "", "JOIN " <> cReq' <> " 14\nbob's connInfo")
  ("", bobConn', Right (CONF confId "bob's connInfo")) <- (alice <#:)
  bobConn' `shouldBe` bobConn
  alice #: ("2", bobConn, "LET " <> confId <> " 16\nalice's connInfo") =#> \case ("2", c, OK) -> c == bobConn; _ -> False
  bob <# ("", aliceConn, INFO "alice's connInfo")
  bob <# ("", aliceConn, CON)
  alice <# ("", bobConn, CON)
  alice #: ("2", bobConn, "SEND :hello") #> ("2", bobConn, MID 1)
  alice <# ("", bobConn, SENT 1)
  bob <#= \case ("", c, Msg "hello") -> c == aliceConn; _ -> False
  bob #: ("12", aliceConn, "ACK 1") #> ("12", aliceConn, OK)
  alice #: ("3", bobConn, "SEND :how are you?") #> ("3", bobConn, MID 2)
  alice <# ("", bobConn, SENT 2)
  bob <#= \case ("", c, Msg "how are you?") -> c == aliceConn; _ -> False
  bob #: ("13", aliceConn, "ACK 2") #> ("13", aliceConn, OK)
  bob #: ("14", aliceConn, "SEND 9\nhello too") #> ("14", aliceConn, MID 3)
  bob <# ("", aliceConn, SENT 3)
  alice <#= \case ("", c, Msg "hello too") -> c == bobConn; _ -> False
  alice #: ("3a", bobConn, "ACK 3") #> ("3a", bobConn, OK)
  bob #: ("15", aliceConn, "SEND 9\nmessage 1") #> ("15", aliceConn, MID 4)
  bob <# ("", aliceConn, SENT 4)
  alice <#= \case ("", c, Msg "message 1") -> c == bobConn; _ -> False
  alice #: ("4a", bobConn, "ACK 4") #> ("4a", bobConn, OK)
  alice #: ("5", bobConn, "OFF") #> ("5", bobConn, OK)
  bob #: ("17", aliceConn, "SEND 9\nmessage 3") #> ("17", aliceConn, MID 5)
  bob <# ("", aliceConn, MERR 5 (SMP AUTH))
  alice #: ("6", bobConn, "DEL") #> ("6", bobConn, OK)
  alice #:# "nothing else should be delivered to alice"

testContactConnection :: Transport c => TProxy c -> c -> c -> c -> IO ()
testContactConnection _ alice bob tom = do
  ("1", "alice_contact", Right (INV cReq)) <- alice #: ("1", "alice_contact", "NEW CON")
  let cReq' = strEncode cReq

  bob #: ("11", "alice", "JOIN " <> cReq' <> " 14\nbob's connInfo") #> ("11", "alice", OK)
  ("", "alice_contact", Right (REQ aInvId "bob's connInfo")) <- (alice <#:)
  alice #: ("2", "bob", "ACPT " <> aInvId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  ("", "alice", Right (CONF bConfId "alice's connInfo")) <- (bob <#:)
  bob #: ("12", "alice", "LET " <> bConfId <> " 16\nbob's connInfo 2") #> ("12", "alice", OK)
  alice <# ("", "bob", INFO "bob's connInfo 2")
  alice <# ("", "bob", CON)
  bob <# ("", "alice", CON)
  alice #: ("3", "bob", "SEND :hi") #> ("3", "bob", MID 1)
  alice <# ("", "bob", SENT 1)
  bob <#= \case ("", "alice", Msg "hi") -> True; _ -> False
  bob #: ("13", "alice", "ACK 1") #> ("13", "alice", OK)

  tom #: ("21", "alice", "JOIN " <> cReq' <> " 14\ntom's connInfo") #> ("21", "alice", OK)
  ("", "alice_contact", Right (REQ aInvId' "tom's connInfo")) <- (alice <#:)
  alice #: ("4", "tom", "ACPT " <> aInvId' <> " 16\nalice's connInfo") #> ("4", "tom", OK)
  ("", "alice", Right (CONF tConfId "alice's connInfo")) <- (tom <#:)
  tom #: ("22", "alice", "LET " <> tConfId <> " 16\ntom's connInfo 2") #> ("22", "alice", OK)
  alice <# ("", "tom", INFO "tom's connInfo 2")
  alice <# ("", "tom", CON)
  tom <# ("", "alice", CON)
  alice #: ("5", "tom", "SEND :hi there") #> ("5", "tom", MID 1)
  alice <# ("", "tom", SENT 1)
  tom <#= \case ("", "alice", Msg "hi there") -> True; _ -> False
  tom #: ("23", "alice", "ACK 1") #> ("23", "alice", OK)

testContactConnRandomIds :: Transport c => TProxy c -> c -> c -> IO ()
testContactConnRandomIds _ alice bob = do
  ("1", aliceContact, Right (INV cReq)) <- alice #: ("1", "", "NEW CON")
  let cReq' = strEncode cReq

  ("11", aliceConn, Right OK) <- bob #: ("11", "", "JOIN " <> cReq' <> " 14\nbob's connInfo")
  ("", aliceContact', Right (REQ aInvId "bob's connInfo")) <- (alice <#:)
  aliceContact' `shouldBe` aliceContact

  ("2", bobConn, Right OK) <- alice #: ("2", "", "ACPT " <> aInvId <> " 16\nalice's connInfo")
  ("", aliceConn', Right (CONF bConfId "alice's connInfo")) <- (bob <#:)
  aliceConn' `shouldBe` aliceConn

  bob #: ("12", aliceConn, "LET " <> bConfId <> " 16\nbob's connInfo 2") #> ("12", aliceConn, OK)
  alice <# ("", bobConn, INFO "bob's connInfo 2")
  alice <# ("", bobConn, CON)
  bob <# ("", aliceConn, CON)

  alice #: ("3", bobConn, "SEND :hi") #> ("3", bobConn, MID 1)
  alice <# ("", bobConn, SENT 1)
  bob <#= \case ("", c, Msg "hi") -> c == aliceConn; _ -> False
  bob #: ("13", aliceConn, "ACK 1") #> ("13", aliceConn, OK)

testRejectContactRequest :: Transport c => TProxy c -> c -> c -> IO ()
testRejectContactRequest _ alice bob = do
  ("1", "a_contact", Right (INV cReq)) <- alice #: ("1", "a_contact", "NEW CON")
  let cReq' = strEncode cReq
  bob #: ("11", "alice", "JOIN " <> cReq' <> " 10\nbob's info") #> ("11", "alice", OK)
  ("", "a_contact", Right (REQ aInvId "bob's info")) <- (alice <#:)
  -- RJCT must use correct contact connection
  alice #: ("2a", "bob", "RJCT " <> aInvId) #> ("2a", "bob", ERR $ CONN NOT_FOUND)
  alice #: ("2b", "a_contact", "RJCT " <> aInvId) #> ("2b", "a_contact", OK)
  alice #: ("3", "bob", "ACPT " <> aInvId <> " 12\nalice's info") #> ("3", "bob", ERR $ A.CMD PROHIBITED)
  bob #:# "nothing should be delivered to bob"

testSubscription :: Transport c => TProxy c -> c -> c -> c -> IO ()
testSubscription _ alice1 alice2 bob = do
  (alice1, "alice") `connect` (bob, "bob")
  bob #: ("12", "alice", "SEND 5\nhello") #> ("12", "alice", MID 1)
  bob <# ("", "alice", SENT 1)
  alice1 <#= \case ("", "bob", Msg "hello") -> True; _ -> False
  alice1 #: ("1", "bob", "ACK 1") #> ("1", "bob", OK)
  bob #: ("13", "alice", "SEND 11\nhello again") #> ("13", "alice", MID 2)
  bob <# ("", "alice", SENT 2)
  alice1 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice1 #: ("2", "bob", "ACK 2") #> ("2", "bob", OK)
  alice2 #: ("21", "bob", "SUB") #> ("21", "bob", OK)
  alice1 <# ("", "bob", END)
  bob #: ("14", "alice", "SEND 2\nhi") #> ("14", "alice", MID 3)
  bob <# ("", "alice", SENT 3)
  alice2 <#= \case ("", "bob", Msg "hi") -> True; _ -> False
  alice2 #: ("22", "bob", "ACK 3") #> ("22", "bob", OK)
  alice1 #:# "nothing else should be delivered to alice1"

testSubscrNotification :: Transport c => TProxy c -> (ThreadId, ThreadId) -> c -> IO ()
testSubscrNotification t (server, _) client = do
  client #: ("1", "conn1", "NEW INV") =#> \case ("1", "conn1", INV {}) -> True; _ -> False
  client #:# "nothing should be delivered to client before the server is killed"
  killThread server
  client <# ("", "conn1", DOWN)
  withSmpServer (ATransport t) $
    client <# ("", "conn1", ERR (SMP AUTH)) -- this new server does not have the queue

testMsgDeliveryServerRestart :: Transport c => TProxy c -> c -> c -> IO ()
testMsgDeliveryServerRestart t alice bob = do
  withServer $ do
    connect (alice, "alice") (bob, "bob")
    bob #: ("1", "alice", "SEND 2\nhi") #> ("1", "alice", MID 1)
    bob <# ("", "alice", SENT 1)
    alice <#= \case ("", "bob", Msg "hi") -> True; _ -> False
    alice #: ("11", "bob", "ACK 1") #> ("11", "bob", OK)
    alice #:# "nothing else delivered before the server is killed"

  alice <# ("", "bob", DOWN)
  bob #: ("2", "alice", "SEND 11\nhello again") #> ("2", "alice", MID 2)
  bob #:# "nothing else delivered before the server is restarted"
  alice #:# "nothing else delivered before the server is restarted"

  withServer $ do
    bob <# ("", "alice", SENT 2)
    alice <# ("", "bob", UP)
    alice <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
    alice #: ("12", "bob", "ACK 2") #> ("12", "bob", OK)

  removeFile testStoreLogFile
  where
    withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()

testMsgDeliveryAgentRestart :: Transport c => TProxy c -> c -> IO ()
testMsgDeliveryAgentRestart t bob = do
  withAgent $ \alice -> do
    withServer $ do
      connect (bob, "bob") (alice, "alice")
      alice #: ("1", "bob", "SEND 5\nhello") #> ("1", "bob", MID 1)
      alice <# ("", "bob", SENT 1)
      bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
      bob #: ("11", "alice", "ACK 1") #> ("11", "alice", OK)
      bob #:# "nothing else delivered before the server is down"

    bob <# ("", "alice", DOWN)
    alice #: ("2", "bob", "SEND 11\nhello again") #> ("2", "bob", MID 2)
    alice #:# "nothing else delivered before the server is restarted"
    bob #:# "nothing else delivered before the server is restarted"

  withAgent $ \alice -> do
    withServer $ do
      tPutRaw alice ("3", "bob", "SUB")
      alice <#= \case
        (corrId, "bob", cmd) ->
          (corrId == "3" && cmd == OK)
            || (corrId == "" && cmd == SENT 2)
        _ -> False
      bob <# ("", "alice", UP)
      bob <#= \case ("", "alice", Msg "hello again") -> True; _ -> False
      bob #: ("12", "alice", "ACK 2") #> ("12", "alice", OK)

  removeFile testStoreLogFile
  removeFile testDB
  where
    withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()
    withAgent = withSmpAgentThreadOn_ (ATransport t) (agentTestPort, testPort, testDB) (pure ()) . const . testSMPAgentClientOn agentTestPort

connect :: forall c. Transport c => (c, ByteString) -> (c, ByteString) -> IO ()
connect (h1, name1) (h2, name2) = do
  ("c1", _, Right (INV cReq)) <- h1 #: ("c1", name2, "NEW INV")
  let cReq' = strEncode cReq
  h2 #: ("c2", name1, "JOIN " <> cReq' <> " 5\ninfo2") #> ("c2", name1, OK)
  ("", _, Right (CONF connId "info2")) <- (h1 <#:)
  h1 #: ("c3", name2, "LET " <> connId <> " 5\ninfo1") #> ("c3", name2, OK)
  h2 <# ("", name1, INFO "info1")
  h2 <# ("", name1, CON)
  h1 <# ("", name2, CON)

-- connect' :: forall c. Transport c => c -> c -> IO (ByteString, ByteString)
-- connect' h1 h2 = do
--   ("c1", conn2, Right (INV cReq)) <- h1 #: ("c1", "", "NEW INV")
--   let cReq' = strEncode cReq
--   ("c2", conn1, Right OK) <- h2 #: ("c2", "", "JOIN " <> cReq' <> " 5\ninfo2")
--   ("", _, Right (REQ connId "info2")) <- (h1 <#:)
--   h1 #: ("c3", conn2, "ACPT " <> connId <> " 5\ninfo1") =#> \case ("c3", c, OK) -> c == conn2; _ -> False
--   h2 <# ("", conn1, INFO "info1")
--   h2 <# ("", conn1, CON)
--   h1 <# ("", conn2, CON)
--   pure (conn1, conn2)

sampleDhKey :: ByteString
sampleDhKey = "MCowBQYDK2VuAyEAjiswwI3O_NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

syntaxTests :: forall c. Transport c => TProxy c -> Spec
syntaxTests t = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR CMD SYNTAX")
  describe "NEW" $ do
    describe "valid" $ do
      -- TODO: add tests with defined connection alias
      it "with correct parameter" $ ("211", "", "NEW INV") >#>= \case ("211", _, "INV" : _) -> True; _ -> False
    describe "invalid" $ do
      -- TODO: add tests with defined connection alias
      it "with incorrect parameter" $ ("222", "", "NEW hi") >#> ("222", "", "ERR CMD SYNTAX")

  describe "JOIN" $ do
    describe "valid" $ do
      it "using same server as in invitation" $
        ( "311",
          "a",
          "JOIN https://simpex.chat/invitation#/?smp=smp%3A%2F%2F"
            <> urlEncode True "9VjLsOY5ZvB4hoglNdBzJFAUi_vP4GkZnJFahQOXV20="
            <> "%40localhost%3A5001%2F3456-w%3D%3D%23"
            <> urlEncode True sampleDhKey
            <> "&v=1"
            <> "&e2e=v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> " 14\nbob's connInfo"
        )
          >#> ("311", "a", "ERR SMP AUTH")
    describe "invalid" $ do
      it "no parameters" $ ("321", "", "JOIN") >#> ("321", "", "ERR CMD SYNTAX")
  where
    -- simple test for one command with the expected response
    (>#>) :: ARawTransmission -> ARawTransmission -> Expectation
    command >#> response = smpAgentTest t command `shouldReturn` response

    -- simple test for one command with a predicate for the expected response
    (>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
    command >#>= p = smpAgentTest t command >>= (`shouldSatisfy` p . \(cId, cAlias, cmd) -> (cId, cAlias, B.words cmd))
