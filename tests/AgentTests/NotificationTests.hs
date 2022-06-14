{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.NotificationTests where

-- import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)

import AgentTests.FunctionalAPITests (get, (##>), (=##>), pattern Msg)
import Control.Concurrent (threadDelay)
import Control.Monad.Except
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import Data.Text.Encoding (encodeUtf8)
import NtfClient
import SMPAgentClient (agentCfg, initAgentServers, testDB, testDB2)
import SMPClient (withSmpServer)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..))
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Protocol (ErrorType (AUTH))
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Util (tryE)
import System.Directory (removeFile)
import Test.Hspec
import UnliftIO.STM

notificationTests :: ATransport -> Spec
notificationTests t =
  after_ (removeFile testDB) $ do
    describe "Managing notification tokens" $ do
      it "should register and verify notification token" $
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testNotificationToken apns
      it "should allow repeated registration with the same credentials" $ \_ ->
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testNtfTokenRepeatRegistration apns
      it "should allow the second registration with different credentials and delete the first after verification" $ \_ ->
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testNtfTokenSecondRegistration apns
      it "should re-register token when notification server is restarted" $ \_ ->
        withAPNSMockServer $ \apns ->
          testNtfTokenServerRestart t apns
    fdescribe "Managing notification subscriptions" $ do
      it "should create notification subscription for existing connection" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            withNtfServer t $ testNotificationSubscriptionExistingConnection apns
      it "should create notification subscription for new connection" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            withNtfServer t $ testNotificationSubscriptionNewConnection apns

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    let tkn = DeviceToken PPApns "abcd"
    NTRegistered <- registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken a tkn verification nonce
    enableNtfCron a tkn 30
    NTActive <- checkNtfToken a tkn
    deleteNtfToken a tkn
    -- agent deleted this token
    Left (CMD PROHIBITED) <- tryE $ checkNtfToken a tkn
    pure ()
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
  a <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    let tkn = DeviceToken PPApns "abcd"
    NTRegistered <- registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    NTRegistered <- registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    _ <- ntfData' .-> "verification"
    _ <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk
    -- can still use the first verification code, it is the same after decryption
    verifyNtfToken a tkn verification nonce
    enableNtfCron a tkn 30
    NTActive <- checkNtfToken a tkn
    pure ()
  pure ()

testNtfTokenSecondRegistration :: APNSMockServer -> IO ()
testNtfTokenSecondRegistration APNSMockServer {apnsQ} = do
  -- setLogLevel LogError -- LogDebug
  -- withGlobalLogging logCfg $ do
  a <- getSMPAgentClient agentCfg initAgentServers
  a' <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    let tkn = DeviceToken PPApns "abcd"
    NTRegistered <- registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken a tkn verification nonce

    NTRegistered <- registerNtfToken a' tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    verification' <- ntfData' .-> "verification"
    nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk

    -- at this point the first token is still active
    NTActive <- checkNtfToken a tkn
    -- and the second is not yet verified
    NTConfirmed <- checkNtfToken a' tkn
    -- now the second token registration is verified
    verifyNtfToken a' tkn verification' nonce'
    -- the first registration is removed
    Left (NTF AUTH) <- tryE $ checkNtfToken a tkn
    -- and the second is active
    NTActive <- checkNtfToken a' tkn
    enableNtfCron a' tkn 30
    pure ()
  pure ()

testNtfTokenServerRestart :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestart t APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  let tkn = DeviceToken PPApns "abcd"
  Right ntfData <- withNtfServer t . runExceptT $ do
    NTRegistered <- registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    liftIO $ sendApnsResponse APNSRespOk
    pure ntfData
  -- the new agent is created as otherwise when running the tests in CI the old agent was keeping the connection to the server
  threadDelay 1000000
  disconnectAgentClient a
  a' <- getSMPAgentClient agentCfg initAgentServers
  -- server stopped before token is verified, so now the attempt to verify it will return AUTH error but re-register token,
  -- so that repeat verification happens without restarting the clients, when notification arrives
  Right () <- withNtfServer t . runExceptT $ do
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    Left (NTF AUTH) <- tryE $ verifyNtfToken a' tkn verification nonce
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    verification' <- ntfData' .-> "verification"
    nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk
    verifyNtfToken a' tkn verification' nonce'
    NTActive <- checkNtfToken a' tkn
    enableNtfCron a' tkn 30
  pure ()

testNotificationSubscriptionExistingConnection :: APNSMockServer -> IO ()
testNotificationSubscriptionExistingConnection APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- register notification token
    let tkn = DeviceToken PPApns "abcd"
    NTRegistered <- registerNtfToken alice tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken alice tkn verification nonce
    NTActive <- checkNtfToken alice tkn
    -- send message
    liftIO $ threadDelay 50000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

testNotificationSubscriptionNewConnection :: APNSMockServer -> IO ()
testNotificationSubscriptionNewConnection APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    -- alice registers notification token
    let aliceTkn = DeviceToken PPApns "abcd"
    NTRegistered <- registerNtfToken alice aliceTkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- ntfData .-> "verification"
    nonce <- C.cbNonce <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken alice aliceTkn verification nonce
    NTActive <- checkNtfToken alice aliceTkn
    -- bob registers notification token
    let bobTkn = DeviceToken PPApns "bcde"
    NTRegistered <- registerNtfToken bob bobTkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    verification' <- ntfData' .-> "verification"
    nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk
    verifyNtfToken bob bobTkn verification' nonce'
    NTActive <- checkNtfToken bob bobTkn
    -- establish connection
    liftIO $ threadDelay 50000
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
    allowConnection alice bobId confId "alice's connInfo"
    messageNotification apnsQ
    messageNotification apnsQ
    get alice ##> ("", bobId, CON)
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    get bob ##> ("", aliceId, CON)
    -- bob sends message
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
    -- alice sends message
    2 <- msgId <$> sendMessage alice bobId (SMP.MsgFlags True) "hey there"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    messageNotification apnsQ
    get bob =##> \case ("", c, Msg "hey there") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 2
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

messageNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO ()
messageNotification apnsQ = do
  APNSMockRequest {notification = APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData'}, sendApnsResponse} <-
    atomically $ readTBQueue apnsQ
  _ <- ntfData' .-> "checkMessage"
  _ <- C.cbNonce <$> ntfData' .-> "nonce"
  liftIO $ sendApnsResponse APNSRespOk