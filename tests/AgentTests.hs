{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module AgentTests (agentTests) where

import AgentTests.ConnectionRequestTests
import AgentTests.DoubleRatchetTests (doubleRatchetTests)
import AgentTests.FunctionalAPITests (functionalAPITests, inAnyOrder, pattern Msg, pattern Msg', pattern SENT)
import AgentTests.MigrationTests (migrationTests)
import AgentTests.NotificationTests (notificationTests)
import AgentTests.SQLiteTests (storeTests)
import Control.Concurrent
import Control.Monad (forM_, when)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Maybe (fromJust)
import Data.Type.Equality
import GHC.Stack (withFrozenCallStack)
import Network.HTTP.Types (urlEncode)
import SMPAgentClient
import SMPClient (testKeyHash, testPort, testPort2, testStoreLogFile, withSmpServer, withSmpServerStoreLogOn)
import Simplex.Messaging.Agent.Protocol hiding (CONF, INFO, MID, REQ, SENT)
import qualified Simplex.Messaging.Agent.Protocol as A
import Simplex.Messaging.Crypto.Ratchet (InitialKeys (..), PQEncryption (..), PQSupport (..), pattern IKPQOff, pattern IKPQOn, pattern PQEncOn, pattern PQSupportOff, pattern PQSupportOn)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ErrorType (..))
import Simplex.Messaging.Transport (ATransport (..), TProxy (..), Transport (..))
import Simplex.Messaging.Util (bshow)
import System.Directory (removeFile)
import System.Timeout
import Test.Hspec
import Util

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "Notification tests" $ notificationTests (ATransport t)
  describe "SQLite store" storeTests
  describe "Migration tests" migrationTests
  describe "SMP agent protocol syntax" $ syntaxTests t
  describe "Establishing duplex connection (via agent protocol)" $ do
    skip "These tests are disabled because the agent does not work correctly with multiple connected TCP clients" $
      describe "one agent" $ do
        it "should connect via one server and one agent" $ do
          smpAgentTest2_1_1 $ testDuplexConnection t
        it "should connect via one server and one agent (random IDs)" $ do
          smpAgentTest2_1_1 $ testDuplexConnRandomIds t
    it "should connect via one server and 2 agents" $ do
      smpAgentTest2_2_1 $ testDuplexConnection t
    it "should connect via one server and 2 agents (random IDs)" $ do
      smpAgentTest2_2_1 $ testDuplexConnRandomIds t
    describe "should connect via 2 servers and 2 agents" $ do
      pqMatrix2 t smpAgentTest2_2_2 testDuplexConnection'
    describe "should connect via 2 servers and 2 agents (random IDs)" $ do
      pqMatrix2 t smpAgentTest2_2_2 testDuplexConnRandomIds'
  describe "Establishing connections via `contact connection`" $ do
    describe "should connect via contact connection with one server and 3 agents" $ do
      pqMatrix3 t smpAgentTest3 testContactConnection
    describe "should connect via contact connection with one server and 2 agents (random IDs)" $ do
      pqMatrix2NoInv t smpAgentTest2_2_1 testContactConnRandomIds
    it "should support rejecting contact request" $ do
      smpAgentTest2_2_1 $ testRejectContactRequest t
  describe "Connection subscriptions" $ do
    it "should connect via one server and one agent" $ do
      smpAgentTest3_1_1 $ testSubscription t
    it "should send notifications to client when server disconnects" $ do
      smpAgentServerTest $ testSubscrNotification t
  describe "Message delivery and server reconnection" $ do
    describe "should deliver messages after losing server connection and re-connecting" $
      pqMatrix2 t smpAgentTest2_2_2_needs_server testMsgDeliveryServerRestart
    it "should connect to the server when server goes up if it initially was down" $ do
      smpAgentTestN [] $ testServerConnectionAfterError t
    it "should deliver pending messages after agent restarting" $ do
      smpAgentTest1_1_1 $ testMsgDeliveryAgentRestart t
    it "should concurrently deliver messages to connections without blocking" $ do
      smpAgentTest2_2_1 $ testConcurrentMsgDelivery t
    it "should deliver messages if one of connections has quota exceeded" $ do
      smpAgentTest2_2_1 $ testMsgDeliveryQuotaExceeded t
    it "should resume delivering messages after exceeding quota once all messages are received" $ do
      smpAgentTest2_2_1 $ testResumeDeliveryQuotaExceeded t

type AEntityTransmission p e = (ACorrId, ConnId, ACommand p e)

type AEntityTransmissionOrError p e = (ACorrId, ConnId, Either AgentErrorType (ACommand p e))

tGetAgent :: (Transport c, HasCallStack) => c -> IO (AEntityTransmissionOrError 'Agent 'AEConn)
tGetAgent = tGetAgent' True

tGetAgent' :: forall c e. (Transport c, AEntityI e, HasCallStack) => Bool -> c -> IO (AEntityTransmissionOrError 'Agent e)
tGetAgent' skipErr h = do
  (corrId, connId, cmdOrErr) <- pGetAgent skipErr h
  case cmdOrErr of
    Right (APC e cmd) -> case testEquality e (sAEntity @e) of
      Just Refl -> pure (corrId, connId, Right cmd)
      _ -> error $ "unexpected command " <> show cmd
    Left err -> pure (corrId, connId, Left err)

pGetAgent :: forall c. Transport c => Bool -> c -> IO (ATransmissionOrError 'Agent)
pGetAgent skipErr h = do
  (corrId, connId, cmdOrErr) <- tGet SAgent h
  case cmdOrErr of
    Right (APC _ CONNECT {}) -> pGetAgent skipErr h
    Right (APC _ DISCONNECT {}) -> pGetAgent skipErr h
    Right (APC _ UP {}) -> pGetAgent skipErr h
    Right (APC _ (ERR (BROKER _ NETWORK))) | skipErr -> pGetAgent skipErr h
    cmd -> pure (corrId, connId, cmd)

-- | receive message to handle `h`
(<#:) :: Transport c => c -> IO (AEntityTransmissionOrError 'Agent 'AEConn)
(<#:) = tGetAgent

(<#:?) :: Transport c => c -> IO (ATransmissionOrError 'Agent)
(<#:?) = pGetAgent True

(<#:.) :: Transport c => c -> IO (AEntityTransmissionOrError 'Agent 'AENone)
(<#:.) = tGetAgent' True

-- | send transmission `t` to handle `h` and get response
(#:) :: Transport c => c -> (ByteString, ByteString, ByteString) -> IO (AEntityTransmissionOrError 'Agent 'AEConn)
h #: t = tPutRaw h t >> (<#:) h

(#:!) :: Transport c => c -> (ByteString, ByteString, ByteString) -> IO (AEntityTransmissionOrError 'Agent 'AEConn)
h #:! t = tPutRaw h t >> tGetAgent' False h

-- | action and expected response
-- `h #:t #> r` is the test that sends `t` to `h` and validates that the response is `r`
(#>) :: IO (AEntityTransmissionOrError 'Agent 'AEConn) -> AEntityTransmission 'Agent 'AEConn -> Expectation
action #> (corrId, connId, cmd) = withFrozenCallStack $ action `shouldReturn` (corrId, connId, Right cmd)

-- | action and predicate for the response
-- `h #:t =#> p` is the test that sends `t` to `h` and validates the response using `p`
(=#>) :: IO (AEntityTransmissionOrError 'Agent 'AEConn) -> (AEntityTransmission 'Agent 'AEConn -> Bool) -> Expectation
action =#> p = withFrozenCallStack $ action >>= (`shouldSatisfy` p . correctTransmission)

pattern MID :: AgentMsgId -> ACommand 'Agent 'AEConn
pattern MID msgId = A.MID msgId PQEncOn

correctTransmission :: (ACorrId, ConnId, Either AgentErrorType cmd) -> (ACorrId, ConnId, cmd)
correctTransmission (corrId, connId, cmdOrErr) = case cmdOrErr of
  Right cmd -> (corrId, connId, cmd)
  Left e -> error $ show e

-- | receive message to handle `h` and validate that it is the expected one
(<#) :: (HasCallStack, Transport c) => c -> AEntityTransmission 'Agent 'AEConn -> Expectation
h <# (corrId, connId, cmd) = timeout 5000000 (h <#:) `shouldReturn` Just (corrId, connId, Right cmd)

(<#.) :: (HasCallStack, Transport c) => c -> AEntityTransmission 'Agent 'AENone -> Expectation
h <#. (corrId, connId, cmd) = timeout 5000000 (h <#:.) `shouldReturn` Just (corrId, connId, Right cmd)

-- | receive message to handle `h` and validate it using predicate `p`
(<#=) :: (HasCallStack, Transport c) => c -> (AEntityTransmission 'Agent 'AEConn -> Bool) -> Expectation
h <#= p = timeout 5000000 (h <#:) >>= (`shouldSatisfy` p . correctTransmission . fromJust)

(<#=?) :: (HasCallStack, Transport c) => c -> (ATransmission 'Agent -> Bool) -> Expectation
h <#=? p = timeout 5000000 (h <#:?) >>= (`shouldSatisfy` p . correctTransmission . fromJust)

-- | test that nothing is delivered to handle `h` during 10ms
(#:#) :: Transport c => c -> String -> Expectation
h #:# err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` tGetAgent h >>= \case
        Just _ -> error err
        _ -> return ()

type PQMatrix2 c =
  HasCallStack =>
  TProxy c ->
  (HasCallStack => (c -> c -> IO ()) -> Expectation) ->
  (HasCallStack => (c, InitialKeys) -> (c, PQSupport) -> IO ()) ->
  Spec

pqMatrix2 :: PQMatrix2 c
pqMatrix2 = pqMatrix2_ True

pqMatrix2NoInv :: PQMatrix2 c
pqMatrix2NoInv = pqMatrix2_ False

pqMatrix2_ :: Bool -> PQMatrix2 c
pqMatrix2_ pqInv _ smpTest test = do
  it "dh/dh handshake" $ smpTest $ \a b -> test (a, IKPQOff) (b, PQSupportOff)
  it "dh/pq handshake" $ smpTest $ \a b -> test (a, IKPQOff) (b, PQSupportOn)
  it "pq/dh handshake" $ smpTest $ \a b -> test (a, IKPQOn) (b, PQSupportOff)
  it "pq/pq handshake" $ smpTest $ \a b -> test (a, IKPQOn) (b, PQSupportOn)
  when pqInv $ do
    it "pq-inv/dh handshake" $ smpTest $ \a b -> test (a, IKUsePQ) (b, PQSupportOff)
    it "pq-inv/pq handshake" $ smpTest $ \a b -> test (a, IKUsePQ) (b, PQSupportOn)

pqMatrix3 ::
  HasCallStack =>
  TProxy c ->
  (HasCallStack => (c -> c -> c -> IO ()) -> Expectation) ->
  (HasCallStack => (c, InitialKeys) -> (c, PQSupport) -> (c, PQSupport) -> IO ()) ->
  Spec
pqMatrix3 _ smpTest test = do
  it "dh" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOff) (c, PQSupportOff)
  it "dh/dh/pq" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOff) (c, PQSupportOn)
  it "dh/pq/dh" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOn) (c, PQSupportOff)
  it "dh/pq/pq" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOn) (c, PQSupportOn)
  it "pq/dh/dh" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOff) (c, PQSupportOff)
  it "pq/dh/pq" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOff) (c, PQSupportOn)
  it "pq/pq/dh" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOn) (c, PQSupportOff)
  it "pq" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOn) (c, PQSupportOn)

testDuplexConnection :: (HasCallStack, Transport c) => TProxy c -> c -> c -> IO ()
testDuplexConnection _ alice bob = testDuplexConnection' (alice, IKPQOn) (bob, PQSupportOn)

testDuplexConnection' :: (HasCallStack, Transport c) => (c, InitialKeys) -> (c, PQSupport) -> IO ()
testDuplexConnection' (alice, aPQ) (bob, bPQ) = do
  let pq = pqConnectionMode aPQ bPQ
  ("1", "bob", Right (INV cReq)) <- alice #: ("1", "bob", "NEW T INV" <> pqConnModeStr aPQ <> " subscribe")
  let cReq' = strEncode cReq
  bob #: ("11", "alice", "JOIN T " <> cReq' <> enableKEMStr bPQ <> " subscribe 14\nbob's connInfo") #> ("11", "alice", OK)
  ("", "bob", Right (A.CONF confId pqSup' _ "bob's connInfo")) <- (alice <#:)
  pqSup' `shouldBe` CR.connPQEncryption aPQ
  alice #: ("2", "bob", "LET " <> confId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  bob <# ("", "alice", A.INFO bPQ "alice's connInfo")
  bob <# ("", "alice", CON pq)
  alice <# ("", "bob", CON pq)
  -- message IDs 1 to 3 get assigned to control messages, so first MSG is assigned ID 4
  alice #: ("3", "bob", "SEND F :hello") #> ("3", "bob", A.MID 4 pq)
  alice <# ("", "bob", SENT 4)
  bob <#= \case ("", "alice", Msg' 4 pq' "hello") -> pq == pq'; _ -> False
  bob #: ("12", "alice", "ACK 4") #> ("12", "alice", OK)
  alice #: ("4", "bob", "SEND F :how are you?") #> ("4", "bob", A.MID 5 pq)
  alice <# ("", "bob", SENT 5)
  bob <#= \case ("", "alice", Msg' 5 pq' "how are you?") -> pq == pq'; _ -> False
  bob #: ("13", "alice", "ACK 5") #> ("13", "alice", OK)
  bob #: ("14", "alice", "SEND F 9\nhello too") #> ("14", "alice", A.MID 6 pq)
  bob <# ("", "alice", SENT 6)
  alice <#= \case ("", "bob", Msg' 6 pq' "hello too") -> pq == pq'; _ -> False
  alice #: ("3a", "bob", "ACK 6") #> ("3a", "bob", OK)
  bob #: ("15", "alice", "SEND F 9\nmessage 1") #> ("15", "alice", A.MID 7 pq)
  bob <# ("", "alice", SENT 7)
  alice <#= \case ("", "bob", Msg' 7 pq' "message 1") -> pq == pq'; _ -> False
  alice #: ("4a", "bob", "ACK 7") #> ("4a", "bob", OK)
  alice #: ("5", "bob", "OFF") #> ("5", "bob", OK)
  bob #: ("17", "alice", "SEND F 9\nmessage 3") #> ("17", "alice", A.MID 8 pq)
  bob <#= \case ("", "alice", MERR 8 (SMP _ AUTH)) -> True; _ -> False
  alice #: ("6", "bob", "DEL") #> ("6", "bob", OK)
  alice #:# "nothing else should be delivered to alice"

testDuplexConnRandomIds :: (HasCallStack, Transport c) => TProxy c -> c -> c -> IO ()
testDuplexConnRandomIds _ alice bob = testDuplexConnRandomIds' (alice, IKPQOn) (bob, PQSupportOn)

testDuplexConnRandomIds' :: (HasCallStack, Transport c) => (c, InitialKeys) -> (c, PQSupport) -> IO ()
testDuplexConnRandomIds' (alice, aPQ) (bob, bPQ) = do
  let pq = pqConnectionMode aPQ bPQ
  ("1", bobConn, Right (INV cReq)) <- alice #: ("1", "", "NEW T INV" <> pqConnModeStr aPQ <> " subscribe")
  let cReq' = strEncode cReq
  ("11", aliceConn, Right OK) <- bob #: ("11", "", "JOIN T " <> cReq' <> enableKEMStr bPQ <> " subscribe 14\nbob's connInfo")
  ("", bobConn', Right (A.CONF confId pqSup' _ "bob's connInfo")) <- (alice <#:)
  pqSup' `shouldBe` CR.connPQEncryption aPQ
  bobConn' `shouldBe` bobConn
  alice #: ("2", bobConn, "LET " <> confId <> " 16\nalice's connInfo") =#> \case ("2", c, OK) -> c == bobConn; _ -> False
  bob <# ("", aliceConn, A.INFO bPQ "alice's connInfo")
  bob <# ("", aliceConn, CON pq)
  alice <# ("", bobConn, CON pq)
  alice #: ("2", bobConn, "SEND F :hello") #> ("2", bobConn, A.MID 4 pq)
  alice <# ("", bobConn, SENT 4)
  bob <#= \case ("", c, Msg' 4 pq' "hello") -> c == aliceConn && pq == pq'; _ -> False
  bob #: ("12", aliceConn, "ACK 4") #> ("12", aliceConn, OK)
  alice #: ("3", bobConn, "SEND F :how are you?") #> ("3", bobConn, A.MID 5 pq)
  alice <# ("", bobConn, SENT 5)
  bob <#= \case ("", c, Msg' 5 pq' "how are you?") -> c == aliceConn && pq == pq'; _ -> False
  bob #: ("13", aliceConn, "ACK 5") #> ("13", aliceConn, OK)
  bob #: ("14", aliceConn, "SEND F 9\nhello too") #> ("14", aliceConn, A.MID 6 pq)
  bob <# ("", aliceConn, SENT 6)
  alice <#= \case ("", c, Msg' 6 pq' "hello too") -> c == bobConn && pq == pq'; _ -> False
  alice #: ("3a", bobConn, "ACK 6") #> ("3a", bobConn, OK)
  bob #: ("15", aliceConn, "SEND F 9\nmessage 1") #> ("15", aliceConn, A.MID 7 pq)
  bob <# ("", aliceConn, SENT 7)
  alice <#= \case ("", c, Msg' 7 pq' "message 1") -> c == bobConn && pq == pq'; _ -> False
  alice #: ("4a", bobConn, "ACK 7") #> ("4a", bobConn, OK)
  alice #: ("5", bobConn, "OFF") #> ("5", bobConn, OK)
  bob #: ("17", aliceConn, "SEND F 9\nmessage 3") #> ("17", aliceConn, A.MID 8 pq)
  bob <#= \case ("", cId, MERR 8 (SMP _ AUTH)) -> cId == aliceConn; _ -> False
  alice #: ("6", bobConn, "DEL") #> ("6", bobConn, OK)
  alice #:# "nothing else should be delivered to alice"

testContactConnection :: Transport c => (c, InitialKeys) -> (c, PQSupport) -> (c, PQSupport) -> IO ()
testContactConnection (alice, aPQ) (bob, bPQ) (tom, tPQ) = do
  ("1", "alice_contact", Right (INV cReq)) <- alice #: ("1", "alice_contact", "NEW T CON" <> pqConnModeStr aPQ <> " subscribe")
  let cReq' = strEncode cReq
      abPQ = pqConnectionMode aPQ bPQ
      aPQMode = CR.connPQEncryption aPQ

  bob #: ("11", "alice", "JOIN T " <> cReq' <> enableKEMStr bPQ <> " subscribe 14\nbob's connInfo") #> ("11", "alice", OK)
  ("", "alice_contact", Right (A.REQ aInvId PQSupportOn _ "bob's connInfo")) <- (alice <#:)
  alice #: ("2", "bob", "ACPT " <> aInvId <> enableKEMStr aPQMode <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  ("", "alice", Right (A.CONF bConfId pqSup'' _ "alice's connInfo")) <- (bob <#:)
  pqSup'' `shouldBe` bPQ
  bob #: ("12", "alice", "LET " <> bConfId <> " 16\nbob's connInfo 2") #> ("12", "alice", OK)
  alice <# ("", "bob", A.INFO (CR.connPQEncryption aPQ) "bob's connInfo 2")
  alice <# ("", "bob", CON abPQ)
  bob <# ("", "alice", CON abPQ)
  alice #: ("3", "bob", "SEND F :hi") #> ("3", "bob", A.MID 4 abPQ)
  alice <# ("", "bob", SENT 4)
  bob <#= \case ("", "alice", Msg' 4 pq' "hi") -> pq' == abPQ; _ -> False
  bob #: ("13", "alice", "ACK 4") #> ("13", "alice", OK)

  let atPQ = pqConnectionMode aPQ tPQ
  tom #: ("21", "alice", "JOIN T " <> cReq' <> enableKEMStr tPQ <> " subscribe 14\ntom's connInfo") #> ("21", "alice", OK)
  ("", "alice_contact", Right (A.REQ aInvId' PQSupportOn _ "tom's connInfo")) <- (alice <#:)
  alice #: ("4", "tom", "ACPT " <> aInvId' <> enableKEMStr aPQMode <> " 16\nalice's connInfo") #> ("4", "tom", OK)
  ("", "alice", Right (A.CONF tConfId pqSup4 _ "alice's connInfo")) <- (tom <#:)
  pqSup4 `shouldBe` tPQ
  tom #: ("22", "alice", "LET " <> tConfId <> " 16\ntom's connInfo 2") #> ("22", "alice", OK)
  alice <# ("", "tom", A.INFO (CR.connPQEncryption aPQ) "tom's connInfo 2")
  alice <# ("", "tom", CON atPQ)
  tom <# ("", "alice", CON atPQ)
  alice #: ("5", "tom", "SEND F :hi there") #> ("5", "tom", A.MID 4 atPQ)
  alice <# ("", "tom", SENT 4)
  tom <#= \case ("", "alice", Msg' 4 pq' "hi there") -> pq' == atPQ; _ -> False
  tom #: ("23", "alice", "ACK 4") #> ("23", "alice", OK)

testContactConnRandomIds :: Transport c => (c, InitialKeys) -> (c, PQSupport) -> IO ()
testContactConnRandomIds (alice, aPQ) (bob, bPQ) = do
  let pq = pqConnectionMode aPQ bPQ
  ("1", aliceContact, Right (INV cReq)) <- alice #: ("1", "", "NEW T CON" <> pqConnModeStr aPQ <> " subscribe")
  let cReq' = strEncode cReq

  ("11", aliceConn, Right OK) <- bob #: ("11", "", "JOIN T " <> cReq' <> enableKEMStr bPQ <> " subscribe 14\nbob's connInfo")
  ("", aliceContact', Right (A.REQ aInvId PQSupportOn _ "bob's connInfo")) <- (alice <#:)
  aliceContact' `shouldBe` aliceContact

  ("2", bobConn, Right OK) <- alice #: ("2", "", "ACPT " <> aInvId <> enableKEMStr (CR.connPQEncryption aPQ) <> " 16\nalice's connInfo")
  ("", aliceConn', Right (A.CONF bConfId pqSup'' _ "alice's connInfo")) <- (bob <#:)
  pqSup'' `shouldBe` bPQ
  aliceConn' `shouldBe` aliceConn

  bob #: ("12", aliceConn, "LET " <> bConfId <> " 16\nbob's connInfo 2") #> ("12", aliceConn, OK)
  alice <# ("", bobConn, A.INFO (CR.connPQEncryption aPQ) "bob's connInfo 2")
  alice <# ("", bobConn, CON pq)
  bob <# ("", aliceConn, CON pq)

  alice #: ("3", bobConn, "SEND F :hi") #> ("3", bobConn, A.MID 4 pq)
  alice <# ("", bobConn, SENT 4)
  bob <#= \case ("", c, Msg' 4 pq' "hi") -> c == aliceConn && pq == pq'; _ -> False
  bob #: ("13", aliceConn, "ACK 4") #> ("13", aliceConn, OK)

testRejectContactRequest :: Transport c => TProxy c -> c -> c -> IO ()
testRejectContactRequest _ alice bob = do
  ("1", "a_contact", Right (INV cReq)) <- alice #: ("1", "a_contact", "NEW T CON subscribe")
  let cReq' = strEncode cReq
  bob #: ("11", "alice", "JOIN T " <> cReq' <> " subscribe 10\nbob's info") #> ("11", "alice", OK)
  ("", "a_contact", Right (A.REQ aInvId PQSupportOn _ "bob's info")) <- (alice <#:)
  -- RJCT must use correct contact connection
  alice #: ("2a", "bob", "RJCT " <> aInvId) #> ("2a", "bob", ERR $ CONN NOT_FOUND)
  alice #: ("2b", "a_contact", "RJCT " <> aInvId) #> ("2b", "a_contact", OK)
  alice #: ("3", "bob", "ACPT " <> aInvId <> " 12\nalice's info") =#> \case ("3", "bob", ERR (A.CMD PROHIBITED _)) -> True; _ -> False
  bob #:# "nothing should be delivered to bob"

testSubscription :: Transport c => TProxy c -> c -> c -> c -> IO ()
testSubscription _ alice1 alice2 bob = do
  (alice1, "alice") `connect` (bob, "bob")
  bob #: ("12", "alice", "SEND F 5\nhello") #> ("12", "alice", MID 4)
  bob <# ("", "alice", SENT 4)
  alice1 <#= \case ("", "bob", Msg "hello") -> True; _ -> False
  alice1 #: ("1", "bob", "ACK 4") #> ("1", "bob", OK)
  bob #: ("13", "alice", "SEND F 11\nhello again") #> ("13", "alice", MID 5)
  bob <# ("", "alice", SENT 5)
  alice1 <#= \case ("", "bob", Msg "hello again") -> True; _ -> False
  alice1 #: ("2", "bob", "ACK 5") #> ("2", "bob", OK)
  alice2 #: ("21", "bob", "SUB") #> ("21", "bob", OK)
  alice1 <# ("", "bob", END)
  bob #: ("14", "alice", "SEND F 2\nhi") #> ("14", "alice", MID 6)
  bob <# ("", "alice", SENT 6)
  alice2 <#= \case ("", "bob", Msg "hi") -> True; _ -> False
  alice2 #: ("22", "bob", "ACK 6") #> ("22", "bob", OK)
  alice1 #:# "nothing else should be delivered to alice1"

testSubscrNotification :: Transport c => TProxy c -> (ThreadId, ThreadId) -> c -> IO ()
testSubscrNotification t (server, _) client = do
  client #: ("1", "conn1", "NEW T INV subscribe") =#> \case ("1", "conn1", INV {}) -> True; _ -> False
  client #:# "nothing should be delivered to client before the server is killed"
  killThread server
  client <#. ("", "", DOWN testSMPServer ["conn1"])
  withSmpServer (ATransport t) $
    client <#= \case ("", "conn1", ERR (SMP _ AUTH)) -> True; _ -> False -- this new server does not have the queue

testMsgDeliveryServerRestart :: forall c. Transport c => (c, InitialKeys) -> (c, PQSupport) -> IO ()
testMsgDeliveryServerRestart (alice, aPQ) (bob, bPQ) = do
  let pq = pqConnectionMode aPQ bPQ
  withServer $ do
    connect' (alice, "alice", aPQ) (bob, "bob", bPQ)
    bob #: ("1", "alice", "SEND F 2\nhi") #> ("1", "alice", A.MID 4 pq)
    bob <# ("", "alice", SENT 4)
    alice <#= \case ("", "bob", Msg' _ pq' "hi") -> pq == pq'; _ -> False
    alice #: ("11", "bob", "ACK 4") #> ("11", "bob", OK)
    alice #:# "nothing else delivered before the server is killed"

  let server = SMPServer "localhost" testPort2 testKeyHash
  alice <#. ("", "", DOWN server ["bob"])
  bob #: ("2", "alice", "SEND F 11\nhello again") #> ("2", "alice", A.MID 5 pq)
  bob #:# "nothing else delivered before the server is restarted"
  alice #:# "nothing else delivered before the server is restarted"

  withServer $ do
    bob <# ("", "alice", SENT 5)
    alice <#. ("", "", UP server ["bob"])
    alice <#= \case ("", "bob", Msg' _ pq' "hello again") -> pq == pq'; _ -> False
    alice #: ("12", "bob", "ACK 5") #> ("12", "bob", OK)

  removeFile testStoreLogFile
  where
    withServer test' = withSmpServerStoreLogOn (transport @c) testPort2 (const test') `shouldReturn` ()

testServerConnectionAfterError :: forall c. Transport c => TProxy c -> [c] -> IO ()
testServerConnectionAfterError t _ = do
  withAgent1 $ \bob -> do
    withAgent2 $ \alice -> do
      withServer $ do
        connect (bob, "bob") (alice, "alice")
      bob <#. ("", "", DOWN server ["alice"])
      alice <#. ("", "", DOWN server ["bob"])
      alice #: ("1", "bob", "SEND F 5\nhello") #> ("1", "bob", MID 4)
      alice #:# "nothing else delivered before the server is restarted"
      bob #:# "nothing else delivered before the server is restarted"

  withAgent1 $ \bob -> do
    withAgent2 $ \alice -> do
      bob #:! ("1", "alice", "SUB") =#> \case ("1", "alice", ERR (BROKER _ e)) -> e == NETWORK || e == TIMEOUT; _ -> False
      alice #:! ("1", "bob", "SUB") =#> \case ("1", "bob", ERR (BROKER _ e)) -> e == NETWORK || e == TIMEOUT; _ -> False
      withServer $ do
        alice <#=? \case ("", "bob", APC SAEConn (SENT 4)) -> True; ("", "", APC _ (UP s ["bob"])) -> s == server; _ -> False
        alice <#=? \case ("", "bob", APC SAEConn (SENT 4)) -> True; ("", "", APC _ (UP s ["bob"])) -> s == server; _ -> False
        bob <#=? \case ("", "alice", APC _ (Msg "hello")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
        bob <#=? \case ("", "alice", APC _ (Msg "hello")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
        bob #: ("2", "alice", "ACK 4") #> ("2", "alice", OK)
        alice #: ("1", "bob", "SEND F 11\nhello again") #> ("1", "bob", MID 5)
        alice <# ("", "bob", SENT 5)
        bob <#= \case ("", "alice", Msg "hello again") -> True; _ -> False

  removeFile testStoreLogFile
  removeFile testDB
  removeFile testDB2
  where
    server = SMPServer "localhost" testPort2 testKeyHash
    withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()
    withAgent1 = withAgent agentTestPort testDB 0
    withAgent2 = withAgent agentTestPort2 testDB2 10
    withAgent :: String -> FilePath -> Int -> (c -> IO a) -> IO a
    withAgent agentPort agentDB initClientId = withSmpAgentThreadOn_ (ATransport t) (agentPort, testPort2, agentDB) initClientId (pure ()) . const . testSMPAgentClientOn agentPort

testMsgDeliveryAgentRestart :: Transport c => TProxy c -> c -> IO ()
testMsgDeliveryAgentRestart t bob = do
  let server = SMPServer "localhost" testPort2 testKeyHash
  withAgent $ \alice -> do
    withServer $ do
      connect (bob, "bob") (alice, "alice")
      alice #: ("1", "bob", "SEND F 5\nhello") #> ("1", "bob", MID 4)
      alice <# ("", "bob", SENT 4)
      bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
      bob #: ("11", "alice", "ACK 4") #> ("11", "alice", OK)
      bob #:# "nothing else delivered before the server is down"

    bob <#. ("", "", DOWN server ["alice"])
    alice #: ("2", "bob", "SEND F 11\nhello again") #> ("2", "bob", MID 5)
    alice #:# "nothing else delivered before the server is restarted"
    bob #:# "nothing else delivered before the server is restarted"

  withAgent $ \alice -> do
    withServer $ do
      tPutRaw alice ("3", "bob", "SUB")
      alice <#= \case
        (corrId, "bob", cmd) ->
          (corrId == "3" && cmd == OK)
            || (corrId == "" && cmd == SENT 5)
        _ -> False
      bob <#=? \case ("", "alice", APC _ (Msg "hello again")) -> True; _ -> False
      bob #: ("12", "alice", "ACK 5") #> ("12", "alice", OK)

  removeFile testStoreLogFile
  removeFile testDB
  where
    withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()
    withAgent = withSmpAgentThreadOn_ (ATransport t) (agentTestPort, testPort, testDB) 0 (pure ()) . const . testSMPAgentClientOn agentTestPort

testConcurrentMsgDelivery :: Transport c => TProxy c -> c -> c -> IO ()
testConcurrentMsgDelivery _ alice bob = do
  connect (alice, "alice") (bob, "bob")

  ("1", "bob2", Right (INV cReq)) <- alice #: ("1", "bob2", "NEW T INV subscribe")
  let cReq' = strEncode cReq
  bob #: ("11", "alice2", "JOIN T " <> cReq' <> " subscribe 14\nbob's connInfo") #> ("11", "alice2", OK)
  ("", "bob2", Right (A.CONF _confId PQSupportOff _ "bob's connInfo")) <- (alice <#:)
  -- below commands would be needed to accept bob's connection, but alice does not
  -- alice #: ("2", "bob", "LET " <> _confId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
  -- bob <# ("", "alice", INFO "alice's connInfo")
  -- bob <# ("", "alice", CON)
  -- alice <# ("", "bob", CON)

  -- the first connection should not be blocked by the second one
  sendMessage (alice, "alice") (bob, "bob") "hello"
  -- alice #: ("2", "bob", "SEND F :hello") #> ("2", "bob", MID 1)
  -- alice <# ("", "bob", SENT 1)
  -- bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
  -- bob #: ("12", "alice", "ACK 1") #> ("12", "alice", OK)
  bob #: ("14", "alice", "SEND F 9\nhello too") #> ("14", "alice", MID 5)
  bob <# ("", "alice", SENT 5)
  -- if delivery is blocked it won't go further
  alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
  alice #: ("3", "bob", "ACK 5") #> ("3", "bob", OK)

testMsgDeliveryQuotaExceeded :: Transport c => TProxy c -> c -> c -> IO ()
testMsgDeliveryQuotaExceeded _ alice bob = do
  connect (alice, "alice") (bob, "bob")
  connect (alice, "alice2") (bob, "bob2")
  forM_ [1 .. 4 :: Int] $ \i -> do
    let corrId = bshow i
        msg = "message " <> bshow i
    (_, "bob", Right (MID mId)) <- alice #: (corrId, "bob", "SEND F :" <> msg)
    alice <#= \case ("", "bob", SENT m) -> m == mId; _ -> False
  (_, "bob", Right (MID _)) <- alice #: ("5", "bob", "SEND F :over quota")
  alice <#= \case ("", "bob", MWARN _ (SMP _ QUOTA)) -> True; _ -> False

  alice #: ("1", "bob2", "SEND F :hello") #> ("1", "bob2", MID 4)
  -- if delivery is blocked it won't go further
  alice <# ("", "bob2", SENT 4)

testResumeDeliveryQuotaExceeded :: Transport c => TProxy c -> c -> c -> IO ()
testResumeDeliveryQuotaExceeded _ alice bob = do
  connect (alice, "alice") (bob, "bob")
  forM_ [1 .. 4 :: Int] $ \i -> do
    let corrId = bshow i
        msg = "message " <> bshow i
    (_, "bob", Right (MID mId)) <- alice #: (corrId, "bob", "SEND F :" <> msg)
    alice <#= \case ("", "bob", SENT m) -> m == mId; _ -> False
  ("5", "bob", Right (MID 8)) <- alice #: ("5", "bob", "SEND F :over quota")
  alice <#= \case ("", "bob", MWARN 8 (SMP _ QUOTA)) -> True; _ -> False
  alice #:# "the last message not sent yet"
  bob <#= \case ("", "alice", Msg "message 1") -> True; _ -> False
  bob #: ("1", "alice", "ACK 4") #> ("1", "alice", OK)
  alice #:# "the last message not sent"
  bob <#= \case ("", "alice", Msg "message 2") -> True; _ -> False
  bob #: ("2", "alice", "ACK 5") #> ("2", "alice", OK)
  alice #:# "the last message not sent"
  bob <#= \case ("", "alice", Msg "message 3") -> True; _ -> False
  bob #: ("3", "alice", "ACK 6") #> ("3", "alice", OK)
  alice #:# "the last message not sent"
  bob <#= \case ("", "alice", Msg "message 4") -> True; _ -> False
  bob #: ("4", "alice", "ACK 7") #> ("4", "alice", OK)
  inAnyOrder
    (tGetAgent alice)
    [ \case ("", c, Right (SENT 8)) -> c == "bob"; _ -> False,
      \case ("", c, Right QCONT) -> c == "bob"; _ -> False
    ]
  bob <#= \case ("", "alice", Msg "over quota") -> True; _ -> False
  -- message 8 is skipped because of alice agent sending "QCONT" message
  bob #: ("5", "alice", "ACK 9") #> ("5", "alice", OK)

connect :: Transport c => (c, ByteString) -> (c, ByteString) -> IO ()
connect (h1, name1) (h2, name2) = connect' (h1, name1, IKPQOn) (h2, name2, PQSupportOn)

connect' :: forall c. Transport c => (c, ByteString, InitialKeys) -> (c, ByteString, PQSupport) -> IO ()
connect' (h1, name1, pqMode1) (h2, name2, pqMode2) = do
  ("c1", _, Right (INV cReq)) <- h1 #: ("c1", name2, "NEW T INV" <> pqConnModeStr pqMode1 <> " subscribe")
  let cReq' = strEncode cReq
      pq = pqConnectionMode pqMode1 pqMode2
  h2 #: ("c2", name1, "JOIN T " <> cReq' <> enableKEMStr pqMode2 <> " subscribe 5\ninfo2") #> ("c2", name1, OK)
  ("", _, Right (A.CONF connId pqSup' _ "info2")) <- (h1 <#:)
  pqSup' `shouldBe` CR.connPQEncryption pqMode1
  h1 #: ("c3", name2, "LET " <> connId <> " 5\ninfo1") #> ("c3", name2, OK)
  h2 <# ("", name1, A.INFO pqMode2 "info1")
  h2 <# ("", name1, CON pq)
  h1 <# ("", name2, CON pq)

pqConnectionMode :: InitialKeys -> PQSupport -> PQEncryption
pqConnectionMode pqMode1 pqMode2 = PQEncryption $ supportPQ (CR.connPQEncryption pqMode1) && supportPQ pqMode2

enableKEMStr :: PQSupport -> ByteString
enableKEMStr PQSupportOn = " " <> strEncode PQSupportOn
enableKEMStr _ = ""

pqConnModeStr :: InitialKeys -> ByteString
pqConnModeStr (IKNoPQ PQSupportOff) = ""
pqConnModeStr pq = " " <> strEncode pq

sendMessage :: Transport c => (c, ConnId) -> (c, ConnId) -> ByteString -> IO ()
sendMessage (h1, name1) (h2, name2) msg = do
  ("m1", name2', Right (MID mId)) <- h1 #: ("m1", name2, "SEND F :" <> msg)
  name2' `shouldBe` name2
  h1 <#= \case ("", n, SENT m) -> n == name2 && m == mId; _ -> False
  ("", name1', Right (MSG MsgMeta {recipient = (msgId', _)} _ msg')) <- (h2 <#:)
  name1' `shouldBe` name1
  msg' `shouldBe` msg
  h2 #: ("m2", name1, "ACK " <> bshow msgId') =#> \case ("m2", n, OK) -> n == name1; _ -> False

-- connect' :: forall c. Transport c => c -> c -> IO (ByteString, ByteString)
-- connect' h1 h2 = do
--   ("c1", conn2, Right (INV cReq)) <- h1 #: ("c1", "", "NEW T INV subscribe")
--   let cReq' = strEncode cReq
--   ("c2", conn1, Right OK) <- h2 #: ("c2", "", "JOIN T " <> cReq' <> " subscribe 5\ninfo2")
--   ("", _, Right (REQ connId _ "info2")) <- (h1 <#:)
--   h1 #: ("c3", conn2, "ACPT " <> connId <> " 5\ninfo1") =#> \case ("c3", c, OK) -> c == conn2; _ -> False
--   h2 <# ("", conn1, INFO "info1")
--   h2 <# ("", conn1, CON)
--   h1 <# ("", conn2, CON)
--   pure (conn1, conn2)

sampleDhKey :: ByteString
sampleDhKey = "MCowBQYDK2VuAyEAjiswwI3O_NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

syntaxTests :: forall c. Transport c => TProxy c -> Spec
syntaxTests t = do
  it "unknown command" $ ("1", "5678", "HELLO") >#> ("1", "5678", "ERR CMD SYNTAX parseCommand")
  describe "NEW" $ do
    describe "valid" $ do
      it "with correct parameter" $ ("211", "", "NEW T INV subscribe") >#>= \case ("211", _, "INV" : _) -> True; _ -> False
    describe "invalid" $ do
      it "with incorrect parameter" $ ("222", "", "NEW T hi subscribe") >#> ("222", "", "ERR CMD SYNTAX parseCommand")

  describe "JOIN" $ do
    describe "valid" $ do
      it "using same server as in invitation" $
        ( "311",
          "a",
          "JOIN T https://simpex.chat/invitation#/?smp=smp%3A%2F%2F"
            <> urlEncode True "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="
            <> "%40localhost%3A5001%2F3456-w%3D%3D%23"
            <> urlEncode True sampleDhKey
            <> "&v=2"
            <> "&e2e=v%3D2%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> " subscribe "
            <> "14\nbob's connInfo"
        )
          >#> ("311", "a", "ERR SMP smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:5001 AUTH")
    describe "invalid" $ do
      it "no parameters" $ ("321", "", "JOIN") >#> ("321", "", "ERR CMD SYNTAX parseCommand")
  where
    -- simple test for one command with the expected response
    (>#>) :: ARawTransmission -> ARawTransmission -> Expectation
    command >#> response = withFrozenCallStack $ smpAgentTest t command `shouldReturn` response

    -- simple test for one command with a predicate for the expected response
    (>#>=) :: ARawTransmission -> ((ByteString, ByteString, [ByteString]) -> Bool) -> Expectation
    command >#>= p = withFrozenCallStack $ smpAgentTest t command >>= (`shouldSatisfy` p . \(cId, connId, cmd) -> (cId, connId, B.words cmd))
