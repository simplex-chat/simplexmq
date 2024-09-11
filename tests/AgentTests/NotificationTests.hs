{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module AgentTests.NotificationTests where

-- import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)
import AgentTests.FunctionalAPITests
  ( agentCfgVPrevPQ,
    createConnection,
    exchangeGreetings,
    get,
    joinConnection,
    makeConnection,
    nGet,
    runRight,
    runRight_,
    sendMessage,
    switchComplete,
    testServerMatrix2,
    withAgent,
    withAgentClients2,
    withAgentClients3,
    withAgentClientsCfg2,
    withAgentClientsCfgServers2,
    (##>),
    (=##>),
    pattern CON,
    pattern CONF,
    pattern INFO,
    pattern Msg,
    pattern SENT,
  )
import Control.Concurrent (ThreadId, killThread, threadDelay)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader (runReaderT)
import Control.Monad.Trans.Except
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (bimap, first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.List.NonEmpty as L
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple.QQ (sql)
import NtfClient
import SMPAgentClient (agentCfg, initAgentServers, initAgentServers2, testDB, testDB2, testNtfServer, testNtfServer2)
import SMPClient (cfg, cfgVPrev, testPort, testPort2, testStoreLogFile2, withSmpServer, withSmpServerConfigOn, withSmpServerStoreLogOn)
import Simplex.Messaging.Agent hiding (createConnection, joinConnection, sendMessage)
import Simplex.Messaging.Agent.Client (ProtocolTestFailure (..), ProtocolTestStep (..), withStore')
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig, Env (..), InitialAgentServers)
import Simplex.Messaging.Agent.Protocol hiding (CON, CONF, INFO, SENT)
import Simplex.Messaging.Agent.Store.SQLite (closeSQLiteStore, getSavedNtfToken, reopenSQLiteStore, withTransaction)
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Env (NtfServerConfig (..))
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Types (NtfTknAction (..), NtfToken (..))
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (ErrorType (AUTH), MsgFlags (MsgFlags), NtfServer, ProtocolServer (..), SMPMsgMeta (..), SubscriptionMode (..))
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM (ServerConfig (..))
import Simplex.Messaging.Transport (ATransport)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec
import UnliftIO

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists filePath = do
  fileExists <- doesFileExist filePath
  when fileExists $ removeFile filePath

notificationTests :: ATransport -> Spec
notificationTests t = do
  describe "Managing notification tokens" $ do
    it "should register and verify notification token" $
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testNotificationToken apns
    it "should allow repeated registration with the same credentials" $
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testNtfTokenRepeatRegistration apns
    it "should allow the second registration with different credentials and delete the first after verification" $
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testNtfTokenSecondRegistration apns
    it "should verify token after notification server is restarted" $
      withAPNSMockServer $ \apns ->
        testNtfTokenServerRestart t apns
    it "should re-verify token after notification server is restarted" $
      withAPNSMockServer $ \apns ->
        testNtfTokenServerRestartReverify t apns
    it "should re-verify token after notification server is restarted when first request timed-out" $
      withAPNSMockServer $ \apns ->
        testNtfTokenServerRestartReverifyTimeout t apns
    it "should re-register token when notification server is restarted" $
      withAPNSMockServer $ \apns ->
        testNtfTokenServerRestartReregister t apns
    it "should re-register token when notification server is restarted when first request timed-out" $
      withAPNSMockServer $ \apns ->
        testNtfTokenServerRestartReregisterTimeout t apns
    it "should work with multiple configured servers" $
      withAPNSMockServer $ \apns ->
        testNtfTokenMultipleServers t apns
    it "should keep working with active token until replaced" $
      withAPNSMockServer $ \apns ->
        testNtfTokenChangeServers t apns
  describe "notification server tests" $ do
    it "should pass" $ testRunNTFServerTests t testNtfServer `shouldReturn` Nothing
    let srv1 = testNtfServer {keyHash = "1234"}
    it "should fail with incorrect fingerprint" $ do
      testRunNTFServerTests t srv1 `shouldReturn` Just (ProtocolTestFailure TSConnect $ BROKER (B.unpack $ strEncode srv1) NETWORK)
  describe "Managing notification subscriptions" $ do
    describe "should create notification subscription for existing connection" $
      testNtfMatrix t testNotificationSubscriptionExistingConnection
    describe "should create notification subscription for new connection" $
      testNtfMatrix t testNotificationSubscriptionNewConnection
    it "should change notifications mode" $
      withSmpServer t $
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testChangeNotificationsMode apns
    it "should change token" $
      withSmpServer t $
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testChangeToken apns
  describe "Notifications server store log" $
    it "should save and restore tokens and subscriptions" $
      withSmpServer t $
        withAPNSMockServer $ \apns ->
          testNotificationsStoreLog t apns
  describe "Notifications after SMP server restart" $
    it "should resume subscriptions after SMP server is restarted" $
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testNotificationsSMPRestart t apns
  describe "Notifications after SMP server restart" $
    it "should resume batched subscriptions after SMP server is restarted" $
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testNotificationsSMPRestartBatch 100 t apns
  describe "should switch notifications to the new queue" $
    testServerMatrix2 t $ \servers ->
      withAPNSMockServer $ \apns ->
        withNtfServer t $ testSwitchNotifications servers apns
  it "should keep sending notifications for old token" $
    withSmpServer t $
      withAPNSMockServer $ \apns ->
        withNtfServerOn t ntfTestPort $
          testNotificationsOldToken apns
  it "should update server from new token" $
    withSmpServer t $
      withAPNSMockServer $ \apns ->
        withNtfServerOn t ntfTestPort2 . withNtfServerThreadOn t ntfTestPort $ \ntf ->
          testNotificationsNewToken apns ntf

testNtfMatrix :: HasCallStack => ATransport -> (APNSMockServer -> AgentMsgId -> AgentClient -> AgentClient -> IO ()) -> Spec
testNtfMatrix t runTest = do
  describe "next and current" $ do
    it "curr servers; curr clients" $ runNtfTestCfg t 1 cfg ntfServerCfg agentCfg agentCfg runTest
    it "curr servers; prev clients" $ runNtfTestCfg t 3 cfg ntfServerCfg agentCfgVPrevPQ agentCfgVPrevPQ runTest
    it "prev servers; prev clients" $ runNtfTestCfg t 3 cfgVPrev ntfServerCfgVPrev agentCfgVPrevPQ agentCfgVPrevPQ runTest
    it "prev servers; curr clients" $ runNtfTestCfg t 1 cfgVPrev ntfServerCfgVPrev agentCfg agentCfg runTest
    -- servers can be upgraded in any order
    it "servers: curr SMP, prev NTF; prev clients" $ runNtfTestCfg t 3 cfg ntfServerCfgVPrev agentCfgVPrevPQ agentCfgVPrevPQ runTest
    it "servers: prev SMP, curr NTF; prev clients" $ runNtfTestCfg t 3 cfgVPrev ntfServerCfg agentCfgVPrevPQ agentCfgVPrevPQ runTest
    -- one of two clients can be upgraded
    it "servers: curr SMP, curr NTF; clients: curr/prev" $ runNtfTestCfg t 3 cfg ntfServerCfg agentCfg agentCfgVPrevPQ runTest
    it "servers: curr SMP, curr NTF; clients: prev/curr" $ runNtfTestCfg t 3 cfg ntfServerCfg agentCfgVPrevPQ agentCfg runTest

runNtfTestCfg :: HasCallStack => ATransport -> AgentMsgId -> ServerConfig -> NtfServerConfig -> AgentConfig -> AgentConfig -> (APNSMockServer -> AgentMsgId -> AgentClient -> AgentClient -> IO ()) -> IO ()
runNtfTestCfg t baseId smpCfg ntfCfg aCfg bCfg runTest = do
  withSmpServerConfigOn t smpCfg testPort $ \_ ->
    withAPNSMockServer $ \apns ->
      withNtfServerCfg ntfCfg {transports = [(ntfTestPort, t)]} $ \_ ->
        withAgentClientsCfg2 aCfg bCfg $ runTest apns baseId
  threadDelay 100000

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  withAgent 1 agentCfg initAgentServers testDB $ \a -> runRight_ $ do
    let tkn = DeviceToken PPApnsTest "abcd"
    NTRegistered <- registerNtfToken a tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken a tkn nonce verification
    NTActive <- checkNtfToken a tkn
    deleteNtfToken a tkn
    -- agent deleted this token
    Left (CMD PROHIBITED _) <- tryE $ checkNtfToken a tkn
    pure ()

(.->) :: J.Value -> J.Key -> ExceptT AgentErrorType IO ByteString
v .-> key = do
  J.Object o <- pure v
  liftEither . bimap INTERNAL (U.decodeLenient . encodeUtf8) $ JT.parseEither (J..: key) o

-- logCfg :: LogConfig
-- logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

testNtfTokenRepeatRegistration :: APNSMockServer -> IO ()
testNtfTokenRepeatRegistration APNSMockServer {apnsQ} = do
  -- setLogLevel LogError -- LogDebug
  -- withGlobalLogging logCfg $ do
  withAgent 1 agentCfg initAgentServers testDB $ \a -> runRight_ $ do
    let tkn = DeviceToken PPApnsTest "abcd"
    NTRegistered <- registerNtfToken a tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    NTRegistered <- registerNtfToken a tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    _ <- ntfData' .-> "verification"
    _ <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk
    -- can still use the first verification code, it is the same after decryption
    verifyNtfToken a tkn nonce verification
    NTActive <- checkNtfToken a tkn
    pure ()

testNtfTokenSecondRegistration :: APNSMockServer -> IO ()
testNtfTokenSecondRegistration APNSMockServer {apnsQ} =
  -- setLogLevel LogError -- LogDebug
  -- withGlobalLogging logCfg $ do
  withAgentClients2 $ \a a' -> runRight_ $ do
    let tkn = DeviceToken PPApnsTest "abcd"
    NTRegistered <- registerNtfToken a tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken a tkn nonce verification

    NTRegistered <- registerNtfToken a' tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    verification' <- ntfData' .-> "verification"
    nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk

    -- at this point the first token is still active
    NTActive <- checkNtfToken a tkn
    -- and the second is not yet verified
    liftIO $ threadDelay 50000
    NTConfirmed <- checkNtfToken a' tkn
    -- now the second token registration is verified
    verifyNtfToken a' tkn nonce' verification'
    -- the first registration is removed
    Left (NTF _ AUTH) <- tryE $ checkNtfToken a tkn
    -- and the second is active
    NTActive <- checkNtfToken a' tkn
    pure ()

testNtfTokenServerRestart :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestart t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  ntfData <- withAgent 1 agentCfg initAgentServers testDB $ \a ->
    withNtfServerStoreLog t $ \_ -> runRight $ do
      NTRegistered <- registerNtfToken a tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
      pure ntfData
  -- the new agent is created as otherwise when running the tests in CI the old agent was keeping the connection to the server
  threadDelay 1000000
  withAgent 2 agentCfg initAgentServers testDB $ \a' ->
    -- server stopped before token is verified, so now the attempt to verify it will return AUTH error but re-register token,
    -- so that repeat verification happens without restarting the clients, when notification arrives
    withNtfServerStoreLog t $ \_ -> runRight_ $ do
      verification <- ntfData .-> "verification"
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      verifyNtfToken a' tkn nonce verification
      NTActive <- checkNtfToken a' tkn
      pure ()

testNtfTokenServerRestartReverify :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestartReverify t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  withAgent 1 agentCfg initAgentServers testDB $ \a -> do
    ntfData <- withNtfServerStoreLog t $ \_ -> runRight $ do
      NTRegistered <- registerNtfToken a tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
      pure ntfData
    runRight_ $ do
      verification <- ntfData .-> "verification"
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      Left (BROKER _ NETWORK) <- tryE $ verifyNtfToken a tkn nonce verification
      pure ()
  threadDelay 1000000
  withAgent 2 agentCfg initAgentServers testDB $ \a' ->
    -- server stopped before token is verified, so now the attempt to verify it will return AUTH error but re-register token,
    -- so that repeat verification happens without restarting the clients, when notification arrives
    withNtfServerStoreLog t $ \_ -> runRight_ $ do
      NTActive <- registerNtfToken a' tkn NMPeriodic
      NTActive <- checkNtfToken a' tkn
      pure ()

testNtfTokenServerRestartReverifyTimeout :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestartReverifyTimeout t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  withAgent 1 agentCfg initAgentServers testDB $ \a@AgentClient {agentEnv = Env {store}} -> do
    (nonce, verification) <- withNtfServerStoreLog t $ \_ -> runRight $ do
      NTRegistered <- registerNtfToken a tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
      verification <- ntfData .-> "verification"
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      verifyNtfToken a tkn nonce verification
      pure (nonce, verification)
    -- this emulates the situation when server verified token but the client did not receive the response
    Just NtfToken {ntfTknStatus = NTActive, ntfTknAction = Just NTACheck, ntfDhSecret = Just dhSecret} <- withTransaction store getSavedNtfToken
    Right code <- pure $ NtfRegCode <$> C.cbDecrypt dhSecret nonce verification
    withTransaction store $ \db ->
      DB.execute
        db
        [sql|
          UPDATE ntf_tokens
          SET tkn_status = ?, tkn_action = ?
          WHERE provider = ? AND device_token = ?
        |]
        (NTConfirmed, Just (NTAVerify code), PPApnsTest, "abcd" :: ByteString)
    Just NtfToken {ntfTknStatus = NTConfirmed, ntfTknAction = Just (NTAVerify _)} <- withTransaction store getSavedNtfToken
    pure ()
  threadDelay 1000000
  withAgent 2 agentCfg initAgentServers testDB $ \a' ->
    -- server stopped before token is verified, so now the attempt to verify it will return AUTH error but re-register token,
    -- so that repeat verification happens without restarting the clients, when notification arrives
    withNtfServerStoreLog t $ \_ -> runRight_ $ do
      NTActive <- registerNtfToken a' tkn NMPeriodic
      NTActive <- checkNtfToken a' tkn
      pure ()

testNtfTokenServerRestartReregister :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestartReregister t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  withAgent 1 agentCfg initAgentServers testDB $ \a ->
    withNtfServerStoreLog t $ \_ -> runRight $ do
      NTRegistered <- registerNtfToken a tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just _}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
  -- the new agent is created as otherwise when running the tests in CI the old agent was keeping the connection to the server
  threadDelay 1000000
  withAgent 2 agentCfg initAgentServers testDB $ \a' ->
    -- server stopped before token is verified, and client might have lost verification notification.
    -- so that repeat registration happens when client is restarted.
    withNtfServerStoreLog t $ \_ -> runRight_ $ do
      NTRegistered <- registerNtfToken a' tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
      verification <- ntfData .-> "verification"
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      verifyNtfToken a' tkn nonce verification
      NTActive <- checkNtfToken a' tkn
      pure ()

testNtfTokenServerRestartReregisterTimeout :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestartReregisterTimeout t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  withAgent 1 agentCfg initAgentServers testDB $ \a@AgentClient {agentEnv = Env {store}} -> do
    withNtfServerStoreLog t $ \_ -> runRight $ do
      NTRegistered <- registerNtfToken a tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just _}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
    -- this emulates the situation when server registered token but the client did not receive the response
    withTransaction store $ \db ->
      DB.execute
        db
        [sql|
          UPDATE ntf_tokens
          SET tkn_id = NULL, tkn_dh_secret = NULL, tkn_status = ?, tkn_action = ?
          WHERE provider = ? AND device_token = ?
        |]
        (NTNew, Just NTARegister, PPApnsTest, "abcd" :: ByteString)
    Just NtfToken {ntfTokenId = Nothing, ntfTknStatus = NTNew, ntfTknAction = Just NTARegister} <- withTransaction store getSavedNtfToken
    pure ()
  threadDelay 1000000
  withAgent 2 agentCfg initAgentServers testDB $ \a' ->
    -- server stopped before token is verified, and client might have lost verification notification.
    -- so that repeat registration happens when client is restarted.
    withNtfServerStoreLog t $ \_ -> runRight_ $ do
      NTRegistered <- registerNtfToken a' tkn NMPeriodic
      APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
        atomically $ readTBQueue apnsQ
      liftIO $ sendApnsResponse APNSRespOk
      verification <- ntfData .-> "verification"
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      verifyNtfToken a' tkn nonce verification
      NTActive <- checkNtfToken a' tkn
      pure ()

getTestNtfTokenPort :: AgentClient -> AE String
getTestNtfTokenPort a =
  ExceptT (runExceptT (withStore' a getSavedNtfToken) `runReaderT` agentEnv a) >>= \case
    Just NtfToken {ntfServer = ProtocolServer {port}} -> pure port
    Nothing -> error "no active NtfToken"

testNtfTokenMultipleServers :: ATransport -> APNSMockServer -> IO ()
testNtfTokenMultipleServers t APNSMockServer {apnsQ} = do
  let tkn = DeviceToken PPApnsTest "abcd"
  withAgent 1 agentCfg initAgentServers2 testDB $ \a ->
    withNtfServerThreadOn t ntfTestPort $ \ntf ->
      withNtfServerThreadOn t ntfTestPort2 $ \ntf2 -> runRight_ $ do
        -- register a new token, the agent picks a server and stores its choice
        NTRegistered <- registerNtfToken a tkn NMPeriodic
        APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
          atomically $ readTBQueue apnsQ
        verification <- ntfData .-> "verification"
        nonce <- C.cbNonce <$> ntfData .-> "nonce"
        liftIO $ sendApnsResponse APNSRespOk
        verifyNtfToken a tkn nonce verification
        NTActive <- checkNtfToken a tkn
        -- shut down the "other" server
        port <- getTestNtfTokenPort a
        liftIO . killThread $ if port == ntfTestPort then ntf2 else ntf
        -- still works
        NTActive <- checkNtfToken a tkn
        liftIO . killThread $ if port == ntfTestPort then ntf else ntf2
        -- negative test, the correct server is now gone
        Left _ <- tryError (checkNtfToken a tkn)
        pure ()

testNtfTokenChangeServers :: ATransport -> APNSMockServer -> IO ()
testNtfTokenChangeServers t APNSMockServer {apnsQ} =
  withNtfServerThreadOn t ntfTestPort $ \ntf -> do
    tkn1 <- withAgent 1 agentCfg initAgentServers testDB $ \a -> runRight $ do
      tkn <- registerTestToken a "abcd" NMInstant apnsQ
      NTActive <- checkNtfToken a tkn
      liftIO $ setNtfServers a [testNtfServer2]
      NTActive <- checkNtfToken a tkn -- still works on old server
      pure tkn

    threadDelay 1000000

    withAgent 2 agentCfg initAgentServers testDB $ \a -> do
      runRight_ $ do
        getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort
        NTActive <- checkNtfToken a tkn1
        liftIO $ setNtfServers a [testNtfServer2] -- just change configured server list
        getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort -- not yet changed
        -- trigger token replace
        tkn2 <- registerTestToken a "xyzw" NMInstant apnsQ
        getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort -- not yet changed
        deleteNtfToken a tkn2 -- force server switch
        Left BROKER {brokerErr = NETWORK} <- tryError $ registerTestToken a "qwer" NMInstant apnsQ -- ok, it's down for now
        getTestNtfTokenPort a >>= \port2 -> liftIO $ port2 `shouldBe` ntfTestPort2 -- but the token got updated
      killThread ntf
      withNtfServerOn t ntfTestPort2 $ runRight_ $ do
        liftIO $ threadDelay 1000000 -- for notification server to reconnect
        tkn <- registerTestToken a "qwer" NMInstant apnsQ
        checkNtfToken a tkn >>= \r -> liftIO $ r `shouldBe` NTActive

testRunNTFServerTests :: ATransport -> NtfServer -> IO (Maybe ProtocolTestFailure)
testRunNTFServerTests t srv =
  withNtfServerOn t ntfTestPort $
    withAgent 1 agentCfg initAgentServers testDB $ \a ->
      testProtocolServer a 1 $ ProtoServerWithAuth srv Nothing

testNotificationSubscriptionExistingConnection :: APNSMockServer -> AgentMsgId -> AgentClient -> AgentClient -> IO ()
testNotificationSubscriptionExistingConnection APNSMockServer {apnsQ} baseId alice@AgentClient {agentEnv = Env {config = aliceCfg, store}} bob = do
  (bobId, aliceId, nonce, message) <- runRight $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    (aliceId, _sqSecured) <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- register notification token
    let tkn = DeviceToken PPApnsTest "abcd"
    NTRegistered <- registerNtfToken alice tkn NMInstant
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    vNonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken alice tkn vNonce verification
    NTActive <- checkNtfToken alice tkn
    -- send message
    liftIO $ threadDelay 250000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    -- notification
    (nonce, message) <- messageNotification apnsQ
    pure (bobId, aliceId, nonce, message)

  -- alice client already has subscription for the connection
  Left (CMD PROHIBITED _) <- runExceptT $ getNotificationMessage alice nonce message

  threadDelay 500000
  suspendAgent alice 0
  closeSQLiteStore store
  threadDelay 1000000
  putStrLn "before opening the database from another agent"

  -- aliceNtf client doesn't have subscription and is allowed to get notification message
  withAgent 3 aliceCfg initAgentServers testDB $ \aliceNtf -> runRight_ $ do
    (_, Just SMPMsgMeta {msgFlags = MsgFlags True}) <- getNotificationMessage aliceNtf nonce message
    pure ()

  threadDelay 1000000
  putStrLn "after closing the database in another agent"
  reopenSQLiteStore store
  foregroundAgent alice
  threadDelay 500000

  runRight_ $ do
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    -- delete notification subscription
    toggleConnectionNtfs alice bobId False
    liftIO $ threadDelay 500000
    -- send message
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    -- no notifications should follow
    noNotification apnsQ
  where
    msgId = subtract baseId

testNotificationSubscriptionNewConnection :: HasCallStack => APNSMockServer -> AgentMsgId -> AgentClient -> AgentClient -> IO ()
testNotificationSubscriptionNewConnection APNSMockServer {apnsQ} baseId alice bob =
  runRight_ $ do
    -- alice registers notification token
    DeviceToken {} <- registerTestToken alice "abcd" NMInstant apnsQ
    -- bob registers notification token
    DeviceToken {} <- registerTestToken bob "bcde" NMInstant apnsQ
    -- establish connection
    liftIO $ threadDelay 50000
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    liftIO $ threadDelay 1000000
    (aliceId, _sqSecured) <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    liftIO $ threadDelay 750000
    void $ messageNotificationData alice apnsQ
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    liftIO $ threadDelay 500000
    allowConnection alice bobId confId "alice's connInfo"
    void $ messageNotificationData bob apnsQ
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    when (baseId == 3) $ void $ messageNotificationData alice apnsQ
    get alice ##> ("", bobId, CON)
    when (baseId == 3) $ void $ messageNotificationData bob apnsQ
    get bob ##> ("", aliceId, CON)
    -- bob sends message
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    -- alice sends message
    2 <- msgId <$> sendMessage alice bobId (SMP.MsgFlags True) "hey there"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    void $ messageNotificationData bob apnsQ
    get bob =##> \case ("", c, Msg "hey there") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 2) Nothing
    -- no unexpected notifications should follow
    noNotification apnsQ
  where
    msgId = subtract baseId

registerTestToken :: AgentClient -> ByteString -> NotificationsMode -> TBQueue APNSMockRequest -> ExceptT AgentErrorType IO DeviceToken
registerTestToken a token mode apnsQ = do
  let tkn = DeviceToken PPApnsTest token
  NTRegistered <- registerNtfToken a tkn mode
  Just APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
    timeout 1000000 . atomically $ readTBQueue apnsQ
  verification' <- ntfData' .-> "verification"
  nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
  liftIO $ sendApnsResponse' APNSRespOk
  verifyNtfToken a tkn nonce' verification'
  NTActive <- checkNtfToken a tkn
  pure tkn

testChangeNotificationsMode :: APNSMockServer -> IO ()
testChangeNotificationsMode APNSMockServer {apnsQ} =
  withAgentClients2 $ \alice bob -> runRight_ $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    (aliceId, sqSecured) <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    liftIO $ sqSecured `shouldBe` True
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- register notification token, set mode to NMInstant
    tkn <- registerTestToken alice "abcd" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    -- set mode to NMPeriodic
    NTActive <- registerNtfToken alice tkn NMPeriodic
    -- send message, no notification
    liftIO $ threadDelay 750000
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    noNotification apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 2) Nothing
    -- set mode to NMInstant
    NTActive <- registerNtfToken alice tkn NMInstant
    -- send message, receive notification
    liftIO $ threadDelay 500000
    3 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello there") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 3) Nothing
    -- turn off notifications
    deleteNtfToken alice tkn
    -- send message, no notification
    liftIO $ threadDelay 500000
    4 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "why hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    noNotification apnsQ
    get alice =##> \case ("", c, Msg "why hello there") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 4) Nothing
    -- turn on notifications, set mode to NMInstant
    void $ registerTestToken alice "abcd" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    5 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hey"
    get bob ##> ("", aliceId, SENT $ baseId + 5)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hey") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 5) Nothing
    -- no notifications should follow
    noNotification apnsQ
  where
    baseId = 1
    msgId = subtract baseId

testChangeToken :: APNSMockServer -> IO ()
testChangeToken APNSMockServer {apnsQ} = withAgent 1 agentCfg initAgentServers testDB2 $ \bob -> do
  (aliceId, bobId) <- withAgent 2 agentCfg initAgentServers testDB $ \alice -> runRight $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    (aliceId, sqSecured) <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    liftIO $ sqSecured `shouldBe` True
    ("", _, CONF confId _ "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, CON)
    -- register notification token, set mode to NMInstant
    void $ registerTestToken alice "abcd" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    pure (aliceId, bobId)

  withAgent 3 agentCfg initAgentServers testDB $ \alice1 -> runRight_ $ do
    subscribeConnection alice1 bobId
    -- change notification token
    void $ registerTestToken alice1 "bcde" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    void $ messageNotificationData alice1 apnsQ
    get alice1 =##> \case ("", c, Msg "hello there") -> c == bobId; _ -> False
    ackMessage alice1 bobId (baseId + 2) Nothing
    -- no notifications should follow
    noNotification apnsQ
  where
    baseId = 1
    msgId = subtract baseId

testNotificationsStoreLog :: ATransport -> APNSMockServer -> IO ()
testNotificationsStoreLog t APNSMockServer {apnsQ} = withAgentClients2 $ \alice bob -> do
  (aliceId, bobId) <- withNtfServerStoreLog t $ \threadId -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    2 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT 2)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId 2 Nothing
    liftIO $ killThread threadId
    pure (aliceId, bobId)

  liftIO $ threadDelay 250000

  withNtfServerStoreLog t $ \threadId -> runRight_ $ do
    liftIO $ threadDelay 250000
    3 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT 3)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    liftIO $ killThread threadId

testNotificationsSMPRestart :: ATransport -> APNSMockServer -> IO ()
testNotificationsSMPRestart t APNSMockServer {apnsQ} = withAgentClients2 $ \alice bob -> do
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \threadId -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    2 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT 2)
    void $ messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId 2 Nothing
    liftIO $ killThread threadId
    pure (aliceId, bobId)

  runRight_ @AgentErrorType $ do
    nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
    nGet bob =##> \case ("", "", DOWN _ [c]) -> c == aliceId; _ -> False

  withSmpServerStoreLogOn t testPort $ \threadId -> runRight_ $ do
    nGet alice =##> \case ("", "", UP _ [c]) -> c == bobId; _ -> False
    nGet bob =##> \case ("", "", UP _ [c]) -> c == aliceId; _ -> False
    liftIO $ threadDelay 1000000
    3 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT 3)
    _ <- messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    liftIO $ killThread threadId

testNotificationsSMPRestartBatch :: Int -> ATransport -> APNSMockServer -> IO ()
testNotificationsSMPRestartBatch n t APNSMockServer {apnsQ} =
  withAgentClientsCfgServers2 agentCfg agentCfg initAgentServers2 $ \a b -> do
    threadDelay 1000000
    conns <- runServers $ do
      conns <- replicateM (n :: Int) $ makeConnection a b
      _ <- registerTestToken a "abcd" NMInstant apnsQ
      liftIO $ threadDelay 5000000
      forM_ conns $ \(aliceId, bobId) -> do
        msgId <- sendMessage b aliceId (SMP.MsgFlags True) "hello"
        get b ##> ("", aliceId, SENT msgId)
        void $ messageNotificationData a apnsQ
        get a =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
        ackMessage a bobId msgId Nothing
      pure conns

    runRight_ @AgentErrorType $ do
      ("", "", DOWN _ bcs1) <- nGet a
      ("", "", DOWN _ bcs2) <- nGet a
      liftIO $ length (bcs1 <> bcs2) `shouldBe` length conns
      ("", "", DOWN _ acs1) <- nGet b
      ("", "", DOWN _ acs2) <- nGet b
      liftIO $ length (acs1 <> acs2) `shouldBe` length conns

    runServers $ do
      ("", "", UP _ bcs1) <- nGet a
      ("", "", UP _ bcs2) <- nGet a
      liftIO $ length (bcs1 <> bcs2) `shouldBe` length conns
      ("", "", UP _ acs1) <- nGet b
      ("", "", UP _ acs2) <- nGet b
      liftIO $ length (acs1 <> acs2) `shouldBe` length conns
      liftIO $ threadDelay 1500000
      forM_ conns $ \(aliceId, bobId) -> do
        msgId <- sendMessage b aliceId (SMP.MsgFlags True) "hello again"
        get b ##> ("", aliceId, SENT msgId)
        _ <- messageNotificationData a apnsQ
        get a =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
  where
    runServers :: ExceptT AgentErrorType IO a -> IO a
    runServers a = do
      withSmpServerStoreLogOn t testPort $ \t1 -> do
        res <- withSmpServerConfigOn t (cfg :: ServerConfig) {storeLogFile = Just testStoreLogFile2} testPort2 $ \t2 ->
          runRight a `finally` killThread t2
        killThread t1
        pure res

testSwitchNotifications :: InitialAgentServers -> APNSMockServer -> IO ()
testSwitchNotifications servers APNSMockServer {apnsQ} =
  withAgentClientsCfgServers2 agentCfg agentCfg servers $ \a b -> runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetings a bId b aId
    _ <- registerTestToken a "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    let testMessage msg = do
          msgId <- sendMessage b aId (SMP.MsgFlags True) msg
          get b ##> ("", aId, SENT msgId)
          void $ messageNotificationData a apnsQ
          get a =##> \case ("", c, Msg msg') -> c == bId && msg == msg'; _ -> False
          ackMessage a bId msgId Nothing
    testMessage "hello"
    _ <- switchConnectionAsync a "" bId
    switchComplete a bId b aId
    liftIO $ threadDelay 500000
    testMessage "hello again"

testNotificationsOldToken :: APNSMockServer -> IO ()
testNotificationsOldToken APNSMockServer {apnsQ} =
  withAgentClients3 $ \a b c -> runRight_ $ do
    (abId, baId) <- makeConnection a b
    let testMessageAB = testMessage_ apnsQ a abId b baId
    _ <- registerTestToken a "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    testMessageAB "hello"
    -- change server
    liftIO $ setNtfServers a [testNtfServer2] -- server 2 isn't running now, don't use
    -- replacing token keeps server
    _ <- registerTestToken a "xyzw" NMInstant apnsQ
    getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort
    testMessageAB "still there"
    -- new connections keep server
    (acId, caId) <- makeConnection a c
    let testMessageAC = testMessage_ apnsQ a acId c caId
    testMessageAC "greetings"

testNotificationsNewToken :: APNSMockServer -> ThreadId -> IO ()
testNotificationsNewToken APNSMockServer {apnsQ} oldNtf =
  withAgentClients3 $ \a b c -> runRight_ $ do
    (abId, baId) <- makeConnection a b
    let testMessageAB = testMessage_ apnsQ a abId b baId
    tkn <- registerTestToken a "abcd" NMInstant apnsQ
    getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort
    liftIO $ threadDelay 250000
    testMessageAB "hello"
    -- switch
    liftIO $ setNtfServers a [testNtfServer2]
    deleteNtfToken a tkn
    _ <- registerTestToken a "abcd" NMInstant apnsQ
    getTestNtfTokenPort a >>= \port -> liftIO $ port `shouldBe` ntfTestPort2
    liftIO $ threadDelay 250000
    liftIO $ killThread oldNtf
    -- -- back to work
    testMessageAB "hello again"
    (acId, caId) <- makeConnection a c
    let testMessageAC = testMessage_ apnsQ a acId c caId
    testMessageAC "greetings"

testMessage_ :: HasCallStack => TBQueue APNSMockRequest -> AgentClient -> ConnId -> AgentClient -> ConnId -> SMP.MsgBody -> ExceptT AgentErrorType IO ()
testMessage_ apnsQ a aId b bId msg = do
  msgId <- sendMessage b aId (SMP.MsgFlags True) msg
  get b ##> ("", aId, SENT msgId)
  void $ messageNotificationData a apnsQ
  get a =##> \case ("", c, Msg msg') -> c == bId && msg == msg'; _ -> False
  ackMessage a bId msgId Nothing

messageNotification :: HasCallStack => TBQueue APNSMockRequest -> ExceptT AgentErrorType IO (C.CbNonce, ByteString)
messageNotification apnsQ = do
  1000000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> error "no notification"
    Just APNSMockRequest {notification = APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData}, sendApnsResponse} -> do
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      message <- ntfData .-> "message"
      liftIO $ sendApnsResponse APNSRespOk
      pure (nonce, message)
    _ -> error "bad notification"

messageNotificationData :: HasCallStack => AgentClient -> TBQueue APNSMockRequest -> ExceptT AgentErrorType IO PNMessageData
messageNotificationData c apnsQ = do
  (nonce, message) <- messageNotification apnsQ
  NtfToken {ntfDhSecret = Just dhSecret} <- getNtfTokenData c
  Right pnMsgs <- liftEither . first INTERNAL $ Right . parseAll pnMessagesP =<< first show (C.cbDecrypt dhSecret nonce message)
  pure $ L.last pnMsgs

noNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO ()
noNotification apnsQ = do
  500000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> pure ()
    _ -> error "unexpected notification"
