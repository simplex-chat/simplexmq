{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.FunctionalAPITests
  ( functionalAPITests,
    testServerMatrix2,
    withAgentClientsCfg2,
    getSMPAgentClient',
    makeConnection,
    exchangeGreetingsMsgId,
    switchComplete,
    createConnection,
    joinConnection,
    sendMessage,
    runRight,
    runRight_,
    get,
    get',
    rfGet,
    sfGet,
    nGet,
    (##>),
    (=##>),
    pattern CON,
    pattern CONF,
    pattern INFO,
    pattern REQ,
    pattern Msg,
    pattern Msg',
    agentCfgV7,
  )
where

import AgentTests.ConnectionRequestTests (connReqData, queueAddr, testE2ERatchetParams12)
import Control.Concurrent (killThread, threadDelay)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (isRight)
import Data.Int (Int64)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map as M
import Data.Maybe (isNothing)
import qualified Data.Set as S
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Clock.System (SystemTime (..), getSystemTime)
import Data.Type.Equality
import Data.Word (Word16)
import qualified Database.SQLite.Simple as SQL
import GHC.Stack (withFrozenCallStack)
import SMPAgentClient
import SMPClient (cfg, testPort, testPort2, testStoreLogFile2, withSmpServer, withSmpServerConfigOn, withSmpServerOn, withSmpServerStoreLogOn, withSmpServerStoreMsgLogOn, withSmpServerV7)
import Simplex.Messaging.Agent hiding (createConnection, joinConnection, sendMessage)
import qualified Simplex.Messaging.Agent as A
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..))
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers (..), createAgentStore)
import Simplex.Messaging.Agent.Protocol hiding (CON, CONF, INFO, REQ)
import qualified Simplex.Messaging.Agent.Protocol as A
import Simplex.Messaging.Agent.Store.SQLite (MigrationConfirmation (..), SQLiteStore (dbNew))
import Simplex.Messaging.Agent.Store.SQLite.Common (withTransaction')
import Simplex.Messaging.Client (NetworkConfig (..), ProtocolClientConfig (..), TransportSessionMode (TSMEntity, TSMUser), defaultSMPClientConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet (InitialKeys (..), PQEncryption (..), PQSupport (..), pattern PQEncOff, pattern PQEncOn, pattern PQSupportOff, pattern PQSupportOn)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Transport (NTFVersion, authBatchCmdsNTFVersion, pattern VersionNTF)
import Simplex.Messaging.Protocol (BasicAuth, ErrorType (..), MsgBody, ProtocolServer (..), SubscriptionMode (..), supportedSMPClientVRange)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Transport (ATransport (..), SMPVersion, VersionSMP, authCmdsSMPVersion, basicAuthSMPVersion, batchCmdsSMPVersion, currentServerSMPRelayVersion)
import Simplex.Messaging.Util (atomically')
import Simplex.Messaging.Version (VersionRange (..))
import qualified Simplex.Messaging.Version as V
import Simplex.Messaging.Version.Internal (Version (..))
import System.Directory (copyFile, renameFile)
import Test.Hspec
import UnliftIO
import Util
import XFTPClient (testXFTPServer)

type AEntityTransmission e = (ACorrId, ConnId, ACommand 'Agent e)

-- deriving instance Eq (ValidFileDescription p)

(##>) :: (HasCallStack, MonadUnliftIO m) => m (AEntityTransmission e) -> AEntityTransmission e -> m ()
a ##> t = withTimeout a (`shouldBe` t)

(=##>) :: (Show a, HasCallStack, MonadUnliftIO m) => m a -> (a -> Bool) -> m ()
a =##> p =
  withTimeout a $ \r -> do
    unless (p r) $ liftIO $ putStrLn $ "value failed predicate: " <> show r
    r `shouldSatisfy` p

withTimeout :: (HasCallStack, MonadUnliftIO m) => m a -> (a -> Expectation) -> m ()
withTimeout a test =
  timeout 10_000000 a >>= \case
    Nothing -> error "operation timed out"
    Just t -> liftIO $ test t

get :: (MonadIO m, HasCallStack) => AgentClient -> m (AEntityTransmission 'AEConn)
get c = withFrozenCallStack $ get' @'AEConn c

rfGet :: (MonadIO m, HasCallStack) => AgentClient -> m (AEntityTransmission 'AERcvFile)
rfGet c = withFrozenCallStack $ get' @'AERcvFile c

sfGet :: (MonadIO m, HasCallStack) => AgentClient -> m (AEntityTransmission 'AESndFile)
sfGet c = withFrozenCallStack $ get' @'AESndFile c

nGet :: (MonadIO m, HasCallStack) => AgentClient -> m (AEntityTransmission 'AENone)
nGet c = withFrozenCallStack $ get' @'AENone c

get' :: forall e m. (MonadIO m, AEntityI e, HasCallStack) => AgentClient -> m (AEntityTransmission e)
get' c = withFrozenCallStack $ do
  (corrId, connId, APC e cmd) <- pGet c
  case testEquality e (sAEntity @e) of
    Just Refl -> pure (corrId, connId, cmd)
    _ -> error $ "unexpected command " <> show cmd

pGet :: forall m. MonadIO m => AgentClient -> m (ATransmission 'Agent)
pGet c = do
  t@(_, _, APC _ cmd) <- atomically' (readTBQueue $ subQ c)
  case cmd of
    CONNECT {} -> pGet c
    DISCONNECT {} -> pGet c
    _ -> pure t

pattern CONF :: ConfirmationId -> [SMPServer] -> ConnInfo -> ACommand 'Agent e
pattern CONF conId srvs connInfo <- A.CONF conId PQSupportOn srvs connInfo

pattern INFO :: ConnInfo -> ACommand 'Agent 'AEConn
pattern INFO connInfo = A.INFO PQSupportOn connInfo

pattern REQ :: InvitationId -> NonEmpty SMPServer -> ConnInfo -> ACommand 'Agent e
pattern REQ invId srvs connInfo <- A.REQ invId PQSupportOn srvs connInfo

pattern CON :: ACommand 'Agent 'AEConn
pattern CON = A.CON PQEncOn

pattern Msg :: MsgBody -> ACommand 'Agent e
pattern Msg msgBody <- MSG MsgMeta {integrity = MsgOk, pqEncryption = PQEncOn} _ msgBody

pattern Msg' :: AgentMsgId -> PQEncryption -> MsgBody -> ACommand 'Agent e
pattern Msg' aMsgId pq msgBody <- MSG MsgMeta {integrity = MsgOk, recipient = (aMsgId, _), pqEncryption = pq} _ msgBody

pattern MsgErr :: AgentMsgId -> MsgErrorType -> MsgBody -> ACommand 'Agent 'AEConn
pattern MsgErr msgId err msgBody <- MSG MsgMeta {recipient = (msgId, _), integrity = MsgError err} _ msgBody

pattern MsgErr' :: AgentMsgId -> MsgErrorType -> PQEncryption -> MsgBody -> ACommand 'Agent 'AEConn
pattern MsgErr' msgId err pq msgBody <- MSG MsgMeta {recipient = (msgId, _), integrity = MsgError err, pqEncryption = pq} _ msgBody

pattern Rcvd :: AgentMsgId -> ACommand 'Agent 'AEConn
pattern Rcvd agentMsgId <- RCVD MsgMeta {integrity = MsgOk} [MsgReceipt {agentMsgId, msgRcptStatus = MROk}]

smpCfgVPrev :: ProtocolClientConfig SMPVersion
smpCfgVPrev = (smpCfg agentCfg) {serverVRange = prevRange $ serverVRange $ smpCfg agentCfg}

smpCfgV7 :: ProtocolClientConfig SMPVersion
smpCfgV7 = (smpCfg agentCfg) {serverVRange = V.mkVersionRange batchCmdsSMPVersion authCmdsSMPVersion}

ntfCfgV2 :: ProtocolClientConfig NTFVersion
ntfCfgV2 = (smpCfg agentCfg) {serverVRange = V.mkVersionRange (VersionNTF 1) authBatchCmdsNTFVersion}

agentCfgVPrev :: AgentConfig
agentCfgVPrev =
  agentCfg
    { sndAuthAlg = C.AuthAlg C.SEd25519,
      smpAgentVRange = \_ -> prevRange $ smpAgentVRange agentCfg PQSupportOff,
      smpClientVRange = prevRange $ smpClientVRange agentCfg,
      e2eEncryptVRange = \_ -> prevRange $ e2eEncryptVRange agentCfg PQSupportOff,
      smpCfg = smpCfgVPrev
    }

-- agent config for the next client version
agentCfgV7 :: AgentConfig
agentCfgV7 =
  agentCfg
    { sndAuthAlg = C.AuthAlg C.SX25519,
      smpAgentVRange = \_ -> V.mkVersionRange duplexHandshakeSMPAgentVersion $ max pqdrSMPAgentVersion currentSMPAgentVersion,
      e2eEncryptVRange = \_ -> V.mkVersionRange CR.kdfX3DHE2EEncryptVersion $ max CR.pqRatchetE2EEncryptVersion CR.currentE2EEncryptVersion,
      smpCfg = smpCfgV7,
      ntfCfg = ntfCfgV2
    }

agentCfgRatchetVPrev :: AgentConfig
agentCfgRatchetVPrev = agentCfg {e2eEncryptVRange = \_ -> prevRange $ e2eEncryptVRange agentCfg PQSupportOff}

prevRange :: VersionRange v -> VersionRange v
prevRange vr = vr {maxVersion = max (minVersion vr) (prevVersion $ maxVersion vr)}

prevVersion :: Version v -> Version v
prevVersion (Version v) = Version (v - 1)

mkVersionRange :: Word16 -> Word16 -> VersionRange v
mkVersionRange v1 v2 = V.mkVersionRange (Version v1) (Version v2)

runRight_ :: (Eq e, Show e, HasCallStack) => ExceptT e IO () -> Expectation
runRight_ action = runExceptT action `shouldReturn` Right ()

runRight :: (Show e, HasCallStack) => ExceptT e IO a -> IO a
runRight action =
  runExceptT action >>= \case
    Right x -> pure x
    Left e -> error $ "Unexpected error: " <> show e

getInAnyOrder :: HasCallStack => AgentClient -> [ATransmission 'Agent -> Bool] -> Expectation
getInAnyOrder c ts = withFrozenCallStack $ inAnyOrder (pGet c) ts

inAnyOrder :: (Show a, MonadIO m, HasCallStack) => m a -> [a -> Bool] -> m ()
inAnyOrder _ [] = pure ()
inAnyOrder g rs = withFrozenCallStack $ do
  r <- g
  let rest = filter (not . expected r) rs
  if length rest < length rs
    then inAnyOrder g rest
    else error $ "unexpected event: " <> show r
  where
    expected :: a -> (a -> Bool) -> Bool
    expected r rp = rp r

createConnection :: AgentClient -> UserId -> Bool -> SConnectionMode c -> Maybe CRClientData -> SubscriptionMode -> AE (ConnId, ConnectionRequestUri c)
createConnection c userId enableNtfs cMode clientData = A.createConnection c userId enableNtfs cMode clientData (IKNoPQ PQSupportOn)

joinConnection :: AgentClient -> UserId -> Bool -> ConnectionRequestUri c -> ConnInfo -> SubscriptionMode -> AE ConnId
joinConnection c userId enableNtfs cReq connInfo = A.joinConnection c userId enableNtfs cReq connInfo PQSupportOn

sendMessage :: AgentClient -> ConnId -> SMP.MsgFlags -> MsgBody -> AE AgentMsgId
sendMessage c connId msgFlags msgBody = do
  (msgId, pqEnc) <- A.sendMessage c connId PQEncOn msgFlags msgBody
  liftIO $ pqEnc `shouldBe` PQEncOn
  pure msgId

functionalAPITests :: ATransport -> Spec
functionalAPITests t = do
  describe "Establishing duplex connection" $ do
    testMatrix2 t runAgentClientTest
    it "should connect when server with multiple identities is stored" $
      withSmpServer t testServerMultipleIdentities
    it "should connect with two peers" $
      withSmpServer t testAgentClient3
    it "should establish connection without PQ encryption and enable it" $
      withSmpServer t testEnablePQEncryption
  describe "Establishing duplex connection v2, different Ratchet versions" $
    testRatchetMatrix2 t runAgentClientTest
  describe "Establish duplex connection via contact address" $
    testMatrix2 t runAgentClientContactTest
  describe "Establish duplex connection via contact address v2, different Ratchet versions" $
    testRatchetMatrix2 t runAgentClientContactTest
  describe "Establishing connection asynchronously" $ do
    it "should connect with initiating client going offline" $
      withSmpServer t testAsyncInitiatingOffline
    it "should connect with joining client going offline before its queue activation" $
      withSmpServer t testAsyncJoiningOfflineBeforeActivation
    it "should connect with both clients going offline" $
      withSmpServer t testAsyncBothOffline
    it "should connect on the second attempt if server was offline" $
      testAsyncServerOffline t
    it "should restore confirmation after client restart" $
      testAllowConnectionClientRestart t
  describe "Message delivery" $ do
    describe "update connection agent version on received messages" $ do
      it "should increase if compatible, shouldn't decrease" $
        testIncreaseConnAgentVersion t
      it "should increase to max compatible version" $
        testIncreaseConnAgentVersionMaxCompatible t
      it "should increase when connection was negotiated on different versions" $
        testIncreaseConnAgentVersionStartDifferentVersion t
    -- TODO PQ tests for upgrading connection to PQ encryption
    it "should deliver message after client restart" $
      testDeliverClientRestart t
    it "should deliver messages to the user once, even if repeat delivery is made by the server (no ACK)" $
      testDuplicateMessage t
    it "should report error via msg integrity on skipped messages" $
      testSkippedMessages t
    describe "message expiration" $ do
      it "should expire one message" $ testExpireMessage t
      it "should expire multiple messages" $ testExpireManyMessages t
      it "should expire one message if quota is exceeded" $ testExpireMessageQuota t
      it "should expire multiple messages if quota is exceeded" $ testExpireManyMessagesQuota t
    describe "Ratchet synchronization" $ do
      it "should report ratchet de-synchronization, synchronize ratchets" $
        testRatchetSync t
      it "should synchronize ratchets after server being offline" $
        testRatchetSyncServerOffline t
      it "should synchronize ratchets after client restart" $
        testRatchetSyncClientRestart t
      it "should synchronize ratchets after suspend/foreground" $
        testRatchetSyncSuspendForeground t
      it "should synchronize ratchets when clients start synchronization simultaneously" $
        testRatchetSyncSimultaneous t
    describe "Subscription mode OnlyCreate" $ do
      it "messages delivered only when polled" $
        withSmpServer t testOnlyCreatePull
  describe "Inactive client disconnection" $ do
    it "should disconnect clients without subs if they were inactive longer than TTL" $
      testInactiveNoSubs t
    it "should NOT disconnect inactive clients when they have subscriptions" $
      testInactiveWithSubs t
    it "should NOT disconnect active clients" $
      testActiveClientNotDisconnected t
  describe "Suspending agent" $ do
    it "should update client when agent is suspended" $
      withSmpServer t testSuspendingAgent
    it "should complete sending messages when agent is suspended" $
      testSuspendingAgentCompleteSending t
    it "should suspend agent on timeout, even if pending messages not sent" $
      testSuspendingAgentTimeout t
  describe "Batching SMP commands" $ do
    it "should subscribe to multiple (200) subscriptions with batching" $
      testBatchedSubscriptions 200 10 t
    skip "faster version of the previous test (200 subscriptions gets very slow with test coverage)" $
      it "should subscribe to multiple (6) subscriptions with batching" $
        testBatchedSubscriptions 6 3 t
  describe "Async agent commands" $ do
    it "should connect using async agent commands" $
      withSmpServer t testAsyncCommands
    it "should restore and complete async commands on restart" $
      testAsyncCommandsRestore t
    it "should accept connection using async command" $
      withSmpServer t testAcceptContactAsync
    it "should delete connections using async command when server connection fails" $
      testDeleteConnectionAsync t
    it "join connection when reply queue creation fails" $
      testJoinConnectionAsyncReplyError t
    describe "delete connection waiting for delivery" $ do
      it "should delete connection immediately if there are no pending messages" $
        testWaitDeliveryNoPending t
      it "should delete connection after waiting for delivery to complete" $
        testWaitDelivery t
      it "should delete connection if message can't be delivered due to AUTH error" $
        testWaitDeliveryAUTHErr t
      it "should delete connection by timeout even if message wasn't delivered" $
        testWaitDeliveryTimeout t
      it "should delete connection by timeout, message in progress can be delivered" $
        testWaitDeliveryTimeout2 t
  describe "Users" $ do
    it "should create and delete user with connections" $
      withSmpServer t testUsers
    it "should create and delete user without connections" $
      withSmpServer t testDeleteUserQuietly
    it "should create and delete user with connections when server connection fails" $
      testUsersNoServer t
    it "should connect two users and switch session mode" $
      withSmpServer t testTwoUsers
  describe "Connection switch" $ do
    describe "should switch delivery to the new queue" $
      testServerMatrix2 t testSwitchConnection
    describe "should switch to new queue asynchronously" $
      testServerMatrix2 t testSwitchAsync
    describe "should delete connection during switch" $
      testServerMatrix2 t testSwitchDelete
    describe "should abort switch in Started phase" $
      testServerMatrix2 t testAbortSwitchStarted
    describe "should abort switch in Started phase, reinitiate immediately" $
      testServerMatrix2 t testAbortSwitchStartedReinitiate
    describe "should prohibit to abort switch in Secured phase" $
      testServerMatrix2 t testCannotAbortSwitchSecured
    describe "should switch two connections simultaneously" $
      testServerMatrix2 t testSwitch2Connections
    describe "should switch two connections simultaneously, abort one" $
      testServerMatrix2 t testSwitch2ConnectionsAbort1
  describe "SMP basic auth" $ do
    let v4 = prevVersion basicAuthSMPVersion
    forM_ (nub [prevVersion authCmdsSMPVersion, authCmdsSMPVersion, currentServerSMPRelayVersion]) $ \v -> do
      describe ("v" <> show v <> ": with server auth") $ do
        --                                       allow NEW | server auth, v | clnt1 auth, v  | clnt2 auth, v    |  2 - success, 1 - JOIN fail, 0 - NEW fail
        it "success                " $ testBasicAuth t True (Just "abcd", v) (Just "abcd", v) (Just "abcd", v) `shouldReturn` 2
        it "disabled               " $ testBasicAuth t False (Just "abcd", v) (Just "abcd", v) (Just "abcd", v) `shouldReturn` 0
        it "NEW fail, no auth      " $ testBasicAuth t True (Just "abcd", v) (Nothing, v) (Just "abcd", v) `shouldReturn` 0
        it "NEW fail, bad auth     " $ testBasicAuth t True (Just "abcd", v) (Just "wrong", v) (Just "abcd", v) `shouldReturn` 0
        it "NEW fail, version      " $ testBasicAuth t True (Just "abcd", v) (Just "abcd", v4) (Just "abcd", v) `shouldReturn` 0
        it "JOIN fail, no auth     " $ testBasicAuth t True (Just "abcd", v) (Just "abcd", v) (Nothing, v) `shouldReturn` 1
        it "JOIN fail, bad auth    " $ testBasicAuth t True (Just "abcd", v) (Just "abcd", v) (Just "wrong", v) `shouldReturn` 1
        it "JOIN fail, version     " $ testBasicAuth t True (Just "abcd", v) (Just "abcd", v) (Just "abcd", v4) `shouldReturn` 1
      describe ("v" <> show v <> ": no server auth") $ do
        it "success     " $ testBasicAuth t True (Nothing, v) (Nothing, v) (Nothing, v) `shouldReturn` 2
        it "srv disabled" $ testBasicAuth t False (Nothing, v) (Nothing, v) (Nothing, v) `shouldReturn` 0
        it "version srv " $ testBasicAuth t True (Nothing, v4) (Nothing, v) (Nothing, v) `shouldReturn` 2
        it "version fst " $ testBasicAuth t True (Nothing, v) (Nothing, v4) (Nothing, v) `shouldReturn` 2
        it "version snd " $ testBasicAuth t True (Nothing, v) (Nothing, v) (Nothing, v4) `shouldReturn` 2
        it "version both" $ testBasicAuth t True (Nothing, v) (Nothing, v4) (Nothing, v4) `shouldReturn` 2
        it "version all " $ testBasicAuth t True (Nothing, v4) (Nothing, v4) (Nothing, v4) `shouldReturn` 2
        it "auth fst    " $ testBasicAuth t True (Nothing, v) (Just "abcd", v) (Nothing, v) `shouldReturn` 2
        it "auth fst 2  " $ testBasicAuth t True (Nothing, v4) (Just "abcd", v) (Nothing, v) `shouldReturn` 2
        it "auth snd    " $ testBasicAuth t True (Nothing, v) (Nothing, v) (Just "abcd", v) `shouldReturn` 2
        it "auth both   " $ testBasicAuth t True (Nothing, v) (Just "abcd", v) (Just "abcd", v) `shouldReturn` 2
        it "auth, disabled" $ testBasicAuth t False (Nothing, v) (Just "abcd", v) (Just "abcd", v) `shouldReturn` 0
  describe "SMP server test via agent API" $ do
    it "should pass without basic auth" $ testSMPServerConnectionTest t Nothing (noAuthSrv testSMPServer2) `shouldReturn` Nothing
    let srv1 = testSMPServer2 {keyHash = "1234"}
    it "should fail with incorrect fingerprint" $ do
      testSMPServerConnectionTest t Nothing (noAuthSrv srv1) `shouldReturn` Just (ProtocolTestFailure TSConnect $ BROKER (B.unpack $ strEncode srv1) NETWORK)
    describe "server with password" $ do
      let auth = Just "abcd"
          srv = ProtoServerWithAuth testSMPServer2
          authErr = Just (ProtocolTestFailure TSCreateQueue $ SMP AUTH)
      it "should pass with correct password" $ testSMPServerConnectionTest t auth (srv auth) `shouldReturn` Nothing
      it "should fail without password" $ testSMPServerConnectionTest t auth (srv Nothing) `shouldReturn` authErr
      it "should fail with incorrect password" $ testSMPServerConnectionTest t auth (srv $ Just "wrong") `shouldReturn` authErr
  describe "getRatchetAdHash" $
    it "should return the same data for both peers" $
      withSmpServer t testRatchetAdHash
  describe "Delivery receipts" $ do
    it "should send and receive delivery receipt" $ withSmpServer t testDeliveryReceipts
    it "should send delivery receipt only in connection v3+" $ testDeliveryReceiptsVersion t
    it "send delivery receipts concurrently with messages" $ testDeliveryReceiptsConcurrent t

testBasicAuth :: ATransport -> Bool -> (Maybe BasicAuth, VersionSMP) -> (Maybe BasicAuth, VersionSMP) -> (Maybe BasicAuth, VersionSMP) -> IO Int
testBasicAuth t allowNewQueues srv@(srvAuth, srvVersion) clnt1 clnt2 = do
  let testCfg = cfg {allowNewQueues, newQueueBasicAuth = srvAuth, smpServerVRange = V.mkVersionRange batchCmdsSMPVersion srvVersion}
      canCreate1 = canCreateQueue allowNewQueues srv clnt1
      canCreate2 = canCreateQueue allowNewQueues srv clnt2
      expected
        | canCreate1 && canCreate2 = 2
        | canCreate1 = 1
        | otherwise = 0
  created <- withSmpServerConfigOn t testCfg testPort $ \_ -> testCreateQueueAuth srvVersion clnt1 clnt2
  created `shouldBe` expected
  pure created

canCreateQueue :: Bool -> (Maybe BasicAuth, VersionSMP) -> (Maybe BasicAuth, VersionSMP) -> Bool
canCreateQueue allowNew (srvAuth, srvVersion) (clntAuth, clntVersion) =
  let v = basicAuthSMPVersion
   in allowNew && (isNothing srvAuth || (srvVersion >= v && clntVersion >= v && srvAuth == clntAuth))

testMatrix2 :: ATransport -> (PQSupport -> AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> Spec
testMatrix2 t runTest = do
  it "v7" $ withSmpServerV7 t $ runTestCfg2 agentCfgV7 agentCfgV7 3 $ runTest PQSupportOn
  it "v7 to current" $ withSmpServerV7 t $ runTestCfg2 agentCfgV7 agentCfg 3 $ runTest PQSupportOn
  it "current to v7" $ withSmpServerV7 t $ runTestCfg2 agentCfg agentCfgV7 3 $ runTest PQSupportOn
  it "current with v7 server" $ withSmpServerV7 t $ runTestCfg2 agentCfg agentCfg 3 $ runTest PQSupportOn
  it "current" $ withSmpServer t $ runTestCfg2 agentCfg agentCfg 3 $ runTest PQSupportOn
  it "prev" $ withSmpServer t $ runTestCfg2 agentCfgVPrev agentCfgVPrev 3 $ runTest PQSupportOff
  it "prev to current" $ withSmpServer t $ runTestCfg2 agentCfgVPrev agentCfg 3 $ runTest PQSupportOff
  it "current to prev" $ withSmpServer t $ runTestCfg2 agentCfg agentCfgVPrev 3 $ runTest PQSupportOff

testRatchetMatrix2 :: ATransport -> (PQSupport -> AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> Spec
testRatchetMatrix2 t runTest = do
  it "ratchet next" $ withSmpServerV7 t $ runTestCfg2 agentCfgV7 agentCfgV7 3 $ runTest PQSupportOn
  it "ratchet next to current" $ withSmpServerV7 t $ runTestCfg2 agentCfgV7 agentCfg 3 $ runTest PQSupportOn
  it "ratchet current to next" $ withSmpServerV7 t $ runTestCfg2 agentCfg agentCfgV7 3 $ runTest PQSupportOn
  it "ratchet current" $ withSmpServer t $ runTestCfg2 agentCfg agentCfg 3 $ runTest PQSupportOn
  it "ratchet prev" $ withSmpServer t $ runTestCfg2 agentCfgRatchetVPrev agentCfgRatchetVPrev 3 $ runTest PQSupportOff
  it "ratchets prev to current" $ withSmpServer t $ runTestCfg2 agentCfgRatchetVPrev agentCfg 3 $ runTest PQSupportOff
  it "ratchets current to prev" $ withSmpServer t $ runTestCfg2 agentCfg agentCfgRatchetVPrev 3 $ runTest PQSupportOff

testServerMatrix2 :: ATransport -> (InitialAgentServers -> IO ()) -> Spec
testServerMatrix2 t runTest = do
  it "1 server" $ withSmpServer t $ runTest initAgentServers
  it "2 servers" $ withSmpServer t . withSmpServerOn t testPort2 $ runTest initAgentServers2

runTestCfg2 :: AgentConfig -> AgentConfig -> AgentMsgId -> (AgentClient -> AgentClient -> AgentMsgId -> IO ()) -> IO ()
runTestCfg2 aCfg bCfg baseMsgId runTest =
  withAgentClientsCfg2 aCfg bCfg $ \a b -> runTest a b baseMsgId

withAgentClientsCfg2 :: AgentConfig -> AgentConfig -> (AgentClient -> AgentClient -> IO ()) -> IO ()
withAgentClientsCfg2 aCfg bCfg runTest = do
  a <- getSMPAgentClient' 1 aCfg initAgentServers testDB
  b <- getSMPAgentClient' 2 bCfg initAgentServers testDB2
  runTest a b
  disposeAgentClient a
  disposeAgentClient b

withAgentClients2 :: (AgentClient -> AgentClient -> IO ()) -> IO ()
withAgentClients2 = withAgentClientsCfg2 agentCfg agentCfg

runAgentClientTest :: HasCallStack => PQSupport -> AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientTest pqSupport alice@AgentClient {} bob baseId =
  runRight_ $ do
    (bobId, qInfo) <- A.createConnection alice 1 True SCMInvitation Nothing (IKNoPQ pqSupport) SMSubscribe
    aliceId <- A.joinConnection bob 1 True qInfo "bob's connInfo" pqSupport SMSubscribe
    ("", _, A.CONF confId pqSup' _ "bob's connInfo") <- get alice
    liftIO $ pqSup' `shouldBe` pqSupport
    allowConnection alice bobId confId "alice's connInfo"
    let pqEnc = CR.pqSupportToEnc pqSupport
    get alice ##> ("", bobId, A.CON pqEnc)
    get bob ##> ("", aliceId, A.INFO pqSupport "alice's connInfo")
    get bob ##> ("", aliceId, A.CON pqEnc)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> A.sendMessage alice bobId pqEnc SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> A.sendMessage alice bobId pqEnc SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg' _ pq "hello") -> c == aliceId && pq == pqEnc; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing
    get bob =##> \case ("", c, Msg' _ pq "how are you?") -> c == aliceId && pq == pqEnc; _ -> False
    ackMessage bob aliceId (baseId + 2) Nothing
    3 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg' _ pq "hello too") -> c == bobId && pq == pqEnc; _ -> False
    ackMessage alice bobId (baseId + 3) Nothing
    get alice =##> \case ("", c, Msg' _ pq "message 1") -> c == bobId && pq == pqEnc; _ -> False
    ackMessage alice bobId (baseId + 4) Nothing
    suspendConnection alice bobId
    5 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  where
    msgId = subtract baseId . fst

testEnablePQEncryption :: HasCallStack => IO ()
testEnablePQEncryption = do
  ca <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  cb <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  g <- C.newRandom
  runRight_ $ do
    (aId, bId) <- makeConnection_ PQSupportOff ca cb
    let a = (ca, aId)
        b = (cb, bId)
    (a, 4, "msg 1") \#>\ b
    (b, 5, "msg 2") \#>\ a
    -- 45 bytes is used by agent message envelope inside double ratchet message envelope
    let largeMsg g' pqEnc = atomically $ C.randomBytes (e2eEncUserMsgLength pqdrSMPAgentVersion pqEnc - 45) g'
    lrg <- largeMsg g PQSupportOff
    (a, 6, lrg) \#>\ b
    (b, 7, lrg) \#>\ a
    -- enabling PQ encryption
    (a, 8, lrg) \#>! b
    (b, 9, lrg) \#>! a
    -- switched to smaller envelopes (before reporting PQ encryption enabled)
    sml <- largeMsg g PQSupportOn
    -- fail because of message size
    Left (A.CMD LARGE) <- tryError $ A.sendMessage ca bId PQEncOn SMP.noMsgFlags lrg
    (11, PQEncOff) <- A.sendMessage ca bId PQEncOn SMP.noMsgFlags sml
    get ca =##> \case ("", connId, SENT 11) -> connId == bId; _ -> False
    get cb =##> \case ("", connId, MsgErr' 10 MsgSkipped {} PQEncOff msg') -> connId == aId && msg' == sml; _ -> False
    ackMessage cb aId 10 Nothing
    -- -- fail in reply to sync IDss
    Left (A.CMD LARGE) <- tryError $ A.sendMessage cb aId PQEncOn SMP.noMsgFlags lrg
    (12, PQEncOn) <- A.sendMessage cb aId PQEncOn SMP.noMsgFlags sml
    get cb =##> \case ("", connId, SENT 12) -> connId == aId; _ -> False
    get ca =##> \case ("", connId, MsgErr' 12 MsgSkipped {} PQEncOn msg') -> connId == bId && msg' == sml; _ -> False
    ackMessage ca bId 12 Nothing
    -- PQ encryption now enabled
    (a, 13, sml) !#>! b
    (b, 14, sml) !#>! a
    -- disabling PQ encryption
    (a, 15, sml) !#>\ b
    (b, 16, sml) !#>\ a
    (a, 17, sml) \#>\ b
    (b, 18, sml) \#>\ a
    -- enabling PQ encryption again
    (a, 19, sml) \#>! b
    (b, 20, sml) \#>! a
    (a, 21, sml) \#>! b
    (b, 22, sml) !#>! a
    (a, 23, sml) !#>! b
    -- disabling PQ encryption again
    (b, 24, sml) !#>\ a
    (a, 25, sml) !#>\ b
    (b, 26, sml) \#>\ a
    (a, 27, sml) \#>\ b
    -- PQ encryption is now disabled, but support remained enabled, so we still cannot send larger messages
    Left (A.CMD LARGE) <- tryError $ A.sendMessage ca bId PQEncOff SMP.noMsgFlags (sml <> "123456")
    Left (A.CMD LARGE) <- tryError $ A.sendMessage cb aId PQEncOff SMP.noMsgFlags (sml <> "123456")
    pure ()
  where
    (\#>\) = PQEncOff `sndRcv` PQEncOff
    (\#>!) = PQEncOff `sndRcv` PQEncOn
    (!#>!) = PQEncOn `sndRcv` PQEncOn
    (!#>\) = PQEncOn `sndRcv` PQEncOff

sndRcv :: PQEncryption -> PQEncryption -> ((AgentClient, ConnId), AgentMsgId, MsgBody) -> (AgentClient, ConnId) -> ExceptT AgentErrorType IO ()
sndRcv pqEnc pqEnc' ((c1, id1), mId, msg) (c2, id2) = do
  r <- A.sendMessage c1 id2 pqEnc' SMP.noMsgFlags msg
  liftIO $ r `shouldBe` (mId, pqEnc)
  get c1 =##> \case ("", connId, SENT mId') -> connId == id2 && mId' == mId; _ -> False
  get c2 =##> \case ("", connId, Msg' mId' pq msg') -> connId == id1 && mId' == mId && msg' == msg && pq == pqEnc; _ -> False
  ackMessage c2 id1 mId Nothing

testAgentClient3 :: HasCallStack => IO ()
testAgentClient3 = do
  a <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  c <- getSMPAgentClient' 3 agentCfg initAgentServers testDB3
  runRight_ $ do
    (aIdForB, bId) <- makeConnection a b
    (aIdForC, cId) <- makeConnection a c

    4 <- sendMessage a bId SMP.noMsgFlags "b4"
    4 <- sendMessage a cId SMP.noMsgFlags "c4"
    5 <- sendMessage a bId SMP.noMsgFlags "b5"
    5 <- sendMessage a cId SMP.noMsgFlags "c5"
    get a =##> \case ("", connId, SENT 4) -> connId == bId || connId == cId; _ -> False
    get a =##> \case ("", connId, SENT 4) -> connId == bId || connId == cId; _ -> False
    get a =##> \case ("", connId, SENT 5) -> connId == bId || connId == cId; _ -> False
    get a =##> \case ("", connId, SENT 5) -> connId == bId || connId == cId; _ -> False
    get b =##> \case ("", connId, Msg "b4") -> connId == aIdForB; _ -> False
    ackMessage b aIdForB 4 Nothing
    get b =##> \case ("", connId, Msg "b5") -> connId == aIdForB; _ -> False
    ackMessage b aIdForB 5 Nothing
    get c =##> \case ("", connId, Msg "c4") -> connId == aIdForC; _ -> False
    ackMessage c aIdForC 4 Nothing
    get c =##> \case ("", connId, Msg "c5") -> connId == aIdForC; _ -> False
    ackMessage c aIdForC 5 Nothing

runAgentClientContactTest :: HasCallStack => PQSupport -> AgentClient -> AgentClient -> AgentMsgId -> IO ()
runAgentClientContactTest pqSupport alice bob baseId =
  runRight_ $ do
    (_, qInfo) <- A.createConnection alice 1 True SCMContact Nothing (IKNoPQ pqSupport) SMSubscribe
    aliceId <- A.joinConnection bob 1 True qInfo "bob's connInfo" pqSupport SMSubscribe
    ("", _, A.REQ invId pqSup' _ "bob's connInfo") <- get alice
    liftIO $ pqSup' `shouldBe` pqSupport
    bobId <- acceptContact alice True invId "alice's connInfo" PQSupportOn SMSubscribe
    ("", _, A.CONF confId pqSup'' _ "alice's connInfo") <- get bob
    liftIO $ pqSup'' `shouldBe` pqSupport
    allowConnection bob aliceId confId "bob's connInfo"
    let pqEnc = CR.pqSupportToEnc pqSupport
    get alice ##> ("", bobId, A.INFO pqSupport "bob's connInfo")
    get alice ##> ("", bobId, A.CON pqEnc)
    get bob ##> ("", aliceId, A.CON pqEnc)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> A.sendMessage alice bobId pqEnc SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> A.sendMessage alice bobId pqEnc SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg' _ pq "hello") -> c == aliceId && pq == pqEnc; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing
    get bob =##> \case ("", c, Msg' _ pq "how are you?") -> c == aliceId && pq == pqEnc; _ -> False
    ackMessage bob aliceId (baseId + 2) Nothing
    3 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg' _ pq "hello too") -> c == bobId && pq == pqEnc; _ -> False
    ackMessage alice bobId (baseId + 3) Nothing
    get alice =##> \case ("", c, Msg' _ pq "message 1") -> c == bobId && pq == pqEnc; _ -> False
    ackMessage alice bobId (baseId + 4) Nothing
    suspendConnection alice bobId
    5 <- msgId <$> A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  where
    msgId = subtract baseId . fst

noMessages :: HasCallStack => AgentClient -> String -> Expectation
noMessages c err = tryGet `shouldReturn` ()
  where
    tryGet =
      10000 `timeout` get c >>= \case
        Just msg -> error $ err <> ": " <> show msg
        _ -> return ()

testAsyncInitiatingOffline :: HasCallStack => IO ()
testAsyncInitiatingOffline =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    liftIO $ disposeAgentClient alice
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo" SMSubscribe
    alice' <- liftIO $ getSMPAgentClient' 3 agentCfg initAgentServers testDB
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    get alice' ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob aliceId

testAsyncJoiningOfflineBeforeActivation :: HasCallStack => IO ()
testAsyncJoiningOfflineBeforeActivation =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    liftIO $ disposeAgentClient bob
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient' 3 agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    get alice ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob' aliceId

testAsyncBothOffline :: HasCallStack => IO ()
testAsyncBothOffline =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    liftIO $ disposeAgentClient alice
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo" SMSubscribe
    liftIO $ disposeAgentClient bob
    alice' <- liftIO $ getSMPAgentClient' 3 agentCfg initAgentServers testDB
    subscribeConnection alice' bobId
    ("", _, CONF confId _ "bob's connInfo") <- get alice'
    allowConnection alice' bobId confId "alice's connInfo"
    bob' <- liftIO $ getSMPAgentClient' 4 agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    get alice' ##> ("", bobId, CON)
    get bob' ##> ("", aliceId, INFO "alice's connInfo")
    get bob' ##> ("", aliceId, CON)
    exchangeGreetings alice' bobId bob' aliceId

testAsyncServerOffline :: HasCallStack => ATransport -> IO ()
testAsyncServerOffline t = withAgentClients2 $ \alice bob -> do
  -- create connection and shutdown the server
  (bobId, cReq) <- withSmpServerStoreLogOn t testPort $ \_ ->
    runRight $ createConnection alice 1 True SCMInvitation Nothing SMSubscribe
  -- connection fails
  Left (BROKER _ NETWORK) <- runExceptT $ joinConnection bob 1 True cReq "bob's connInfo" SMSubscribe
  ("", "", DOWN srv conns) <- nGet alice
  srv `shouldBe` testSMPServer
  conns `shouldBe` [bobId]
  -- connection succeeds after server start
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    ("", "", UP srv1 conns1) <- nGet alice
    liftIO $ do
      srv1 `shouldBe` testSMPServer
      conns1 `shouldBe` [bobId]
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo" SMSubscribe
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId

testAllowConnectionClientRestart :: HasCallStack => ATransport -> IO ()
testAllowConnectionClientRestart t = do
  let initAgentServersSrv2 = initAgentServers {smp = userServers [noAuthSrv testSMPServer2]}
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServersSrv2 testDB2
  withSmpServerStoreLogOn t testPort $ \_ -> do
    (aliceId, bobId, confId) <-
      withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \_ -> do
        runRight $ do
          (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
          aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
          ("", _, CONF confId _ "bob's connInfo") <- get alice
          pure (aliceId, bobId, confId)

    ("", "", DOWN _ _) <- nGet bob

    runRight_ $ do
      allowConnectionAsync alice "1" bobId confId "alice's connInfo"
      get alice =##> \case ("1", _, OK) -> True; _ -> False
      pure ()

    threadDelay 100000 -- give time to enqueue confirmation (enqueueConfirmation)
    disposeAgentClient alice

    alice2 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB

    withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \_ -> do
      runRight $ do
        ("", "", UP _ _) <- nGet bob

        subscribeConnection alice2 bobId

        get alice2 ##> ("", bobId, CON)
        get bob ##> ("", aliceId, INFO "alice's connInfo")
        get bob ##> ("", aliceId, CON)

        exchangeGreetingsMsgId 4 alice2 bobId bob aliceId
    disposeAgentClient alice2
    disposeAgentClient bob

testIncreaseConnAgentVersion :: HasCallStack => ATransport -> IO ()
testIncreaseConnAgentVersion t = do
  alice <- getSMPAgentClient' 1 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 2} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 2} initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ do
      (aliceId, bobId) <- makeConnection_ PQSupportOff alice bob
      exchangeGreetingsMsgId_ PQEncOff 4 alice bobId bob aliceId
      checkVersion alice bobId 2
      checkVersion bob aliceId 2
      pure (aliceId, bobId)

    -- version doesn't increase if incompatible

    disposeAgentClient alice
    alice2 <- getSMPAgentClient' 3 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB

    runRight_ $ do
      subscribeConnection alice2 bobId
      exchangeGreetingsMsgId_ PQEncOff 6 alice2 bobId bob aliceId
      checkVersion alice2 bobId 2
      checkVersion bob aliceId 2

    -- version increases if compatible

    disposeAgentClient bob
    bob2 <- getSMPAgentClient' 4 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB2

    runRight_ $ do
      subscribeConnection bob2 aliceId
      exchangeGreetingsMsgId_ PQEncOff 8 alice2 bobId bob2 aliceId
      checkVersion alice2 bobId 3
      checkVersion bob2 aliceId 3

    -- version doesn't decrease, even if incompatible

    disposeAgentClient alice2
    alice3 <- getSMPAgentClient' 5 agentCfg {smpAgentVRange = \_ -> mkVersionRange 2 2} initAgentServers testDB

    runRight_ $ do
      subscribeConnection alice3 bobId
      exchangeGreetingsMsgId_ PQEncOff 10 alice3 bobId bob2 aliceId
      checkVersion alice3 bobId 3
      checkVersion bob2 aliceId 3

    disposeAgentClient bob2
    bob3 <- getSMPAgentClient' 6 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 1} initAgentServers testDB2

    runRight_ $ do
      subscribeConnection bob3 aliceId
      exchangeGreetingsMsgId_ PQEncOff 12 alice3 bobId bob3 aliceId
      checkVersion alice3 bobId 3
      checkVersion bob3 aliceId 3
    disposeAgentClient alice3
    disposeAgentClient bob3

checkVersion :: AgentClient -> ConnId -> Word16 -> ExceptT AgentErrorType IO ()
checkVersion c connId v = do
  ConnectionStats {connAgentVersion} <- getConnectionServers c connId
  liftIO $ connAgentVersion `shouldBe` VersionSMPA v

testIncreaseConnAgentVersionMaxCompatible :: HasCallStack => ATransport -> IO ()
testIncreaseConnAgentVersionMaxCompatible t = do
  alice <- getSMPAgentClient' 1 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 2} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 2} initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ do
      (aliceId, bobId) <- makeConnection_ PQSupportOff alice bob
      exchangeGreetingsMsgId_ PQEncOff 4 alice bobId bob aliceId
      checkVersion alice bobId 2
      checkVersion bob aliceId 2
      pure (aliceId, bobId)

    -- version increases to max compatible

    disposeAgentClient alice
    alice2 <- getSMPAgentClient' 3 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB
    disposeAgentClient bob
    bob2 <- getSMPAgentClient' 4 agentCfg {smpAgentVRange = supportedSMPAgentVRange} initAgentServers testDB2

    runRight_ $ do
      subscribeConnection alice2 bobId
      subscribeConnection bob2 aliceId
      exchangeGreetingsMsgId_ PQEncOff 6 alice2 bobId bob2 aliceId
      checkVersion alice2 bobId 3
      checkVersion bob2 aliceId 3
    disposeAgentClient alice2
    disposeAgentClient bob2

testIncreaseConnAgentVersionStartDifferentVersion :: HasCallStack => ATransport -> IO ()
testIncreaseConnAgentVersionStartDifferentVersion t = do
  alice <- getSMPAgentClient' 1 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 2} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ do
      (aliceId, bobId) <- makeConnection_ PQSupportOff alice bob
      exchangeGreetingsMsgId_ PQEncOff 4 alice bobId bob aliceId
      checkVersion alice bobId 2
      checkVersion bob aliceId 2
      pure (aliceId, bobId)

    -- version increases to max compatible

    disposeAgentClient alice
    alice2 <- getSMPAgentClient' 3 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB

    runRight_ $ do
      subscribeConnection alice2 bobId
      exchangeGreetingsMsgId_ PQEncOff 6 alice2 bobId bob aliceId
      checkVersion alice2 bobId 3
      checkVersion bob aliceId 3
    disposeAgentClient alice2
    disposeAgentClient bob

testDeliverClientRestart :: HasCallStack => ATransport -> IO ()
testDeliverClientRestart t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2

  (aliceId, bobId) <- withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight $ do
      (aliceId, bobId) <- makeConnection alice bob
      exchangeGreetingsMsgId 4 alice bobId bob aliceId
      pure (aliceId, bobId)

  ("", "", DOWN _ _) <- nGet alice
  ("", "", DOWN _ _) <- nGet bob

  6 <- runRight $ sendMessage bob aliceId SMP.noMsgFlags "hello"

  disposeAgentClient bob

  bob2 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      ("", "", UP _ _) <- nGet alice

      subscribeConnection bob2 aliceId

      get bob2 ##> ("", aliceId, SENT 6)
      get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
  disposeAgentClient alice
  disposeAgentClient bob2

testDuplicateMessage :: HasCallStack => ATransport -> IO ()
testDuplicateMessage t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId, bob1) <- withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ makeConnection alice bob
    runRight_ $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    disposeAgentClient bob

    -- if the agent user did not send ACK, the message will be delivered again
    bob1 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2
    runRight_ $ do
      subscribeConnection bob1 aliceId
      get bob1 =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob1 aliceId 4 Nothing
      5 <- sendMessage alice bobId SMP.noMsgFlags "hello 2"
      get alice ##> ("", bobId, SENT 5)
      get bob1 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False

    pure (aliceId, bobId, bob1)

  nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
  nGet bob1 =##> \case ("", "", DOWN _ [c]) -> c == aliceId; _ -> False
  -- commenting two lines below and uncommenting further two lines would also runRight_,
  -- it is the scenario tested above, when the message was not acknowledged by the user
  threadDelay 200000
  Left (BROKER _ NETWORK) <- runExceptT $ ackMessage bob1 aliceId 5 Nothing

  disposeAgentClient alice
  disposeAgentClient bob1

  alice2 <- getSMPAgentClient' 4 agentCfg initAgentServers testDB
  bob2 <- getSMPAgentClient' 5 agentCfg initAgentServers testDB2

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection bob2 aliceId
      subscribeConnection alice2 bobId
      -- get bob2 =##> \case ("", c, Msg "hello 2") -> c == aliceId; _ -> False
      -- ackMessage bob2 aliceId 5 Nothing
      -- message 2 is not delivered again, even though it was delivered to the agent
      6 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 3"
      get alice2 ##> ("", bobId, SENT 6)
      get bob2 =##> \case ("", c, Msg "hello 3") -> c == aliceId; _ -> False
  disposeAgentClient alice2
  disposeAgentClient bob2

testSkippedMessages :: HasCallStack => ATransport -> IO ()
testSkippedMessages t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> do
    (aliceId, bobId) <- runRight $ makeConnection alice bob
    runRight_ $ do
      4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
      get alice ##> ("", bobId, SENT 4)
      get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
      ackMessage bob aliceId 4 Nothing

    disposeAgentClient bob

    runRight_ $ do
      5 <- sendMessage alice bobId SMP.noMsgFlags "hello 2"
      get alice ##> ("", bobId, SENT 5)
      6 <- sendMessage alice bobId SMP.noMsgFlags "hello 3"
      get alice ##> ("", bobId, SENT 6)
      7 <- sendMessage alice bobId SMP.noMsgFlags "hello 4"
      get alice ##> ("", bobId, SENT 7)

    pure (aliceId, bobId)

  nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
  threadDelay 200000

  disposeAgentClient alice

  alice2 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB
  bob2 <- getSMPAgentClient' 4 agentCfg initAgentServers testDB2

  withSmpServerStoreLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection bob2 aliceId
      subscribeConnection alice2 bobId

      8 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 5"
      get alice2 ##> ("", bobId, SENT 8)
      get bob2 =##> \case ("", c, MSG MsgMeta {integrity = MsgError {errorInfo = MsgSkipped {fromMsgId = 4, toMsgId = 6}}} _ "hello 5") -> c == aliceId; _ -> False
      ackMessage bob2 aliceId 5 Nothing

      9 <- sendMessage alice2 bobId SMP.noMsgFlags "hello 6"
      get alice2 ##> ("", bobId, SENT 9)
      get bob2 =##> \case ("", c, Msg "hello 6") -> c == aliceId; _ -> False
      ackMessage bob2 aliceId 6 Nothing
  disposeAgentClient alice2
  disposeAgentClient bob2

testExpireMessage :: HasCallStack => ATransport -> IO ()
testExpireMessage t = do
  a <- getSMPAgentClient' 1 agentCfg {messageTimeout = 1, messageRetryInterval = fastMessageRetryInterval} initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ makeConnection a b
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId; _ -> False
  nGet b =##> \case ("", "", DOWN _ [c]) -> c == aId; _ -> False
  4 <- runRight $ sendMessage a bId SMP.noMsgFlags "1"
  threadDelay 1000000
  5 <- runRight $ sendMessage a bId SMP.noMsgFlags "2" -- this won't expire
  get a =##> \case ("", c, MERR 4 (BROKER _ e)) -> bId == c && (e == TIMEOUT || e == NETWORK); _ -> False
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    withUP a bId $ \case ("", _, SENT 5) -> True; _ -> False
    withUP b aId $ \case ("", _, MsgErr 4 (MsgSkipped 3 3) "2") -> True; _ -> False
    ackMessage b aId 4 Nothing

testExpireManyMessages :: HasCallStack => ATransport -> IO ()
testExpireManyMessages t = do
  a <- getSMPAgentClient' 1 agentCfg {messageTimeout = 1, messageRetryInterval = fastMessageRetryInterval} initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ makeConnection a b
  runRight_ $ do
    nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId; _ -> False
    nGet b =##> \case ("", "", DOWN _ [c]) -> c == aId; _ -> False
    4 <- sendMessage a bId SMP.noMsgFlags "1"
    5 <- sendMessage a bId SMP.noMsgFlags "2"
    6 <- sendMessage a bId SMP.noMsgFlags "3"
    liftIO $ threadDelay 1000000
    7 <- sendMessage a bId SMP.noMsgFlags "4" -- this won't expire
    get a =##> \case ("", c, MERR 4 (BROKER _ e)) -> bId == c && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, MERRS [5, 6] (BROKER _ e)) -> bId == c && (e == TIMEOUT || e == NETWORK); _ -> False
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    withUP a bId $ \case ("", _, SENT 7) -> True; _ -> False
    withUP b aId $ \case ("", _, MsgErr 4 (MsgSkipped 3 5) "4") -> True; _ -> False
    ackMessage b aId 4 Nothing

withUP :: AgentClient -> ConnId -> (AEntityTransmission 'AEConn -> Bool) -> ExceptT AgentErrorType IO ()
withUP a bId p =
  liftIO $
    getInAnyOrder
      a
      [ \case ("", "", APC SAENone (UP _ [c])) -> c == bId; _ -> False,
        \case (corrId, c, APC SAEConn cmd) -> c == bId && p (corrId, c, cmd); _ -> False
      ]

testExpireMessageQuota :: HasCallStack => ATransport -> IO ()
testExpireMessageQuota t = withSmpServerConfigOn t cfg {msgQueueQuota = 1} testPort $ \_ -> do
  a <- getSMPAgentClient' 1 agentCfg {quotaExceededTimeout = 1, messageRetryInterval = fastMessageRetryInterval} initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aId, bId) <- runRight $ do
    (aId, bId) <- makeConnection a b
    liftIO $ threadDelay 500000 >> disposeAgentClient b
    4 <- sendMessage a bId SMP.noMsgFlags "1"
    get a ##> ("", bId, SENT 4)
    5 <- sendMessage a bId SMP.noMsgFlags "2"
    liftIO $ threadDelay 1000000
    6 <- sendMessage a bId SMP.noMsgFlags "3" -- this won't expire
    get a =##> \case ("", c, MERR 5 (SMP QUOTA)) -> bId == c; _ -> False
    pure (aId, bId)
  b' <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2
  runRight_ $ do
    subscribeConnection b' aId
    get b' =##> \case ("", c, Msg "1") -> c == aId; _ -> False
    ackMessage b' aId 4 Nothing
    get a ##> ("", bId, SENT 6)
    get b' =##> \case ("", c, MsgErr 6 (MsgSkipped 4 4) "3") -> c == aId; _ -> False
    ackMessage b' aId 6 Nothing

testExpireManyMessagesQuota :: HasCallStack => ATransport -> IO ()
testExpireManyMessagesQuota t = withSmpServerConfigOn t cfg {msgQueueQuota = 1} testPort $ \_ -> do
  a <- getSMPAgentClient' 1 agentCfg {quotaExceededTimeout = 1, messageRetryInterval = fastMessageRetryInterval} initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aId, bId) <- runRight $ do
    (aId, bId) <- makeConnection a b
    liftIO $ threadDelay 500000 >> disposeAgentClient b
    4 <- sendMessage a bId SMP.noMsgFlags "1"
    get a ##> ("", bId, SENT 4)
    5 <- sendMessage a bId SMP.noMsgFlags "2"
    6 <- sendMessage a bId SMP.noMsgFlags "3"
    7 <- sendMessage a bId SMP.noMsgFlags "4"
    liftIO $ threadDelay 1000000
    8 <- sendMessage a bId SMP.noMsgFlags "5" -- this won't expire
    get a =##> \case ("", c, MERR 5 (SMP QUOTA)) -> bId == c; _ -> False
    get a =##> \case ("", c, MERRS [6, 7] (SMP QUOTA)) -> bId == c; _ -> False
    pure (aId, bId)
  b' <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2
  runRight_ $ do
    subscribeConnection b' aId
    get b' =##> \case ("", c, Msg "1") -> c == aId; _ -> False
    ackMessage b' aId 4 Nothing
    get a ##> ("", bId, SENT 8)
    get b' =##> \case ("", c, MsgErr 6 (MsgSkipped 4 6) "5") -> c == aId; _ -> False
    ackMessage b' aId 6 Nothing

testRatchetSync :: HasCallStack => ATransport -> IO ()
testRatchetSync t = withAgentClients2 $ \alice bob ->
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aliceId, bobId, bob2) <- setupDesynchronizedRatchet alice bob
    runRight $ do
      ConnectionStats {ratchetSyncState} <- synchronizeRatchet bob2 aliceId PQSupportOn False
      liftIO $ ratchetSyncState `shouldBe` RSStarted
      get alice =##> ratchetSyncP bobId RSAgreed
      get bob2 =##> ratchetSyncP aliceId RSAgreed
      get alice =##> ratchetSyncP bobId RSOk
      get bob2 =##> ratchetSyncP aliceId RSOk
      exchangeGreetingsMsgIds alice bobId 12 bob2 aliceId 9

setupDesynchronizedRatchet :: HasCallStack => AgentClient -> AgentClient -> IO (ConnId, ConnId, AgentClient)
setupDesynchronizedRatchet alice bob = do
  (aliceId, bobId) <- runRight $ makeConnection alice bob
  runRight_ $ do
    4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT 4)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId 4 Nothing

    5 <- sendMessage bob aliceId SMP.noMsgFlags "hello 2"
    get bob ##> ("", aliceId, SENT 5)
    get alice =##> \case ("", c, Msg "hello 2") -> c == bobId; _ -> False
    ackMessage alice bobId 5 Nothing

    liftIO $ copyFile testDB2 (testDB2 <> ".bak")

    6 <- sendMessage alice bobId SMP.noMsgFlags "hello 3"
    get alice ##> ("", bobId, SENT 6)
    get bob =##> \case ("", c, Msg "hello 3") -> c == aliceId; _ -> False
    ackMessage bob aliceId 6 Nothing

    7 <- sendMessage bob aliceId SMP.noMsgFlags "hello 4"
    get bob ##> ("", aliceId, SENT 7)
    get alice =##> \case ("", c, Msg "hello 4") -> c == bobId; _ -> False
    ackMessage alice bobId 7 Nothing

  disposeAgentClient bob

  -- importing database backup after progressing ratchet de-synchronizes ratchet
  liftIO $ renameFile (testDB2 <> ".bak") testDB2

  bob2 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2

  runRight_ $ do
    subscribeConnection bob2 aliceId

    Left A.CMD {cmdErr = PROHIBITED} <- liftIO . runExceptT $ synchronizeRatchet bob2 aliceId PQSupportOn False

    8 <- sendMessage alice bobId SMP.noMsgFlags "hello 5"
    get alice ##> ("", bobId, SENT 8)
    get bob2 =##> ratchetSyncP aliceId RSRequired

    Left A.CMD {cmdErr = PROHIBITED} <- liftIO . runExceptT $ sendMessage bob2 aliceId SMP.noMsgFlags "hello 6"
    pure ()

  pure (aliceId, bobId, bob2)

ratchetSyncP :: ConnId -> RatchetSyncState -> AEntityTransmission 'AEConn -> Bool
ratchetSyncP cId rss = \case
  (_, cId', RSYNC rss' _ ConnectionStats {ratchetSyncState}) ->
    cId' == cId && rss' == rss && ratchetSyncState == rss
  _ -> False

ratchetSyncP' :: ConnId -> RatchetSyncState -> ATransmission 'Agent -> Bool
ratchetSyncP' cId rss = \case
  (_, cId', APC SAEConn (RSYNC rss' _ ConnectionStats {ratchetSyncState})) ->
    cId' == cId && rss' == rss && ratchetSyncState == rss
  _ -> False

testRatchetSyncServerOffline :: HasCallStack => ATransport -> IO ()
testRatchetSyncServerOffline t = withAgentClients2 $ \alice bob -> do
  (aliceId, bobId, bob2) <- withSmpServerStoreMsgLogOn t testPort $ \_ ->
    setupDesynchronizedRatchet alice bob

  ("", "", DOWN _ _) <- nGet alice
  ("", "", DOWN _ _) <- nGet bob2

  ConnectionStats {ratchetSyncState} <- runRight $ synchronizeRatchet bob2 aliceId PQSupportOn False
  liftIO $ ratchetSyncState `shouldBe` RSStarted

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      liftIO . getInAnyOrder alice $
        [ ratchetSyncP' bobId RSAgreed,
          serverUpP
        ]
      liftIO . getInAnyOrder bob2 $
        [ ratchetSyncP' aliceId RSAgreed,
          serverUpP
        ]
      get alice =##> ratchetSyncP bobId RSOk
      get bob2 =##> ratchetSyncP aliceId RSOk
      exchangeGreetingsMsgIds alice bobId 12 bob2 aliceId 9

serverUpP :: ATransmission 'Agent -> Bool
serverUpP = \case
  ("", "", APC SAENone (UP _ _)) -> True
  _ -> False

testRatchetSyncClientRestart :: HasCallStack => ATransport -> IO ()
testRatchetSyncClientRestart t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId, bob2) <- withSmpServerStoreMsgLogOn t testPort $ \_ ->
    setupDesynchronizedRatchet alice bob
  ("", "", DOWN _ _) <- nGet alice
  ("", "", DOWN _ _) <- nGet bob2
  ConnectionStats {ratchetSyncState} <- runRight $ synchronizeRatchet bob2 aliceId PQSupportOn False
  liftIO $ ratchetSyncState `shouldBe` RSStarted
  liftIO $ disposeAgentClient bob2
  bob3 <- getSMPAgentClient' 3 agentCfg initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      ("", "", UP _ _) <- nGet alice
      subscribeConnection bob3 aliceId
      get alice =##> ratchetSyncP bobId RSAgreed
      get bob3 =##> ratchetSyncP aliceId RSAgreed
      get alice =##> ratchetSyncP bobId RSOk
      get bob3 =##> ratchetSyncP aliceId RSOk
      exchangeGreetingsMsgIds alice bobId 12 bob3 aliceId 9
  disposeAgentClient alice
  disposeAgentClient bob
  disposeAgentClient bob3

testRatchetSyncSuspendForeground :: HasCallStack => ATransport -> IO ()
testRatchetSyncSuspendForeground t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId, bob2) <- withSmpServerStoreMsgLogOn t testPort $ \_ ->
    setupDesynchronizedRatchet alice bob

  ("", "", DOWN _ _) <- nGet alice
  ("", "", DOWN _ _) <- nGet bob2

  ConnectionStats {ratchetSyncState} <- runRight $ synchronizeRatchet bob2 aliceId PQSupportOn False
  liftIO $ ratchetSyncState `shouldBe` RSStarted

  suspendAgent bob2 0
  threadDelay 100000
  foregroundAgent bob2

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      liftIO . getInAnyOrder alice $
        [ ratchetSyncP' bobId RSAgreed,
          serverUpP
        ]
      liftIO . getInAnyOrder bob2 $
        [ ratchetSyncP' aliceId RSAgreed,
          serverUpP
        ]
      get alice =##> ratchetSyncP bobId RSOk
      get bob2 =##> ratchetSyncP aliceId RSOk
      exchangeGreetingsMsgIds alice bobId 12 bob2 aliceId 9
  disposeAgentClient alice
  disposeAgentClient bob
  disposeAgentClient bob2

testRatchetSyncSimultaneous :: HasCallStack => ATransport -> IO ()
testRatchetSyncSimultaneous t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId, bob2) <- withSmpServerStoreMsgLogOn t testPort $ \_ ->
    setupDesynchronizedRatchet alice bob

  ("", "", DOWN _ _) <- nGet alice
  ("", "", DOWN _ _) <- nGet bob2

  ConnectionStats {ratchetSyncState = bRSS} <- runRight $ synchronizeRatchet bob2 aliceId PQSupportOn False
  liftIO $ bRSS `shouldBe` RSStarted

  ConnectionStats {ratchetSyncState = aRSS} <- runRight $ synchronizeRatchet alice bobId PQSupportOn True
  liftIO $ aRSS `shouldBe` RSStarted

  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    runRight_ $ do
      liftIO . getInAnyOrder alice $
        [ ratchetSyncP' bobId RSAgreed,
          serverUpP
        ]
      liftIO . getInAnyOrder bob2 $
        [ ratchetSyncP' aliceId RSAgreed,
          serverUpP
        ]
      get alice =##> ratchetSyncP bobId RSOk
      get bob2 =##> ratchetSyncP aliceId RSOk
      exchangeGreetingsMsgIds alice bobId 12 bob2 aliceId 9
  disposeAgentClient alice
  disposeAgentClient bob
  disposeAgentClient bob2

testOnlyCreatePull :: IO ()
testOnlyCreatePull = withAgentClients2 $ \alice bob -> runRight_ $ do
  (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMOnlyCreate
  aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMOnlyCreate
  Just ("", _, CONF confId _ "bob's connInfo") <- getMsg alice bobId $ timeout 5_000000 $ get alice
  allowConnection alice bobId confId "alice's connInfo"
  liftIO $ threadDelay 1_000000
  getMsg bob aliceId $
    get bob ##> ("", aliceId, INFO "alice's connInfo")
  liftIO $ threadDelay 1_000000
  getMsg alice bobId $ pure ()
  get alice ##> ("", bobId, CON)
  getMsg bob aliceId $
    get bob ##> ("", aliceId, CON)
  -- exchange messages
  4 <- sendMessage alice bobId SMP.noMsgFlags "hello"
  get alice ##> ("", bobId, SENT 4)
  getMsg bob aliceId $
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
  ackMessage bob aliceId 4 Nothing
  5 <- sendMessage bob aliceId SMP.noMsgFlags "hello too"
  get bob ##> ("", aliceId, SENT 5)
  getMsg alice bobId $
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
  ackMessage alice bobId 5 Nothing
  where
    getMsg :: AgentClient -> ConnId -> ExceptT AgentErrorType IO a -> ExceptT AgentErrorType IO a
    getMsg c cId action = do
      liftIO $ noMessages c "nothing should be delivered before GET"
      Just _ <- getConnectionMessage c cId
      r <- action
      get c =##> \case ("", cId', MSGNTF _) -> cId == cId'; _ -> False
      pure r

makeConnection :: AgentClient -> AgentClient -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnection = makeConnection_ PQSupportOn

makeConnection_ :: PQSupport -> AgentClient -> AgentClient -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnection_ pqEnc alice bob = makeConnectionForUsers_ pqEnc alice 1 bob 1

makeConnectionForUsers :: AgentClient -> UserId -> AgentClient -> UserId -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnectionForUsers = makeConnectionForUsers_ PQSupportOn

makeConnectionForUsers_ :: PQSupport -> AgentClient -> UserId -> AgentClient -> UserId -> ExceptT AgentErrorType IO (ConnId, ConnId)
makeConnectionForUsers_ pqSupport alice aliceUserId bob bobUserId = do
  (bobId, qInfo) <- A.createConnection alice aliceUserId True SCMInvitation Nothing (CR.IKNoPQ pqSupport) SMSubscribe
  aliceId <- A.joinConnection bob bobUserId True qInfo "bob's connInfo" pqSupport SMSubscribe
  ("", _, A.CONF confId pqSup' _ "bob's connInfo") <- get alice
  liftIO $ pqSup' `shouldBe` pqSupport
  allowConnection alice bobId confId "alice's connInfo"
  let pqEnc = CR.pqSupportToEnc pqSupport
  get alice ##> ("", bobId, A.CON pqEnc)
  get bob ##> ("", aliceId, A.INFO pqSupport "alice's connInfo")
  get bob ##> ("", aliceId, A.CON pqEnc)
  pure (aliceId, bobId)

testInactiveNoSubs :: ATransport -> IO ()
testInactiveNoSubs t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
    runRight_ . void $ createConnection alice 1 True SCMInvitation Nothing SMOnlyCreate -- do not subscribe to pass noSubscriptions check
    Just (_, _, APC SAENone (CONNECT _ _)) <- timeout 2000000 $ atomically' (readTBQueue $ subQ alice)
    Just (_, _, APC SAENone (DISCONNECT _ _)) <- timeout 5000000 $ atomically' (readTBQueue $ subQ alice)
    disposeAgentClient alice

testInactiveWithSubs :: ATransport -> IO ()
testInactiveWithSubs t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
    runRight_ . void $ createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    Nothing <- 800000 `timeout` get alice
    liftIO $ threadDelay 1200000
    -- and after 2 sec of inactivity no DOWN is sent as we have a live subscription
    liftIO $ timeout 1200000 (get alice) `shouldReturn` Nothing
    disposeAgentClient alice

testActiveClientNotDisconnected :: ATransport -> IO ()
testActiveClientNotDisconnected t = do
  let cfg' = cfg {inactiveClientExpiration = Just ExpirationConfig {ttl = 1, checkInterval = 1}}
  withSmpServerConfigOn t cfg' testPort $ \_ -> do
    alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
    ts <- getSystemTime
    runRight_ $ do
      (connId, _cReq) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
      keepSubscribing alice connId ts
    disposeAgentClient alice
  where
    keepSubscribing :: AgentClient -> ConnId -> SystemTime -> ExceptT AgentErrorType IO ()
    keepSubscribing alice connId ts = do
      ts' <- liftIO getSystemTime
      if milliseconds ts' - milliseconds ts < 2200
        then do
          -- keep sending SUB for 2.2 seconds
          liftIO $ threadDelay 200000
          subscribeConnection alice connId
          keepSubscribing alice connId ts
        else do
          -- check that nothing is sent from agent
          Nothing <- 800000 `timeout` get alice
          liftIO $ threadDelay 1200000
          -- and after 2 sec of inactivity no DOWN is sent as we have a live subscription
          liftIO $ timeout 1200000 (get alice) `shouldReturn` Nothing
    milliseconds ts = systemSeconds ts * 1000 + fromIntegral (systemNanoseconds ts `div` 1000000)

testSuspendingAgent :: IO ()
testSuspendingAgent =
  withAgentClients2 $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4 Nothing
    liftIO $ suspendAgent b 1000000
    get' b ##> ("", "", SUSPENDED)
    5 <- sendMessage a bId SMP.noMsgFlags "hello 2"
    get a ##> ("", bId, SENT 5)
    Nothing <- 100000 `timeout` get b
    liftIO $ foregroundAgent b
    get b =##> \case ("", c, Msg "hello 2") -> c == aId; _ -> False

testSuspendingAgentCompleteSending :: ATransport -> IO ()
testSuspendingAgentCompleteSending t = withAgentClients2 $ \a b -> do
  (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4 Nothing
    pure (aId, bId)

  runRight_ $ do
    ("", "", DOWN {}) <- nGet a
    ("", "", DOWN {}) <- nGet b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    liftIO $ threadDelay 100000
    liftIO $ suspendAgent b 5000000

  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ @AgentErrorType $ do
    pGet b =##> \case ("", c, APC _ (SENT 5)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet b =##> \case ("", c, APC _ (SENT 5)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet b =##> \case ("", c, APC _ (SENT 6)) -> c == aId; ("", "", APC _ UP {}) -> True; _ -> False
    ("", "", SUSPENDED) <- nGet b

    pGet a =##> \case ("", c, APC _ (Msg "hello too")) -> c == bId; ("", "", APC _ UP {}) -> True; _ -> False
    pGet a =##> \case ("", c, APC _ (Msg "hello too")) -> c == bId; ("", "", APC _ UP {}) -> True; _ -> False
    ackMessage a bId 5 Nothing
    get a =##> \case ("", c, Msg "how are you?") -> c == bId; _ -> False
    ackMessage a bId 6 Nothing

testSuspendingAgentTimeout :: ATransport -> IO ()
testSuspendingAgentTimeout t = withAgentClients2 $ \a b -> do
  (aId, _) <- withSmpServer t . runRight $ do
    (aId, bId) <- makeConnection a b
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4 Nothing
    pure (aId, bId)

  runRight_ $ do
    ("", "", DOWN {}) <- nGet a
    ("", "", DOWN {}) <- nGet b
    5 <- sendMessage b aId SMP.noMsgFlags "hello too"
    6 <- sendMessage b aId SMP.noMsgFlags "how are you?"
    liftIO $ suspendAgent b 100000
    ("", "", SUSPENDED) <- nGet b
    pure ()

testBatchedSubscriptions :: Int -> Int -> ATransport -> IO ()
testBatchedSubscriptions nCreate nDel t = do
  a <- getSMPAgentClient' 1 agentCfg initAgentServers2 testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServers2 testDB2
  conns <- runServers $ do
    conns <- replicateM (nCreate :: Int) $ makeConnection_ PQSupportOff a b
    forM_ conns $ \(aId, bId) -> exchangeGreetings_ PQEncOff a bId b aId
    let (aIds', bIds') = unzip $ take nDel conns
    delete a bIds'
    delete b aIds'
    liftIO $ threadDelay 1000000
    pure conns
  ("", "", DOWN {}) <- nGet a
  ("", "", DOWN {}) <- nGet a
  ("", "", DOWN {}) <- nGet b
  ("", "", DOWN {}) <- nGet b
  runServers $ do
    ("", "", UP {}) <- nGet a
    ("", "", UP {}) <- nGet a
    ("", "", UP {}) <- nGet b
    ("", "", UP {}) <- nGet b
    liftIO $ threadDelay 1000000
    let (aIds, bIds) = unzip conns
        conns' = drop nDel conns
        (aIds', bIds') = unzip conns'
    subscribe a bIds
    subscribe b aIds
    forM_ conns' $ \(aId, bId) -> exchangeGreetingsMsgId_ PQEncOff 6 a bId b aId
    void $ resubscribeConnections a bIds
    void $ resubscribeConnections b aIds
    forM_ conns' $ \(aId, bId) -> exchangeGreetingsMsgId_ PQEncOff 8 a bId b aId
    delete a bIds'
    delete b aIds'
    deleteFail a bIds'
    deleteFail b aIds'
  disposeAgentClient a
  disposeAgentClient b
  where
    subscribe :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    subscribe c cs = do
      r <- subscribeConnections c cs
      liftIO $ do
        let dc = S.fromList $ take nDel cs
        all isRight (M.withoutKeys r dc) `shouldBe` True
        all (== Left (CONN NOT_FOUND)) (M.restrictKeys r dc) `shouldBe` True
        M.keys r `shouldMatchList` cs
    delete :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    delete c cs = do
      r <- deleteConnections c cs
      liftIO $ do
        all isRight r `shouldBe` True
        M.keys r `shouldMatchList` cs
    deleteFail :: AgentClient -> [ConnId] -> ExceptT AgentErrorType IO ()
    deleteFail c cs = do
      r <- deleteConnections c cs
      liftIO $ do
        all (== Left (CONN NOT_FOUND)) r `shouldBe` True
        M.keys r `shouldMatchList` cs
    runServers :: ExceptT AgentErrorType IO a -> IO a
    runServers a = do
      withSmpServerStoreLogOn t testPort $ \t1 -> do
        res <- withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \t2 ->
          runRight a `finally` killThread t2
        killThread t1
        pure res

testAsyncCommands :: IO ()
testAsyncCommands =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    bobId <- createConnectionAsync alice 1 "1" True SCMInvitation (IKNoPQ PQSupportOn) SMSubscribe
    ("1", bobId', INV (ACR _ qInfo)) <- get alice
    liftIO $ bobId' `shouldBe` bobId
    aliceId <- joinConnectionAsync bob 1 "2" True qInfo "bob's connInfo" PQSupportOn SMSubscribe
    ("2", aliceId', OK) <- get bob
    liftIO $ aliceId' `shouldBe` aliceId
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnectionAsync alice "3" bobId confId "alice's connInfo"
    get alice =##> \case ("3", _, OK) -> True; _ -> False
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessageAsync bob "4" aliceId (baseId + 1) Nothing
    inAnyOrder
      (get bob)
      [ \case ("4", _, OK) -> True; _ -> False,
        \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
      ]
    ackMessageAsync bob "5" aliceId (baseId + 2) Nothing
    get bob =##> \case ("5", _, OK) -> True; _ -> False
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessageAsync alice "6" bobId (baseId + 3) Nothing
    inAnyOrder
      (get alice)
      [ \case ("6", _, OK) -> True; _ -> False,
        \case ("", c, Msg "message 1") -> c == bobId; _ -> False
      ]
    ackMessageAsync alice "7" bobId (baseId + 4) Nothing
    get alice =##> \case ("7", _, OK) -> True; _ -> False
    deleteConnectionAsync alice False bobId
    get alice =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bobId; _ -> False
    get alice =##> \case ("", c, DEL_CONN) -> c == bobId; _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  where
    baseId = 3
    msgId = subtract baseId

testAsyncCommandsRestore :: ATransport -> IO ()
testAsyncCommandsRestore t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bobId <- runRight $ createConnectionAsync alice 1 "1" True SCMInvitation (IKNoPQ PQSupportOn) SMSubscribe
  liftIO $ noMessages alice "alice doesn't receive INV because server is down"
  disposeAgentClient alice
  alice' <- liftIO $ getSMPAgentClient' 2 agentCfg initAgentServers testDB
  withSmpServerStoreLogOn t testPort $ \_ -> do
    runRight_ $ do
      subscribeConnection alice' bobId
      get alice' =##> \case ("1", _, INV _) -> True; _ -> False
      pure ()
  disposeAgentClient alice'

testAcceptContactAsync :: IO ()
testAcceptContactAsync =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    (_, qInfo) <- createConnection alice 1 True SCMContact Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    ("", _, REQ invId _ "bob's connInfo") <- get alice
    bobId <- acceptContactAsync alice "1" True invId "alice's connInfo" PQSupportOn SMSubscribe
    get alice =##> \case ("1", c, OK) -> c == bobId; _ -> False
    ("", _, CONF confId _ "alice's connInfo") <- get bob
    allowConnection bob aliceId confId "bob's connInfo"
    get alice ##> ("", bobId, INFO "bob's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- message IDs 1 to 3 (or 1 to 4 in v1) get assigned to control messages, so first MSG is assigned ID 4
    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    2 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing
    get bob =##> \case ("", c, Msg "how are you?") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 2) Nothing
    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    4 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 1"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 3) Nothing
    get alice =##> \case ("", c, Msg "message 1") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 4) Nothing
    suspendConnection alice bobId
    5 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 5) (SMP AUTH))
    deleteConnection alice bobId
    liftIO $ noMessages alice "nothing else should be delivered to alice"
  where
    baseId = 3
    msgId = subtract baseId

testDeleteConnectionAsync :: ATransport -> IO ()
testDeleteConnectionAsync t = do
  a <- getSMPAgentClient' 1 agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  connIds <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (bId1, _inv) <- createConnection a 1 True SCMInvitation Nothing SMSubscribe
    (bId2, _inv) <- createConnection a 1 True SCMInvitation Nothing SMSubscribe
    (bId3, _inv) <- createConnection a 1 True SCMInvitation Nothing SMSubscribe
    pure ([bId1, bId2, bId3] :: [ConnId])
  runRight_ $ do
    deleteConnectionsAsync a False connIds
    nGet a =##> \case ("", "", DOWN {}) -> True; _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c `elem` connIds && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c `elem` connIds; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"
  disposeAgentClient a

testWaitDeliveryNoPending :: ATransport -> IO ()
testWaitDeliveryNoPending t = do
  alice <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    (aliceId, bobId) <- makeConnection alice bob

    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing

    2 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing

    deleteConnectionsAsync alice True [bobId]
    get alice =##> \case ("", cId, DEL_RCVQ _ _ Nothing) -> cId == bobId; _ -> False
    get alice =##> \case ("", cId, DEL_CONN) -> cId == bobId; _ -> False

    3 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, MERR (baseId + 3) (SMP AUTH))

    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  disposeAgentClient alice
  disposeAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testWaitDelivery :: ATransport -> IO ()
testWaitDelivery t = do
  alice <- getSMPAgentClient' 1 agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob

    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing

    2 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing

    pure (aliceId, bobId)

  runRight_ $ do
    ("", "", DOWN _ _) <- nGet alice
    ("", "", DOWN _ _) <- nGet bob
    3 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    4 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "message 1"
    deleteConnectionsAsync alice True [bobId]
    get alice =##> \case ("", cId, DEL_RCVQ _ _ (Just (BROKER _ e))) -> cId == bobId && (e == TIMEOUT || e == NETWORK); _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    get alice ##> ("", bobId, SENT $ baseId + 3)
    get alice ##> ("", bobId, SENT $ baseId + 4)
    get alice =##> \case ("", cId, DEL_CONN) -> cId == bobId; _ -> False

    liftIO $
      getInAnyOrder
        bob
        [ \case ("", "", APC SAENone (UP _ [cId])) -> cId == aliceId; _ -> False,
          \case ("", cId, APC SAEConn (Msg "how are you?")) -> cId == aliceId; _ -> False
        ]
    ackMessage bob aliceId (baseId + 3) Nothing
    get bob =##> \case ("", c, Msg "message 1") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 4) Nothing

    -- queue wasn't deleted (DEL never reached server, see DEL_RCVQ with error), so bob can send message
    5 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "message 2"
    get bob ##> ("", aliceId, SENT $ baseId + 5)

    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  disposeAgentClient alice
  disposeAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testWaitDeliveryAUTHErr :: ATransport -> IO ()
testWaitDeliveryAUTHErr t = do
  alice <- getSMPAgentClient' 1 agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (_aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob

    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing

    2 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing

    deleteConnectionsAsync bob False [aliceId]
    get bob =##> \case ("", cId, DEL_RCVQ _ _ Nothing) -> cId == aliceId; _ -> False
    get bob =##> \case ("", cId, DEL_CONN) -> cId == aliceId; _ -> False

    pure (aliceId, bobId)

  runRight_ $ do
    ("", "", DOWN _ _) <- nGet alice
    3 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    4 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "message 1"
    deleteConnectionsAsync alice True [bobId]
    get alice =##> \case ("", cId, DEL_RCVQ _ _ (Just (BROKER _ e))) -> cId == bobId && (e == TIMEOUT || e == NETWORK); _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  withSmpServerStoreLogOn t testPort $ \_ -> do
    get alice ##> ("", bobId, MERR (baseId + 3) (SMP AUTH))
    get alice ##> ("", bobId, MERR (baseId + 4) (SMP AUTH))
    get alice =##> \case ("", cId, DEL_CONN) -> cId == bobId; _ -> False

    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  disposeAgentClient alice
  disposeAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testWaitDeliveryTimeout :: ATransport -> IO ()
testWaitDeliveryTimeout t = do
  alice <- getSMPAgentClient' 1 agentCfg {connDeleteDeliveryTimeout = 1, initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob

    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing

    2 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing

    pure (aliceId, bobId)

  runRight_ $ do
    ("", "", DOWN _ _) <- nGet alice
    ("", "", DOWN _ _) <- nGet bob
    3 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    4 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "message 1"
    deleteConnectionsAsync alice True [bobId]
    get alice =##> \case ("", cId, DEL_RCVQ _ _ (Just (BROKER _ e))) -> cId == bobId && (e == TIMEOUT || e == NETWORK); _ -> False
    get alice =##> \case ("", cId, DEL_CONN) -> cId == bobId; _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  liftIO $ threadDelay 100000

  withSmpServerStoreLogOn t testPort $ \_ -> do
    nGet bob =##> \case ("", "", UP _ [cId]) -> cId == aliceId; _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  disposeAgentClient alice
  disposeAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testWaitDeliveryTimeout2 :: ATransport -> IO ()
testWaitDeliveryTimeout2 t = do
  alice <- getSMPAgentClient' 1 agentCfg {connDeleteDeliveryTimeout = 2, messageRetryInterval = fastMessageRetryInterval, initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3} initAgentServers testDB
  bob <- getSMPAgentClient' 2 agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob

    1 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "hello"
    get alice ##> ("", bobId, SENT $ baseId + 1)
    get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 1) Nothing

    2 <- msgId <$> sendMessage bob aliceId SMP.noMsgFlags "hello too"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing

    pure (aliceId, bobId)

  runRight_ $ do
    ("", "", DOWN _ _) <- nGet alice
    ("", "", DOWN _ _) <- nGet bob
    3 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "how are you?"
    4 <- msgId <$> sendMessage alice bobId SMP.noMsgFlags "message 1"
    deleteConnectionsAsync alice True [bobId]
    get alice =##> \case ("", cId, DEL_RCVQ _ _ (Just (BROKER _ e))) -> cId == bobId && (e == TIMEOUT || e == NETWORK); _ -> False
    get alice =##> \case ("", cId, DEL_CONN) -> cId == bobId; _ -> False
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  withSmpServerStoreLogOn t testPort $ \_ -> do
    get alice ##> ("", bobId, SENT $ baseId + 3)
    -- "message 1" not delivered

    liftIO $
      getInAnyOrder
        bob
        [ \case ("", "", APC SAENone (UP _ [cId])) -> cId == aliceId; _ -> False,
          \case ("", cId, APC SAEConn (Msg "how are you?")) -> cId == aliceId; _ -> False
        ]
    liftIO $ noMessages alice "nothing else should be delivered to alice"
    liftIO $ noMessages bob "nothing else should be delivered to bob"

  disposeAgentClient alice
  disposeAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testJoinConnectionAsyncReplyError :: HasCallStack => ATransport -> IO ()
testJoinConnectionAsyncReplyError t = do
  let initAgentServersSrv2 = initAgentServers {smp = userServers [noAuthSrv testSMPServer2]}
  a <- getSMPAgentClient' 1 agentCfg initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg initAgentServersSrv2 testDB2
  (aId, bId) <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    bId <- createConnectionAsync a 1 "1" True SCMInvitation (IKNoPQ PQSupportOn) SMSubscribe
    ("1", bId', INV (ACR _ qInfo)) <- get a
    liftIO $ bId' `shouldBe` bId
    aId <- joinConnectionAsync b 1 "2" True qInfo "bob's connInfo" PQSupportOn SMSubscribe
    liftIO $ threadDelay 500000
    ConnectionStats {rcvQueuesInfo = [], sndQueuesInfo = [SndQueueInfo {}]} <- getConnectionServers b aId
    pure (aId, bId)
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId; _ -> False
  withSmpServerOn t testPort2 $ do
    get b =##> \case ("2", c, OK) -> c == aId; _ -> False
    confId <- withSmpServerStoreLogOn t testPort $ \_ -> do
      pGet a >>= \case
        ("", "", APC _ (UP _ [_])) -> do
          ("", _, CONF confId _ "bob's connInfo") <- get a
          pure confId
        ("", _, APC _ (CONF confId _ "bob's connInfo")) -> do
          ("", "", UP _ [_]) <- nGet a
          pure confId
        r -> error $ "unexpected response " <> show r
    nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId; _ -> False
    runRight_ $ do
      allowConnectionAsync a "3" bId confId "alice's connInfo"
      liftIO $ threadDelay 500000
      ConnectionStats {rcvQueuesInfo = [RcvQueueInfo {}], sndQueuesInfo = [SndQueueInfo {}]} <- getConnectionServers b aId
      pure ()
    withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
      pGet a =##> \case ("3", c, APC _ OK) -> c == bId; ("", "", APC _ (UP _ [c])) -> c == bId; _ -> False
      pGet a =##> \case ("3", c, APC _ OK) -> c == bId; ("", "", APC _ (UP _ [c])) -> c == bId; _ -> False
      get a ##> ("", bId, CON)
      get b ##> ("", aId, INFO "alice's connInfo")
      get b ##> ("", aId, CON)
      exchangeGreetings a bId b aId
  disposeAgentClient a
  disposeAgentClient b

testUsers :: IO ()
testUsers =
  withAgentClients2 $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    deleteUser a auId True
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId'; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId'; _ -> False
    nGet a =##> \case ("", "", DEL_USER u) -> u == auId; _ -> False
    exchangeGreetingsMsgId 6 a bId b aId
    liftIO $ noMessages a "nothing else should be delivered to alice"

testDeleteUserQuietly :: IO ()
testDeleteUserQuietly =
  withAgentClients2 $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    deleteUser a auId False
    exchangeGreetingsMsgId 6 a bId b aId
    liftIO $ noMessages a "nothing else should be delivered to alice"

testUsersNoServer :: HasCallStack => ATransport -> IO ()
testUsersNoServer t = withAgentClientsCfg2 aCfg agentCfg $ \a b -> do
  (aId, bId, auId, _aId', bId') <- withSmpServerStoreLogOn t testPort $ \_ -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    auId <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId', bId') <- makeConnectionForUsers a auId b 1
    exchangeGreetingsMsgId 4 a bId' b aId'
    pure (aId, bId, auId, aId', bId')
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId || c == bId'; _ -> False
  nGet a =##> \case ("", "", DOWN _ [c]) -> c == bId || c == bId'; _ -> False
  nGet b =##> \case ("", "", DOWN _ cs) -> length cs == 2; _ -> False
  runRight_ $ do
    deleteUser a auId True
    get a =##> \case ("", c, DEL_RCVQ _ _ (Just (BROKER _ e))) -> c == bId' && (e == TIMEOUT || e == NETWORK); _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId'; _ -> False
    nGet a =##> \case ("", "", DEL_USER u) -> u == auId; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"
  withSmpServerStoreLogOn t testPort $ \_ -> runRight_ $ do
    nGet a =##> \case ("", "", UP _ [c]) -> c == bId; _ -> False
    nGet b =##> \case ("", "", UP _ cs) -> length cs == 2; _ -> False
    exchangeGreetingsMsgId 6 a bId b aId
  where
    aCfg = agentCfg {initialCleanupDelay = 10000, cleanupInterval = 10000, deleteErrorCount = 3}

testSwitchConnection :: InitialAgentServers -> IO ()
testSwitchConnection servers = do
  a <- getSMPAgentClient' 1 agentCfg servers testDB
  b <- getSMPAgentClient' 2 agentCfg servers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    testFullSwitch a bId b aId 10
    testFullSwitch a bId b aId 16
  disposeAgentClient a
  disposeAgentClient b

testFullSwitch :: AgentClient -> ByteString -> AgentClient -> ByteString -> Int64 -> ExceptT AgentErrorType IO ()
testFullSwitch a bId b aId msgId = do
  stats <- switchConnectionAsync a "" bId
  liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
  switchComplete a bId b aId
  exchangeGreetingsMsgId msgId a bId b aId

switchComplete :: AgentClient -> ByteString -> AgentClient -> ByteString -> ExceptT AgentErrorType IO ()
switchComplete a bId b aId = do
  phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
  phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
  phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]
  phaseRcv a bId SPConfirmed [Just RSSendingQADD, Nothing]
  phaseRcv a bId SPSecured [Just RSSendingQUSE, Nothing]
  phaseSnd b aId SPSecured [Just SSSendingQTEST, Nothing]
  phaseSnd b aId SPCompleted [Nothing]
  phaseRcv a bId SPCompleted [Nothing]

phaseRcv :: AgentClient -> ByteString -> SwitchPhase -> [Maybe RcvSwitchStatus] -> ExceptT AgentErrorType IO ()
phaseRcv c connId p swchStatuses = phase c connId QDRcv p (\stats -> rcvSwchStatuses' stats `shouldMatchList` swchStatuses)

rcvSwchStatuses' :: ConnectionStats -> [Maybe RcvSwitchStatus]
rcvSwchStatuses' ConnectionStats {rcvQueuesInfo} = map (\RcvQueueInfo {rcvSwitchStatus} -> rcvSwitchStatus) rcvQueuesInfo

phaseSnd :: AgentClient -> ByteString -> SwitchPhase -> [Maybe SndSwitchStatus] -> ExceptT AgentErrorType IO ()
phaseSnd c connId p swchStatuses = phase c connId QDSnd p (\stats -> sndSwchStatuses' stats `shouldMatchList` swchStatuses)

sndSwchStatuses' :: ConnectionStats -> [Maybe SndSwitchStatus]
sndSwchStatuses' ConnectionStats {sndQueuesInfo} = map (\SndQueueInfo {sndSwitchStatus} -> sndSwitchStatus) sndQueuesInfo

phase :: AgentClient -> ByteString -> QueueDirection -> SwitchPhase -> (ConnectionStats -> Expectation) -> ExceptT AgentErrorType IO ()
phase c connId d p statsExpectation =
  get c >>= \(_, connId', msg) -> do
    liftIO $ connId `shouldBe` connId'
    case msg of
      SWITCH d' p' stats -> liftIO $ do
        d `shouldBe` d'
        p `shouldBe` p'
        statsExpectation stats
      ERR (AGENT A_DUPLICATE) -> phase c connId d p statsExpectation
      r -> do
        liftIO . putStrLn $ "expected: " <> show p <> ", received: " <> show r
        SWITCH {} <- pure r
        pure ()

testSwitchAsync :: HasCallStack => InitialAgentServers -> IO ()
testSwitchAsync servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
  withB' $ \b -> do
    phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
    phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]
  withA' $ \a -> do
    phaseRcv a bId SPConfirmed [Just RSSendingQADD, Nothing]
    phaseRcv a bId SPSecured [Just RSSendingQUSE, Nothing]
  withB' $ \b -> do
    phaseSnd b aId SPSecured [Just SSSendingQTEST, Nothing]
    phaseSnd b aId SPCompleted [Nothing]
  withA' $ \a -> phaseRcv a bId SPCompleted [Nothing]
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId
    exchangeGreetingsMsgId 10 a bId b aId
    testFullSwitch a bId b aId 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

withAgent :: Int -> AgentConfig -> InitialAgentServers -> FilePath -> (AgentClient -> IO a) -> IO a
withAgent clientId cfg' servers dbPath = bracket (getSMPAgentClient' clientId cfg' servers dbPath) disposeAgentClient

sessionSubscribe :: (forall a. (AgentClient -> IO a) -> IO a) -> [ConnId] -> (AgentClient -> ExceptT AgentErrorType IO ()) -> IO ()
sessionSubscribe withC connIds a =
  withC $ \c -> runRight_ $ do
    void $ subscribeConnections c connIds
    r <- a c
    liftIO $ threadDelay 500000
    liftIO $ noMessages c "nothing else should be delivered"
    pure r

testSwitchDelete :: InitialAgentServers -> IO ()
testSwitchDelete servers = do
  a <- getSMPAgentClient' 1 agentCfg servers testDB
  b <- getSMPAgentClient' 2 agentCfg servers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    liftIO $ disposeAgentClient b
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
    deleteConnectionAsync a False bId
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId; _ -> False
    get a =##> \case ("", c, DEL_RCVQ _ _ Nothing) -> c == bId; _ -> False
    get a =##> \case ("", c, DEL_CONN) -> c == bId; _ -> False
    liftIO $ noMessages a "nothing else should be delivered to alice"
  disposeAgentClient a
  disposeAgentClient b

testAbortSwitchStarted :: HasCallStack => InitialAgentServers -> IO ()
testAbortSwitchStarted servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
    -- repeat switch is prohibited
    Left A.CMD {cmdErr = PROHIBITED} <- liftIO . runExceptT $ switchConnectionAsync a "" bId
    -- abort current switch
    stats' <- abortConnectionSwitch a bId
    liftIO $ rcvSwchStatuses' stats' `shouldMatchList` [Nothing]
  withB' $ \b -> do
    phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
    phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]
  withA' $ \a -> do
    get a ##> ("", bId, ERR (AGENT {agentErr = A_QUEUE {queueErr = "QKEY: queue address not found in connection"}}))
    -- repeat switch
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
    phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]

    phaseRcv a bId SPConfirmed [Just RSSendingQADD, Nothing]
    phaseRcv a bId SPSecured [Just RSSendingQUSE, Nothing]

    phaseSnd b aId SPSecured [Just SSSendingQTEST, Nothing]
    phaseSnd b aId SPCompleted [Nothing]

    phaseRcv a bId SPCompleted [Nothing]

    exchangeGreetingsMsgId 12 a bId b aId

    testFullSwitch a bId b aId 18
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

testAbortSwitchStartedReinitiate :: HasCallStack => InitialAgentServers -> IO ()
testAbortSwitchStartedReinitiate servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
    -- abort current switch
    stats' <- abortConnectionSwitch a bId
    liftIO $ rcvSwchStatuses' stats' `shouldMatchList` [Nothing]
    -- repeat switch
    stats'' <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats'' `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
  withB' $ \b -> do
    phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
    liftIO . getInAnyOrder b $
      [ switchPhaseSndP aId SPStarted [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId SPConfirmed [Just SSSendingQKEY, Nothing]
      ]
    phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    liftIO . getInAnyOrder a $
      [ errQueueNotFoundP bId,
        switchPhaseRcvP bId SPConfirmed [Just RSSendingQADD, Nothing]
      ]

    phaseRcv a bId SPSecured [Just RSSendingQUSE, Nothing]

    phaseSnd b aId SPSecured [Just SSSendingQTEST, Nothing]
    phaseSnd b aId SPCompleted [Nothing]

    phaseRcv a bId SPCompleted [Nothing]

    exchangeGreetingsMsgId 12 a bId b aId

    testFullSwitch a bId b aId 18
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

switchPhaseRcvP :: ConnId -> SwitchPhase -> [Maybe RcvSwitchStatus] -> ATransmission 'Agent -> Bool
switchPhaseRcvP cId sphase swchStatuses = switchPhaseP cId QDRcv sphase (\stats -> rcvSwchStatuses' stats == swchStatuses)

switchPhaseSndP :: ConnId -> SwitchPhase -> [Maybe SndSwitchStatus] -> ATransmission 'Agent -> Bool
switchPhaseSndP cId sphase swchStatuses = switchPhaseP cId QDSnd sphase (\stats -> sndSwchStatuses' stats == swchStatuses)

switchPhaseP :: ConnId -> QueueDirection -> SwitchPhase -> (ConnectionStats -> Bool) -> ATransmission 'Agent -> Bool
switchPhaseP cId qd sphase statsP = \case
  (_, cId', APC SAEConn (SWITCH qd' sphase' stats)) -> cId' == cId && qd' == qd && sphase' == sphase && statsP stats
  _ -> False

errQueueNotFoundP :: ConnId -> ATransmission 'Agent -> Bool
errQueueNotFoundP cId = \case
  (_, cId', APC SAEConn (ERR AGENT {agentErr = A_QUEUE {queueErr = "QKEY: queue address not found in connection"}})) -> cId' == cId
  _ -> False

testCannotAbortSwitchSecured :: HasCallStack => InitialAgentServers -> IO ()
testCannotAbortSwitchSecured servers = do
  (aId, bId) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    pure (aId, bId)
  let withA' = sessionSubscribe withA [bId]
      withB' = sessionSubscribe withB [aId]
  withA' $ \a -> do
    stats <- switchConnectionAsync a "" bId
    liftIO $ rcvSwchStatuses' stats `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId SPStarted [Just RSSendingQADD, Nothing]
  withB' $ \b -> do
    phaseSnd b aId SPStarted [Just SSSendingQKEY, Nothing]
    phaseSnd b aId SPConfirmed [Just SSSendingQKEY, Nothing]
  withA' $ \a -> do
    phaseRcv a bId SPConfirmed [Just RSSendingQADD, Nothing]
    phaseRcv a bId SPSecured [Just RSSendingQUSE, Nothing]
    Left A.CMD {cmdErr = PROHIBITED} <- liftIO . runExceptT $ abortConnectionSwitch a bId
    pure ()
  withA $ \a -> withB $ \b -> runRight_ $ do
    subscribeConnection a bId
    subscribeConnection b aId

    phaseSnd b aId SPSecured [Just SSSendingQTEST, Nothing]
    phaseSnd b aId SPCompleted [Nothing]

    phaseRcv a bId SPCompleted [Nothing]

    exchangeGreetingsMsgId 10 a bId b aId

    testFullSwitch a bId b aId 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

testSwitch2Connections :: HasCallStack => InitialAgentServers -> IO ()
testSwitch2Connections servers = do
  (aId1, bId1, aId2, bId2) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId1, bId1) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId1 b aId1
    (aId2, bId2) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId2 b aId2
    pure (aId1, bId1, aId2, bId2)
  let withA' = sessionSubscribe withA [bId1, bId2]
      withB' = sessionSubscribe withB [aId1, aId2]
  withA' $ \a -> do
    stats1 <- switchConnectionAsync a "" bId1
    liftIO $ rcvSwchStatuses' stats1 `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId1 SPStarted [Just RSSendingQADD, Nothing]
    stats2 <- switchConnectionAsync a "" bId2
    liftIO $ rcvSwchStatuses' stats2 `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId2 SPStarted [Just RSSendingQADD, Nothing]
  withB' $ \b -> do
    liftIO . getInAnyOrder b $
      [ switchPhaseSndP aId1 SPStarted [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId1 SPConfirmed [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId2 SPStarted [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId2 SPConfirmed [Just SSSendingQKEY, Nothing]
      ]
  withA' $ \a -> do
    liftIO . getInAnyOrder a $
      [ switchPhaseRcvP bId1 SPConfirmed [Just RSSendingQADD, Nothing],
        switchPhaseRcvP bId1 SPSecured [Just RSSendingQUSE, Nothing],
        switchPhaseRcvP bId2 SPConfirmed [Just RSSendingQADD, Nothing],
        switchPhaseRcvP bId2 SPSecured [Just RSSendingQUSE, Nothing]
      ]
  withB' $ \b -> do
    liftIO . getInAnyOrder b $
      [ switchPhaseSndP aId1 SPSecured [Just SSSendingQTEST, Nothing],
        switchPhaseSndP aId1 SPCompleted [Nothing],
        switchPhaseSndP aId2 SPSecured [Just SSSendingQTEST, Nothing],
        switchPhaseSndP aId2 SPCompleted [Nothing]
      ]
  withA' $ \a -> do
    liftIO . getInAnyOrder a $
      [ switchPhaseRcvP bId1 SPCompleted [Nothing],
        switchPhaseRcvP bId2 SPCompleted [Nothing]
      ]
  withA $ \a -> withB $ \b -> runRight_ $ do
    void $ subscribeConnections a [bId1, bId2]
    void $ subscribeConnections b [aId1, aId2]

    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 10 a bId2 b aId2

    testFullSwitch a bId1 b aId1 16
    testFullSwitch a bId2 b aId2 16
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

testSwitch2ConnectionsAbort1 :: HasCallStack => InitialAgentServers -> IO ()
testSwitch2ConnectionsAbort1 servers = do
  (aId1, bId1, aId2, bId2) <- withA $ \a -> withB $ \b -> runRight $ do
    (aId1, bId1) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId1 b aId1
    (aId2, bId2) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId2 b aId2
    pure (aId1, bId1, aId2, bId2)
  let withA' = sessionSubscribe withA [bId1, bId2]
      withB' = sessionSubscribe withB [aId1, aId2]
  withA' $ \a -> do
    stats1 <- switchConnectionAsync a "" bId1
    liftIO $ rcvSwchStatuses' stats1 `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId1 SPStarted [Just RSSendingQADD, Nothing]
    stats2 <- switchConnectionAsync a "" bId2
    liftIO $ rcvSwchStatuses' stats2 `shouldMatchList` [Just RSSwitchStarted]
    phaseRcv a bId2 SPStarted [Just RSSendingQADD, Nothing]
    -- abort switch of second connection
    stats2' <- abortConnectionSwitch a bId2
    liftIO $ rcvSwchStatuses' stats2' `shouldMatchList` [Nothing]
  withB' $ \b -> do
    liftIO . getInAnyOrder b $
      [ switchPhaseSndP aId1 SPStarted [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId1 SPConfirmed [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId2 SPStarted [Just SSSendingQKEY, Nothing],
        switchPhaseSndP aId2 SPConfirmed [Just SSSendingQKEY, Nothing]
      ]
  withA' $ \a -> do
    liftIO . getInAnyOrder a $
      [ switchPhaseRcvP bId1 SPConfirmed [Just RSSendingQADD, Nothing],
        switchPhaseRcvP bId1 SPSecured [Just RSSendingQUSE, Nothing],
        errQueueNotFoundP bId2
      ]
  withA $ \a -> withB $ \b -> runRight_ $ do
    void $ subscribeConnections a [bId1, bId2]
    void $ subscribeConnections b [aId1, aId2]

    phaseSnd b aId1 SPSecured [Just SSSendingQTEST, Nothing]
    phaseSnd b aId1 SPCompleted [Nothing]

    phaseRcv a bId1 SPCompleted [Nothing]

    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 8 a bId2 b aId2

    testFullSwitch a bId1 b aId1 16
    testFullSwitch a bId2 b aId2 14
  where
    withA :: (AgentClient -> IO a) -> IO a
    withA = withAgent 1 agentCfg servers testDB
    withB :: (AgentClient -> IO a) -> IO a
    withB = withAgent 2 agentCfg servers testDB2

testCreateQueueAuth :: HasCallStack => VersionSMP -> (Maybe BasicAuth, VersionSMP) -> (Maybe BasicAuth, VersionSMP) -> IO Int
testCreateQueueAuth srvVersion clnt1 clnt2 = do
  a <- getClient 1 clnt1 testDB
  b <- getClient 2 clnt2 testDB2
  r <- runRight $ do
    tryError (createConnection a 1 True SCMInvitation Nothing SMSubscribe) >>= \case
      Left (SMP AUTH) -> pure 0
      Left e -> throwError e
      Right (bId, qInfo) ->
        tryError (joinConnection b 1 True qInfo "bob's connInfo" SMSubscribe) >>= \case
          Left (SMP AUTH) -> pure 1
          Left e -> throwError e
          Right aId -> do
            ("", _, CONF confId _ "bob's connInfo") <- get a
            allowConnection a bId confId "alice's connInfo"
            get a ##> ("", bId, CON)
            get b ##> ("", aId, INFO "alice's connInfo")
            get b ##> ("", aId, CON)
            exchangeGreetings a bId b aId
            pure 2
  disposeAgentClient a
  disposeAgentClient b
  pure r
  where
    getClient clientId (clntAuth, clntVersion) db =
      let servers = initAgentServers {smp = userServers [ProtoServerWithAuth testSMPServer clntAuth]}
          smpCfg = (defaultSMPClientConfig :: ProtocolClientConfig SMPVersion) {serverVRange = V.mkVersionRange (prevVersion basicAuthSMPVersion) clntVersion}
          sndAuthAlg = if srvVersion >= authCmdsSMPVersion && clntVersion >= authCmdsSMPVersion then C.AuthAlg C.SX25519 else C.AuthAlg C.SEd25519
       in getSMPAgentClient' clientId agentCfg {smpCfg, sndAuthAlg} servers db

testSMPServerConnectionTest :: ATransport -> Maybe BasicAuth -> SMPServerWithAuth -> IO (Maybe ProtocolTestFailure)
testSMPServerConnectionTest t newQueueBasicAuth srv =
  withSmpServerConfigOn t cfg {newQueueBasicAuth} testPort2 $ \_ -> do
    a <- getSMPAgentClient' 1 agentCfg initAgentServers testDB -- initially passed server is not running
    testProtocolServer a 1 srv

testRatchetAdHash :: HasCallStack => IO ()
testRatchetAdHash =
  withAgentClients2 $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    ad1 <- getConnectionRatchetAdHash a bId
    ad2 <- getConnectionRatchetAdHash b aId
    liftIO $ ad1 `shouldBe` ad2

testDeliveryReceipts :: HasCallStack => IO ()
testDeliveryReceipts =
  withAgentClients2 $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    -- a sends, b receives and sends delivery receipt
    4 <- sendMessage a bId SMP.noMsgFlags "hello"
    get a ##> ("", bId, SENT 4)
    get b =##> \case ("", c, Msg "hello") -> c == aId; _ -> False
    ackMessage b aId 4 $ Just ""
    get a =##> \case ("", c, Rcvd 4) -> c == bId; _ -> False
    ackMessage a bId 5 Nothing
    -- b sends, a receives and sends delivery receipt
    6 <- sendMessage b aId SMP.noMsgFlags "hello too"
    get b ##> ("", aId, SENT 6)
    get a =##> \case ("", c, Msg "hello too") -> c == bId; _ -> False
    ackMessage a bId 6 $ Just ""
    get b =##> \case ("", c, Rcvd 6) -> c == aId; _ -> False
    ackMessage b aId 7 (Just "") `catchError` \e -> liftIO $ e `shouldBe` A.CMD PROHIBITED
    ackMessage b aId 7 Nothing

testDeliveryReceiptsVersion :: HasCallStack => ATransport -> IO ()
testDeliveryReceiptsVersion t = do
  a <- getSMPAgentClient' 1 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB
  b <- getSMPAgentClient' 2 agentCfg {smpAgentVRange = \_ -> mkVersionRange 1 3} initAgentServers testDB2
  withSmpServerStoreMsgLogOn t testPort $ \_ -> do
    (aId, bId) <- runRight $ do
      (aId, bId) <- makeConnection_ PQSupportOff a b
      checkVersion a bId 3
      checkVersion b aId 3
      (4, _) <- A.sendMessage a bId PQEncOff SMP.noMsgFlags "hello"
      get a ##> ("", bId, SENT 4)
      get b =##> \case ("", c, Msg' 4 PQEncOff "hello") -> c == aId; _ -> False
      ackMessage b aId 4 $ Just ""
      liftIO $ noMessages a "no delivery receipt (unsupported version)"
      (5, _) <- A.sendMessage b aId PQEncOff SMP.noMsgFlags "hello too"
      get b ##> ("", aId, SENT 5)
      get a =##> \case ("", c, Msg' 5 PQEncOff "hello too") -> c == bId; _ -> False
      ackMessage a bId 5 $ Just ""
      liftIO $ noMessages b "no delivery receipt (unsupported version)"
      pure (aId, bId)

    disposeAgentClient a
    disposeAgentClient b
    a' <- getSMPAgentClient' 3 agentCfg {smpAgentVRange = supportedSMPAgentVRange} initAgentServers testDB
    b' <- getSMPAgentClient' 4 agentCfg {smpAgentVRange = supportedSMPAgentVRange} initAgentServers testDB2

    runRight_ $ do
      subscribeConnection a' bId
      subscribeConnection b' aId
      exchangeGreetingsMsgId_ PQEncOff 6 a' bId b' aId
      checkVersion a' bId 4
      checkVersion b' aId 4
      (8, PQEncOff) <- A.sendMessage a' bId PQEncOn SMP.noMsgFlags "hello"
      get a' ##> ("", bId, SENT 8)
      get b' =##> \case ("", c, Msg' 8 PQEncOff "hello") -> c == aId; _ -> False
      ackMessage b' aId 8 $ Just ""
      get a' =##> \case ("", c, Rcvd 8) -> c == bId; _ -> False
      ackMessage a' bId 9 Nothing
      (10, PQEncOff) <- A.sendMessage b' aId PQEncOn SMP.noMsgFlags "hello too"
      get b' ##> ("", aId, SENT 10)
      get a' =##> \case ("", c, Msg' 10 PQEncOff "hello too") -> c == bId; _ -> False
      ackMessage a' bId 10 $ Just ""
      get b' =##> \case ("", c, Rcvd 10) -> c == aId; _ -> False
      ackMessage b' aId 11 Nothing
      (12, _) <- A.sendMessage a' bId PQEncOn SMP.noMsgFlags "hello 2"
      get a' ##> ("", bId, SENT 12)
      get b' =##> \case ("", c, Msg' 12 PQEncOff "hello 2") -> c == aId; _ -> False
      ackMessage b' aId 12 $ Just ""
      get a' =##> \case ("", c, Rcvd 12) -> c == bId; _ -> False
      ackMessage a' bId 13 Nothing
    disposeAgentClient a'
    disposeAgentClient b'

testDeliveryReceiptsConcurrent :: HasCallStack => ATransport -> IO ()
testDeliveryReceiptsConcurrent t =
  withSmpServerConfigOn t cfg {msgQueueQuota = 128} testPort $ \_ -> do
    withAgentClients2 $ \a b -> do
      (aId, bId) <- runRight $ makeConnection a b
      t1 <- liftIO getCurrentTime
      concurrently_ (runClient "a" a bId) (runClient "b" b aId)
      t2 <- liftIO getCurrentTime
      diffUTCTime t2 t1 `shouldSatisfy` (< 60)
      liftIO $ noMessages a "nothing else should be delivered to alice"
      liftIO $ noMessages b "nothing else should be delivered to bob"
  where
    runClient :: String -> AgentClient -> ConnId -> IO ()
    runClient _cName client connId = do
      concurrently_ send receive
      where
        numMsgs = 100
        send = runRight_ $
          replicateM_ numMsgs $ do
            void $ sendMessage client connId SMP.noMsgFlags "hello"
        receive =
          runRight_ $
            -- for each sent message: 1 SENT, 1 RCVD, 1 OK for acknowledging RCVD
            -- for each received message: 1 MSG, 1 OK for acknowledging MSG
            receiveLoop (numMsgs * 5)
        receiveLoop :: Int -> ExceptT AgentErrorType IO ()
        receiveLoop 0 = pure ()
        receiveLoop n = do
          r <- getWithTimeout
          case r of
            (_, _, SENT _) -> do
              -- liftIO $ print $ cName <> ": SENT"
              pure ()
            (_, _, MSG MsgMeta {recipient = (msgId, _), integrity = MsgOk} _ _) -> do
              -- liftIO $ print $ cName <> ": MSG " <> show msgId
              ackMessageAsync client (B.pack . show $ n) connId msgId (Just "")
            (_, _, RCVD MsgMeta {recipient = (msgId, _), integrity = MsgOk} _) -> do
              -- liftIO $ print $ cName <> ": RCVD " <> show msgId
              ackMessageAsync client (B.pack . show $ n) connId msgId Nothing
            (_, _, OK) -> do
              -- liftIO $ print $ cName <> ": OK"
              pure ()
            r' -> error $ "unexpected event: " <> show r'
          receiveLoop (n - 1)
        getWithTimeout :: ExceptT AgentErrorType IO (AEntityTransmission 'AEConn)
        getWithTimeout = do
          3000000 `timeout` get client >>= \case
            Just r -> pure r
            _ -> error "timeout"

testTwoUsers :: HasCallStack => IO ()
testTwoUsers = withAgentClients2 $ \a b -> do
  let nc = netCfg initAgentServers
  sessionMode nc `shouldBe` TSMUser
  runRight_ $ do
    (aId1, bId1) <- makeConnectionForUsers a 1 b 1
    exchangeGreetings a bId1 b aId1
    (aId1', bId1') <- makeConnectionForUsers a 1 b 1
    exchangeGreetings a bId1' b aId1'
    a `hasClients` 1
    b `hasClients` 1
    liftIO $ setNetworkConfig a nc {sessionMode = TSMEntity}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 2

    exchangeGreetingsMsgId 6 a bId1 b aId1
    exchangeGreetingsMsgId 6 a bId1' b aId1'
    liftIO $ threadDelay 250000
    liftIO $ setNetworkConfig a nc {sessionMode = TSMUser}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 1

    aUserId2 <- createUser a [noAuthSrv testSMPServer] [noAuthSrv testXFTPServer]
    (aId2, bId2) <- makeConnectionForUsers a aUserId2 b 1
    exchangeGreetings a bId2 b aId2
    (aId2', bId2') <- makeConnectionForUsers a aUserId2 b 1
    exchangeGreetings a bId2' b aId2'
    a `hasClients` 2
    b `hasClients` 1
    liftIO $ setNetworkConfig a nc {sessionMode = TSMEntity}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 4
    exchangeGreetingsMsgId 8 a bId1 b aId1
    exchangeGreetingsMsgId 8 a bId1' b aId1'
    exchangeGreetingsMsgId 6 a bId2 b aId2
    exchangeGreetingsMsgId 6 a bId2' b aId2'
    liftIO $ threadDelay 250000
    liftIO $ setNetworkConfig a nc {sessionMode = TSMUser}
    liftIO $ threadDelay 250000
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", DOWN _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    ("", "", UP _ _) <- nGet a
    a `hasClients` 2
    exchangeGreetingsMsgId 10 a bId1 b aId1
    exchangeGreetingsMsgId 10 a bId1' b aId1'
    exchangeGreetingsMsgId 8 a bId2 b aId2
    exchangeGreetingsMsgId 8 a bId2' b aId2'
  where
    hasClients :: HasCallStack => AgentClient -> Int -> ExceptT AgentErrorType IO ()
    hasClients c n = liftIO $ M.size <$> readTVarIO (smpClients c) `shouldReturn` n

getSMPAgentClient' :: Int -> AgentConfig -> InitialAgentServers -> FilePath -> IO AgentClient
getSMPAgentClient' clientId cfg' initServers dbPath = do
  Right st <- liftIO $ createAgentStore dbPath "" False MCError
  c <- getSMPAgentClient_ clientId cfg' initServers st False
  when (dbNew st) $ withTransaction' st (`SQL.execute_` "INSERT INTO users (user_id) VALUES (1)")
  pure c

testServerMultipleIdentities :: HasCallStack => IO ()
testServerMultipleIdentities =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    (bobId, cReq) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True cReq "bob's connInfo" SMSubscribe
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    exchangeGreetings alice bobId bob aliceId
    -- this saves queue with second server identity
    bob' <- liftIO $ do
      Left (BROKER _ NETWORK) <- runExceptT $ joinConnection bob 1 True secondIdentityCReq "bob's connInfo" SMSubscribe
      disposeAgentClient bob
      getSMPAgentClient' 3 agentCfg initAgentServers testDB2
    subscribeConnection bob' aliceId
    exchangeGreetingsMsgId 6 alice bobId bob' aliceId
  where
    secondIdentityCReq :: ConnectionRequestUri 'CMInvitation
    secondIdentityCReq =
      CRInvitationUri
        connReqData
          { crSmpQueues =
              [ SMPQueueUri
                  supportedSMPClientVRange
                  queueAddr
                    { smpServer = SMPServer "localhost" "5001" (C.KeyHash "\215m\248\251")
                    }
              ]
          }
        testE2ERatchetParams12

exchangeGreetings :: HasCallStack => AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings = exchangeGreetings_ PQEncOn

exchangeGreetings_ :: HasCallStack => PQEncryption -> AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetings_ pqEnc = exchangeGreetingsMsgId_ pqEnc 4

exchangeGreetingsMsgId :: HasCallStack => Int64 -> AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetingsMsgId = exchangeGreetingsMsgId_ PQEncOn

exchangeGreetingsMsgId_ :: HasCallStack => PQEncryption -> Int64 -> AgentClient -> ConnId -> AgentClient -> ConnId -> ExceptT AgentErrorType IO ()
exchangeGreetingsMsgId_ pqEnc msgId alice bobId bob aliceId = do
  msgId1 <- A.sendMessage alice bobId pqEnc SMP.noMsgFlags "hello"
  liftIO $ msgId1 `shouldBe` (msgId, pqEnc)
  get alice ##> ("", bobId, SENT msgId)
  get bob =##> \case ("", c, Msg' mId pq "hello") -> c == aliceId && mId == msgId && pq == pqEnc; _ -> False
  ackMessage bob aliceId msgId Nothing
  msgId2 <- A.sendMessage bob aliceId pqEnc SMP.noMsgFlags "hello too"
  let msgId' = msgId + 1
  liftIO $ msgId2 `shouldBe` (msgId', pqEnc)
  get bob ##> ("", aliceId, SENT msgId')
  get alice =##> \case ("", c, Msg' mId pq "hello too") -> c == bobId && mId == msgId' && pq == pqEnc; _ -> False
  ackMessage alice bobId msgId' Nothing

exchangeGreetingsMsgIds :: HasCallStack => AgentClient -> ConnId -> Int64 -> AgentClient -> ConnId -> Int64 -> ExceptT AgentErrorType IO ()
exchangeGreetingsMsgIds alice bobId aliceMsgId bob aliceId bobMsgId = do
  msgId1 <- sendMessage alice bobId SMP.noMsgFlags "hello"
  liftIO $ msgId1 `shouldBe` aliceMsgId
  get alice ##> ("", bobId, SENT aliceMsgId)
  get bob =##> \case ("", c, Msg "hello") -> c == aliceId; _ -> False
  ackMessage bob aliceId bobMsgId Nothing
  msgId2 <- sendMessage bob aliceId SMP.noMsgFlags "hello too"
  let aliceMsgId' = aliceMsgId + 1
      bobMsgId' = bobMsgId + 1
  liftIO $ msgId2 `shouldBe` bobMsgId'
  get bob ##> ("", aliceId, SENT bobMsgId')
  get alice =##> \case ("", c, Msg "hello too") -> c == bobId; _ -> False
  ackMessage alice bobId aliceMsgId' Nothing
