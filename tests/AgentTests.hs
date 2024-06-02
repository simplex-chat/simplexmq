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
import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.MigrationTests (migrationTests)
import AgentTests.NotificationTests (notificationTests)
import AgentTests.SQLiteTests (storeTests)
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "Notification tests" $ notificationTests (ATransport t)
  describe "SQLite store" storeTests
  describe "Migration tests" migrationTests

-- describe "Establishing connections via `contact connection`" $ do
--   describe "should connect via contact connection with one server and 3 agents" $ do
--     pqMatrix3 t smpAgentTest3 testContactConnection
--   it "should support rejecting contact request" $ do
--     smpAgentTest2_2_1 $ testRejectContactRequest t
-- describe "Message delivery and server reconnection" $ do
--   describe "should deliver messages after losing server connection and re-connecting" $
--     pqMatrix2 t smpAgentTest2_2_2_needs_server testMsgDeliveryServerRestart
--   it "should connect to the server when server goes up if it initially was down" $ do
--     smpAgentTestN [] $ testServerConnectionAfterError t
--   it "should deliver pending messages after agent restarting" $ do
--     smpAgentTest1_1_1 $ testMsgDeliveryAgentRestart t
--   it "should concurrently deliver messages to connections without blocking" $ do
--     smpAgentTest2_2_1 $ testConcurrentMsgDelivery t
--   it "should deliver messages if one of connections has quota exceeded" $ do
--     smpAgentTest2_2_1 $ testMsgDeliveryQuotaExceeded t
--   it "should resume delivering messages after exceeding quota once all messages are received" $ do
--     smpAgentTest2_2_1 $ testResumeDeliveryQuotaExceeded t

-- pqMatrix3 ::
--   HasCallStack =>
--   TProxy c ->
--   (HasCallStack => (c -> c -> c -> IO ()) -> Expectation) ->
--   (HasCallStack => (c, InitialKeys) -> (c, PQSupport) -> (c, PQSupport) -> IO ()) ->
--   Spec
-- pqMatrix3 _ smpTest test = do
--   it "dh" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOff) (c, PQSupportOff)
--   it "dh/dh/pq" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOff) (c, PQSupportOn)
--   it "dh/pq/dh" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOn) (c, PQSupportOff)
--   it "dh/pq/pq" $ smpTest $ \a b c -> test (a, IKPQOff) (b, PQSupportOn) (c, PQSupportOn)
--   it "pq/dh/dh" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOff) (c, PQSupportOff)
--   it "pq/dh/pq" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOff) (c, PQSupportOn)
--   it "pq/pq/dh" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOn) (c, PQSupportOff)
--   it "pq" $ smpTest $ \a b c -> test (a, IKPQOn) (b, PQSupportOn) (c, PQSupportOn)

-- testContactConnection :: Transport c => (c, InitialKeys) -> (c, PQSupport) -> (c, PQSupport) -> IO ()
-- testContactConnection (alice, aPQ) (bob, bPQ) (tom, tPQ) = do
--   ("1", "alice_contact", Right (INV cReq)) <- alice #: ("1", "alice_contact", "NEW T CON" <> pqConnModeStr aPQ <> " subscribe")
--   let cReq' = strEncode cReq
--       abPQ = pqConnectionMode aPQ bPQ
--       aPQMode = CR.connPQEncryption aPQ

--   bob #: ("11", "alice", "JOIN T " <> cReq' <> enableKEMStr bPQ <> " subscribe 14\nbob's connInfo") #> ("11", "alice", OK)
--   ("", "alice_contact", Right (A.REQ aInvId PQSupportOn _ "bob's connInfo")) <- (alice <#:)
--   alice #: ("2", "bob", "ACPT " <> aInvId <> enableKEMStr aPQMode <> " 16\nalice's connInfo") #> ("2", "bob", OK)
--   ("", "alice", Right (A.CONF bConfId pqSup'' _ "alice's connInfo")) <- (bob <#:)
--   pqSup'' `shouldBe` bPQ
--   bob #: ("12", "alice", "LET " <> bConfId <> " 16\nbob's connInfo 2") #> ("12", "alice", OK)
--   alice <# ("", "bob", A.INFO (CR.connPQEncryption aPQ) "bob's connInfo 2")
--   alice <# ("", "bob", CON abPQ)
--   bob <# ("", "alice", CON abPQ)
--   alice #: ("3", "bob", "SEND F :hi") #> ("3", "bob", A.MID 4 abPQ)
--   alice <# ("", "bob", SENT 4)
--   bob <#= \case ("", "alice", Msg' 4 pq' "hi") -> pq' == abPQ; _ -> False
--   bob #: ("13", "alice", "ACK 4") #> ("13", "alice", OK)

--   let atPQ = pqConnectionMode aPQ tPQ
--   tom #: ("21", "alice", "JOIN T " <> cReq' <> enableKEMStr tPQ <> " subscribe 14\ntom's connInfo") #> ("21", "alice", OK)
--   ("", "alice_contact", Right (A.REQ aInvId' PQSupportOn _ "tom's connInfo")) <- (alice <#:)
--   alice #: ("4", "tom", "ACPT " <> aInvId' <> enableKEMStr aPQMode <> " 16\nalice's connInfo") #> ("4", "tom", OK)
--   ("", "alice", Right (A.CONF tConfId pqSup4 _ "alice's connInfo")) <- (tom <#:)
--   pqSup4 `shouldBe` tPQ
--   tom #: ("22", "alice", "LET " <> tConfId <> " 16\ntom's connInfo 2") #> ("22", "alice", OK)
--   alice <# ("", "tom", A.INFO (CR.connPQEncryption aPQ) "tom's connInfo 2")
--   alice <# ("", "tom", CON atPQ)
--   tom <# ("", "alice", CON atPQ)
--   alice #: ("5", "tom", "SEND F :hi there") #> ("5", "tom", A.MID 4 atPQ)
--   alice <# ("", "tom", SENT 4)
--   tom <#= \case ("", "alice", Msg' 4 pq' "hi there") -> pq' == atPQ; _ -> False
--   tom #: ("23", "alice", "ACK 4") #> ("23", "alice", OK)

-- testRejectContactRequest :: Transport c => TProxy c -> c -> c -> IO ()
-- testRejectContactRequest _ alice bob = do
--   ("1", "a_contact", Right (INV cReq)) <- alice #: ("1", "a_contact", "NEW T CON subscribe")
--   let cReq' = strEncode cReq
--   bob #: ("11", "alice", "JOIN T " <> cReq' <> " subscribe 10\nbob's info") #> ("11", "alice", OK)
--   ("", "a_contact", Right (A.REQ aInvId PQSupportOn _ "bob's info")) <- (alice <#:)
--   -- RJCT must use correct contact connection
--   alice #: ("2a", "bob", "RJCT " <> aInvId) #> ("2a", "bob", ERR $ CONN NOT_FOUND)
--   alice #: ("2b", "a_contact", "RJCT " <> aInvId) #> ("2b", "a_contact", OK)
--   alice #: ("3", "bob", "ACPT " <> aInvId <> " 12\nalice's info") =#> \case ("3", "bob", ERR (A.CMD PROHIBITED _)) -> True; _ -> False
--   bob #:# "nothing should be delivered to bob"

-- testMsgDeliveryServerRestart :: forall c. Transport c => (c, InitialKeys) -> (c, PQSupport) -> IO ()
-- testMsgDeliveryServerRestart (alice, aPQ) (bob, bPQ) = do
--   let pq = pqConnectionMode aPQ bPQ
--   withServer $ do
--     connect' (alice, "alice", aPQ) (bob, "bob", bPQ)
--     bob #: ("1", "alice", "SEND F 2\nhi") #> ("1", "alice", A.MID 4 pq)
--     bob <# ("", "alice", SENT 4)
--     alice <#= \case ("", "bob", Msg' _ pq' "hi") -> pq == pq'; _ -> False
--     alice #: ("11", "bob", "ACK 4") #> ("11", "bob", OK)
--     alice #:# "nothing else delivered before the server is killed"

--   let server = SMPServer "localhost" testPort2 testKeyHash
--   alice <#. ("", "", DOWN server ["bob"])
--   bob #: ("2", "alice", "SEND F 11\nhello again") #> ("2", "alice", A.MID 5 pq)
--   bob #:# "nothing else delivered before the server is restarted"
--   alice #:# "nothing else delivered before the server is restarted"

--   withServer $ do
--     bob <# ("", "alice", SENT 5)
--     alice <#. ("", "", UP server ["bob"])
--     alice <#= \case ("", "bob", Msg' _ pq' "hello again") -> pq == pq'; _ -> False
--     alice #: ("12", "bob", "ACK 5") #> ("12", "bob", OK)

--   removeFile testStoreLogFile
--   where
--     withServer test' = withSmpServerStoreLogOn (transport @c) testPort2 (const test') `shouldReturn` ()

-- testServerConnectionAfterError :: forall c. Transport c => TProxy c -> [c] -> IO ()
-- testServerConnectionAfterError t _ = do
--   withAgent1 $ \bob -> do
--     withAgent2 $ \alice -> do
--       withServer $ do
--         connect (bob, "bob") (alice, "alice")
--       bob <#. ("", "", DOWN server ["alice"])
--       alice <#. ("", "", DOWN server ["bob"])
--       alice #: ("1", "bob", "SEND F 5\nhello") #> ("1", "bob", MID 4)
--       alice #:# "nothing else delivered before the server is restarted"
--       bob #:# "nothing else delivered before the server is restarted"

--   withAgent1 $ \bob -> do
--     withAgent2 $ \alice -> do
--       bob #:! ("1", "alice", "SUB") =#> \case ("1", "alice", ERR (BROKER _ e)) -> e == NETWORK || e == TIMEOUT; _ -> False
--       alice #:! ("1", "bob", "SUB") =#> \case ("1", "bob", ERR (BROKER _ e)) -> e == NETWORK || e == TIMEOUT; _ -> False
--       withServer $ do
--         alice <#=? \case ("", "bob", APC SAEConn (SENT 4)) -> True; ("", "", APC _ (UP s ["bob"])) -> s == server; _ -> False
--         alice <#=? \case ("", "bob", APC SAEConn (SENT 4)) -> True; ("", "", APC _ (UP s ["bob"])) -> s == server; _ -> False
--         bob <#=? \case ("", "alice", APC _ (Msg "hello")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
--         bob <#=? \case ("", "alice", APC _ (Msg "hello")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
--         bob #: ("2", "alice", "ACK 4") #> ("2", "alice", OK)
--         alice #: ("1", "bob", "SEND F 11\nhello again") #> ("1", "bob", MID 5)
--         alice <# ("", "bob", SENT 5)
--         bob <#= \case ("", "alice", Msg "hello again") -> True; _ -> False

--   removeFile testStoreLogFile
--   removeFile testDB
--   removeFile testDB2
--   where
--     server = SMPServer "localhost" testPort2 testKeyHash
--     withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()
--     withAgent1 = withAgent agentTestPort testDB 0
--     withAgent2 = withAgent agentTestPort2 testDB2 10
--     withAgent :: String -> FilePath -> Int -> (c -> IO a) -> IO a
--     withAgent agentPort agentDB initClientId = withSmpAgentThreadOn_ (ATransport t) (agentPort, testPort2, agentDB) initClientId (pure ()) . const . testSMPAgentClientOn agentPort

-- testMsgDeliveryAgentRestart :: Transport c => TProxy c -> c -> IO ()
-- testMsgDeliveryAgentRestart t bob = do
--   let server = SMPServer "localhost" testPort2 testKeyHash
--   withAgent $ \alice -> do
--     withServer $ do
--       connect (bob, "bob") (alice, "alice")
--       alice #: ("1", "bob", "SEND F 5\nhello") #> ("1", "bob", MID 4)
--       alice <# ("", "bob", SENT 4)
--       bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
--       bob #: ("11", "alice", "ACK 4") #> ("11", "alice", OK)
--       bob #:# "nothing else delivered before the server is down"

--     bob <#. ("", "", DOWN server ["alice"])
--     alice #: ("2", "bob", "SEND F 11\nhello again") #> ("2", "bob", MID 5)
--     alice #:# "nothing else delivered before the server is restarted"
--     bob #:# "nothing else delivered before the server is restarted"

--   withAgent $ \alice -> do
--     withServer $ do
--       tPutRaw alice ("3", "bob", "SUB")
--       alice <#= \case
--         (corrId, "bob", cmd) ->
--           (corrId == "3" && cmd == OK)
--             || (corrId == "" && cmd == SENT 5)
--         _ -> False
--       bob <#=? \case ("", "alice", APC _ (Msg "hello again")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
--       bob <#=? \case ("", "alice", APC _ (Msg "hello again")) -> True; ("", "", APC _ (UP s ["alice"])) -> s == server; _ -> False
--       bob #: ("12", "alice", "ACK 5") #> ("12", "alice", OK)

--   removeFile testStoreLogFile
--   removeFile testDB
--   where
--     withServer test' = withSmpServerStoreLogOn (ATransport t) testPort2 (const test') `shouldReturn` ()
--     withAgent = withSmpAgentThreadOn_ (ATransport t) (agentTestPort, testPort, testDB) 0 (pure ()) . const . testSMPAgentClientOn agentTestPort

-- testConcurrentMsgDelivery :: Transport c => TProxy c -> c -> c -> IO ()
-- testConcurrentMsgDelivery _ alice bob = do
--   connect (alice, "alice") (bob, "bob")

--   ("1", "bob2", Right (INV cReq)) <- alice #: ("1", "bob2", "NEW T INV subscribe")
--   let cReq' = strEncode cReq
--   bob #: ("11", "alice2", "JOIN T " <> cReq' <> " subscribe 14\nbob's connInfo") #> ("11", "alice2", OK)
--   ("", "bob2", Right (A.CONF _confId PQSupportOff _ "bob's connInfo")) <- (alice <#:)
--   -- below commands would be needed to accept bob's connection, but alice does not
--   -- alice #: ("2", "bob", "LET " <> _confId <> " 16\nalice's connInfo") #> ("2", "bob", OK)
--   -- bob <# ("", "alice", INFO "alice's connInfo")
--   -- bob <# ("", "alice", CON)
--   -- alice <# ("", "bob", CON)

--   -- the first connection should not be blocked by the second one
--   sendMessage (alice, "alice") (bob, "bob") "hello"
--   -- alice #: ("2", "bob", "SEND F :hello") #> ("2", "bob", MID 1)
--   -- alice <# ("", "bob", SENT 1)
--   -- bob <#= \case ("", "alice", Msg "hello") -> True; _ -> False
--   -- bob #: ("12", "alice", "ACK 1") #> ("12", "alice", OK)
--   bob #: ("14", "alice", "SEND F 9\nhello too") #> ("14", "alice", MID 5)
--   bob <# ("", "alice", SENT 5)
--   -- if delivery is blocked it won't go further
--   alice <#= \case ("", "bob", Msg "hello too") -> True; _ -> False
--   alice #: ("3", "bob", "ACK 5") #> ("3", "bob", OK)

-- testMsgDeliveryQuotaExceeded :: Transport c => TProxy c -> c -> c -> IO ()
-- testMsgDeliveryQuotaExceeded _ alice bob = do
--   connect (alice, "alice") (bob, "bob")
--   connect (alice, "alice2") (bob, "bob2")
--   forM_ [1 .. 4 :: Int] $ \i -> do
--     let corrId = bshow i
--         msg = "message " <> bshow i
--     (_, "bob", Right (MID mId)) <- alice #: (corrId, "bob", "SEND F :" <> msg)
--     alice <#= \case ("", "bob", SENT m) -> m == mId; _ -> False
--   (_, "bob", Right (MID _)) <- alice #: ("5", "bob", "SEND F :over quota")
--   alice <#= \case ("", "bob", MWARN _ (SMP _ QUOTA)) -> True; _ -> False

--   alice #: ("1", "bob2", "SEND F :hello") #> ("1", "bob2", MID 4)
--   -- if delivery is blocked it won't go further
--   alice <# ("", "bob2", SENT 4)

-- testResumeDeliveryQuotaExceeded :: Transport c => TProxy c -> c -> c -> IO ()
-- testResumeDeliveryQuotaExceeded _ alice bob = do
--   connect (alice, "alice") (bob, "bob")
--   forM_ [1 .. 4 :: Int] $ \i -> do
--     let corrId = bshow i
--         msg = "message " <> bshow i
--     (_, "bob", Right (MID mId)) <- alice #: (corrId, "bob", "SEND F :" <> msg)
--     alice <#= \case ("", "bob", SENT m) -> m == mId; _ -> False
--   ("5", "bob", Right (MID 8)) <- alice #: ("5", "bob", "SEND F :over quota")
--   alice <#= \case ("", "bob", MWARN 8 (SMP _ QUOTA)) -> True; _ -> False
--   alice #:# "the last message not sent yet"
--   bob <#= \case ("", "alice", Msg "message 1") -> True; _ -> False
--   bob #: ("1", "alice", "ACK 4") #> ("1", "alice", OK)
--   alice #:# "the last message not sent"
--   bob <#= \case ("", "alice", Msg "message 2") -> True; _ -> False
--   bob #: ("2", "alice", "ACK 5") #> ("2", "alice", OK)
--   alice #:# "the last message not sent"
--   bob <#= \case ("", "alice", Msg "message 3") -> True; _ -> False
--   bob #: ("3", "alice", "ACK 6") #> ("3", "alice", OK)
--   alice #:# "the last message not sent"
--   bob <#= \case ("", "alice", Msg "message 4") -> True; _ -> False
--   bob #: ("4", "alice", "ACK 7") #> ("4", "alice", OK)
--   inAnyOrder
--     (tGetAgent alice)
--     [ \case ("", c, Right (SENT 8)) -> c == "bob"; _ -> False,
--       \case ("", c, Right QCONT) -> c == "bob"; _ -> False
--     ]
--   bob <#= \case ("", "alice", Msg "over quota") -> True; _ -> False
--   -- message 8 is skipped because of alice agent sending "QCONT" message
--   bob #: ("5", "alice", "ACK 9") #> ("5", "alice", OK)

-- connect :: Transport c => (c, ByteString) -> (c, ByteString) -> IO ()
-- connect (h1, name1) (h2, name2) = connect' (h1, name1, IKPQOn) (h2, name2, PQSupportOn)

-- connect' :: forall c. Transport c => (c, ByteString, InitialKeys) -> (c, ByteString, PQSupport) -> IO ()
-- connect' (h1, name1, pqMode1) (h2, name2, pqMode2) = do
--   ("c1", _, Right (INV cReq)) <- h1 #: ("c1", name2, "NEW T INV" <> pqConnModeStr pqMode1 <> " subscribe")
--   let cReq' = strEncode cReq
--       pq = pqConnectionMode pqMode1 pqMode2
--   h2 #: ("c2", name1, "JOIN T " <> cReq' <> enableKEMStr pqMode2 <> " subscribe 5\ninfo2") #> ("c2", name1, OK)
--   ("", _, Right (A.CONF connId pqSup' _ "info2")) <- (h1 <#:)
--   pqSup' `shouldBe` CR.connPQEncryption pqMode1
--   h1 #: ("c3", name2, "LET " <> connId <> " 5\ninfo1") #> ("c3", name2, OK)
--   h2 <# ("", name1, A.INFO pqMode2 "info1")
--   h2 <# ("", name1, CON pq)
--   h1 <# ("", name2, CON pq)

-- sendMessage :: Transport c => (c, ConnId) -> (c, ConnId) -> ByteString -> IO ()
-- sendMessage (h1, name1) (h2, name2) msg = do
--   ("m1", name2', Right (MID mId)) <- h1 #: ("m1", name2, "SEND F :" <> msg)
--   name2' `shouldBe` name2
--   h1 <#= \case ("", n, SENT m) -> n == name2 && m == mId; _ -> False
--   ("", name1', Right (MSG MsgMeta {recipient = (msgId', _)} _ msg')) <- (h2 <#:)
--   name1' `shouldBe` name1
--   msg' `shouldBe` msg
--   h2 #: ("m2", name1, "ACK " <> bshow msgId') =#> \case ("m2", n, OK) -> n == name1; _ -> False

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
