{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.NotificationTests where

-- import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)

import AgentTests.FunctionalAPITests (get, makeConnection, (##>), (=##>), pattern Msg)
import Control.Concurrent (killThread, threadDelay)
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
import Simplex.Messaging.Protocol (ErrorType (AUTH), MsgFlags (MsgFlags), SMPMsgMeta (..))
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Transport (ATransport)
import Simplex.Messaging.Util (tryE)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec
import UnliftIO

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists filePath = do
  fileExists <- doesFileExist filePath
  when fileExists $ removeFile filePath

notificationTests :: ATransport -> Spec
notificationTests t =
  after_ (removeFile testDB >> removeFileIfExists testDB2) $ do
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
      it "should change notifications mode" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            withNtfServer t $ testChangeNotificationsMode apns
      fit "should change token" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            withNtfServer t $ testChangeToken apns
    describe "Notifications server store log" $ do
      it "should save and restore tokens and subscriptions" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            testNotificationsStoreLog t apns

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
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
  pure ()

testNtfTokenSecondRegistration :: APNSMockServer -> IO ()
testNtfTokenSecondRegistration APNSMockServer {apnsQ} = do
  -- setLogLevel LogError -- LogDebug
  -- withGlobalLogging logCfg $ do
  a <- getSMPAgentClient agentCfg initAgentServers
  a' <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
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
    Left (NTF AUTH) <- tryE $ checkNtfToken a tkn
    -- and the second is active
    NTActive <- checkNtfToken a' tkn
    pure ()
  pure ()

testNtfTokenServerRestart :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestart t APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  let tkn = DeviceToken PPApnsTest "abcd"
  Right ntfData <- withNtfServer t . runExceptT $ do
    NTRegistered <- registerNtfToken a tkn NMPeriodic
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
    Left (NTF AUTH) <- tryE $ verifyNtfToken a' tkn nonce verification
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
      atomically $ readTBQueue apnsQ
    verification' <- ntfData' .-> "verification"
    nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
    liftIO $ sendApnsResponse' APNSRespOk
    verifyNtfToken a' tkn nonce' verification'
    NTActive <- checkNtfToken a' tkn
    pure ()
  pure ()

testNotificationSubscriptionExistingConnection :: APNSMockServer -> IO ()
testNotificationSubscriptionExistingConnection APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right (bobId, aliceId, nonce, message) <- runExceptT $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
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
    liftIO $ threadDelay 50000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    -- notification
    (nonce, message) <- messageNotification apnsQ
    pure (bobId, aliceId, nonce, message)

  -- alice client already has subscription for the connection
  Left (CMD PROHIBITED) <- runExceptT $ getNotificationMessage alice nonce message

  -- aliceNtf client doesn't have subscription and is allowed to get notification message
  aliceNtf <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    (_, [SMPMsgMeta {msgFlags = MsgFlags True}]) <- getNotificationMessage aliceNtf nonce message
    pure ()
  disconnectAgentClient aliceNtf

  Right () <- runExceptT $ do
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
    -- delete notification subscription
    deleteNtfSub alice bobId
    -- send message
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    -- no notifications should follow
    noNotification apnsQ
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
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    -- bob registers notification token
    _ <- registerTestToken bob "bcde" NMInstant apnsQ
    -- establish connection
    liftIO $ threadDelay 50000
    (bobId, qInfo) <- createConnection alice SCMInvitation
    liftIO $ threadDelay 500000
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    void $ messageNotification apnsQ
    ("", _, CONF confId "bob's connInfo") <- get alice
    liftIO $ threadDelay 500000
    allowConnection alice bobId confId "alice's connInfo"
    void $ messageNotification apnsQ
    get bob ##> ("", aliceId, INFO "alice's connInfo")
    void $ messageNotification apnsQ
    get alice ##> ("", bobId, CON)
    void $ messageNotification apnsQ
    get bob ##> ("", aliceId, CON)
    -- bob sends message
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
    -- alice sends message
    2 <- msgId <$> sendMessage alice bobId (SMP.MsgFlags True) "hey there"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    void $ messageNotification apnsQ
    get bob =##> \case ("", c, Msg "hey there") -> c == aliceId; _ -> False
    ackMessage bob aliceId $ baseId + 2
    -- no unexpected notifications should follow
    noNotification apnsQ
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

registerTestToken :: AgentClient -> ByteString -> NotificationsMode -> TBQueue APNSMockRequest -> ExceptT AgentErrorType IO DeviceToken
registerTestToken a token mode apnsQ = do
  let tkn = DeviceToken PPApnsTest token
  NTRegistered <- registerNtfToken a tkn mode
  APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData'}, sendApnsResponse = sendApnsResponse'} <-
    atomically $ readTBQueue apnsQ
  verification' <- ntfData' .-> "verification"
  nonce' <- C.cbNonce <$> ntfData' .-> "nonce"
  liftIO $ sendApnsResponse' APNSRespOk
  verifyNtfToken a tkn nonce' verification'
  NTActive <- checkNtfToken a tkn
  pure tkn

testChangeNotificationsMode :: APNSMockServer -> IO ()
testChangeNotificationsMode APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right () <- runExceptT $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
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
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
    -- set mode to NMPeriodic
    NTActive <- registerNtfToken alice tkn NMPeriodic
    -- send message, no notification
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    noNotification apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 2
    -- set mode to NMInstant
    NTActive <- registerNtfToken alice tkn NMInstant
    -- send message, receive notification
    liftIO $ threadDelay 500000
    3 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 3)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello there") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 3
    -- turn off notifications
    deleteNtfToken alice tkn
    -- send message, no notification
    4 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "why hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 4)
    noNotification apnsQ
    get alice =##> \case ("", c, Msg "why hello there") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 4
    -- turn on notifications, set mode to NMInstant
    void $ registerTestToken alice "abcd" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    5 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hey"
    get bob ##> ("", aliceId, SENT $ baseId + 5)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hey") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 5
    -- no notifications should follow
    noNotification apnsQ
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

testChangeToken :: APNSMockServer -> IO ()
testChangeToken APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right (aliceId, bobId) <- runExceptT $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice SCMInvitation
    aliceId <- joinConnection bob qInfo "bob's connInfo"
    ("", _, CONF confId "bob's connInfo") <- get alice
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
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 1
    pure (aliceId, bobId)
  disconnectAgentClient alice

  alice1 <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    -- change notification token
    void $ registerTestToken alice1 "bcde" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    void $ messageNotification apnsQ
    get alice1 =##> \case ("", c, Msg "hello there") -> c == bobId; _ -> False
    ackMessage alice bobId $ baseId + 2
    -- no notifications should follow
    noNotification apnsQ
  pure ()
  where
    baseId = 3
    msgId = subtract baseId

testNotificationsStoreLog :: ATransport -> APNSMockServer -> IO ()
testNotificationsStoreLog t APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient agentCfg initAgentServers
  bob <- getSMPAgentClient agentCfg {dbFile = testDB2} initAgentServers
  Right (aliceId, bobId) <- withNtfServerStoreLog t $ \threadId -> runExceptT $ do
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    (aliceId, bobId) <- makeConnection alice bob
    liftIO $ threadDelay 250000
    4 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT 4)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId 4
    liftIO $ killThread threadId
    pure (aliceId, bobId)

  liftIO $ threadDelay 250000

  Right () <- withNtfServerStoreLog t $ \threadId -> runExceptT $ do
    liftIO $ threadDelay 250000
    5 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT 5)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    liftIO $ killThread threadId
  pure ()

messageNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO (C.CbNonce, ByteString)
messageNotification apnsQ = do
  500000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> error "no notification"
    Just APNSMockRequest {notification = APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData}, sendApnsResponse} -> do
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      message <- ntfData .-> "message"
      liftIO $ sendApnsResponse APNSRespOk
      pure (nonce, message)
    _ -> error "bad notification"

noNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO ()
noNotification apnsQ = do
  500000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> pure ()
    _ -> error "unexpected notification"
