{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module AgentTests.NotificationTests where

-- import Control.Logger.Simple (LogConfig (..), LogLevel (..), setLogLevel, withGlobalLogging)
import AgentTests.FunctionalAPITests (exchangeGreetingsMsgId, get, getSMPAgentClient', makeConnection, nGet, runRight, runRight_, switchComplete, testServerMatrix2, (##>), (=##>), pattern Msg)
import Control.Concurrent (killThread, threadDelay)
import Control.Monad
import Control.Monad.Except
import Control.Monad.Trans.Except
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (bimap, first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import Data.Text.Encoding (encodeUtf8)
import NtfClient
import SMPAgentClient (agentCfg, initAgentServers, initAgentServers2, testDB, testDB2)
import SMPClient (cfg, testPort, testPort2, testStoreLogFile2, withSmpServer, withSmpServerConfigOn, withSmpServerStoreLogOn, xit')
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), InitialAgentServers)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Types (NtfToken (..))
import Simplex.Messaging.Protocol (ErrorType (AUTH), MsgFlags (MsgFlags), SMPMsgMeta (..), SubscriptionMode (..))
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
notificationTests t =
  after_ (removeFileIfExists testDB >> removeFileIfExists testDB2) $ do
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
    describe "Managing notification subscriptions" $ do
      -- fails on Ubuntu CI?
      xit' "should create notification subscription for existing connection" $ \_ -> do
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
      it "should change token" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            withNtfServer t $ testChangeToken apns
    describe "Notifications server store log" $
      it "should save and restore tokens and subscriptions" $ \_ ->
        withSmpServer t $
          withAPNSMockServer $ \apns ->
            testNotificationsStoreLog t apns
    describe "Notifications after SMP server restart" $
      it "should resume subscriptions after SMP server is restarted" $ \_ ->
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testNotificationsSMPRestart t apns
    describe "Notifications after SMP server restart" $
      it "should resume batched subscriptions after SMP server is restarted" $ \_ ->
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testNotificationsSMPRestartBatch 100 t apns
    describe "should switch notifications to the new queue" $
      testServerMatrix2 t $ \servers ->
        withAPNSMockServer $ \apns ->
          withNtfServer t $ testSwitchNotifications servers apns

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight_ $ do
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
    disconnectAgentClient a

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
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight_ $ do
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
    disconnectAgentClient a

testNtfTokenSecondRegistration :: APNSMockServer -> IO ()
testNtfTokenSecondRegistration APNSMockServer {apnsQ} = do
  -- setLogLevel LogError -- LogDebug
  -- withGlobalLogging logCfg $ do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  a' <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
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
    disconnectAgentClient a
    disconnectAgentClient a'

testNtfTokenServerRestart :: ATransport -> APNSMockServer -> IO ()
testNtfTokenServerRestart t APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient' agentCfg initAgentServers testDB
  let tkn = DeviceToken PPApnsTest "abcd"
  ntfData <- withNtfServer t . runRight $ do
    NTRegistered <- registerNtfToken a tkn NMPeriodic
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    liftIO $ sendApnsResponse APNSRespOk
    pure ntfData
  -- the new agent is created as otherwise when running the tests in CI the old agent was keeping the connection to the server
  threadDelay 1000000
  disconnectAgentClient a
  a' <- getSMPAgentClient' agentCfg initAgentServers testDB
  -- server stopped before token is verified, so now the attempt to verify it will return AUTH error but re-register token,
  -- so that repeat verification happens without restarting the clients, when notification arrives
  withNtfServer t . runRight_ $ do
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
    disconnectAgentClient a'

testNotificationSubscriptionExistingConnection :: APNSMockServer -> IO ()
testNotificationSubscriptionExistingConnection APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (bobId, aliceId, nonce, message) <- runRight $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
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
    liftIO $ threadDelay 50000
    1 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT $ baseId + 1)
    -- notification
    (nonce, message) <- messageNotification apnsQ
    pure (bobId, aliceId, nonce, message)

  -- alice client already has subscription for the connection
  Left (CMD PROHIBITED) <- runExceptT $ getNotificationMessage alice nonce message

  -- aliceNtf client doesn't have subscription and is allowed to get notification message
  aliceNtf <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight_ $ do
    (_, [SMPMsgMeta {msgFlags = MsgFlags True}]) <- getNotificationMessage aliceNtf nonce message
    pure ()
  disconnectAgentClient aliceNtf

  runRight_ $ do
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    -- delete notification subscription
    toggleConnectionNtfs alice bobId False
    liftIO $ threadDelay 250000
    -- send message
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    -- no notifications should follow
    noNotification apnsQ
  disconnectAgentClient alice
  disconnectAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testNotificationSubscriptionNewConnection :: APNSMockServer -> IO ()
testNotificationSubscriptionNewConnection APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    -- alice registers notification token
    DeviceToken {} <- registerTestToken alice "abcd" NMInstant apnsQ
    -- bob registers notification token
    DeviceToken {} <- registerTestToken bob "bcde" NMInstant apnsQ
    -- establish connection
    liftIO $ threadDelay 50000
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    liftIO $ threadDelay 1000000
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
    liftIO $ threadDelay 750000
    void $ messageNotification apnsQ
    ("", _, CONF confId _ "bob's connInfo") <- get alice
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
    ackMessage alice bobId (baseId + 1) Nothing
    -- alice sends message
    2 <- msgId <$> sendMessage alice bobId (SMP.MsgFlags True) "hey there"
    get alice ##> ("", bobId, SENT $ baseId + 2)
    void $ messageNotification apnsQ
    get bob =##> \case ("", c, Msg "hey there") -> c == aliceId; _ -> False
    ackMessage bob aliceId (baseId + 2) Nothing
    -- no unexpected notifications should follow
    noNotification apnsQ
  disconnectAgentClient alice
  disconnectAgentClient bob
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
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  runRight_ $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
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
    void $ messageNotification apnsQ
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
    void $ messageNotification apnsQ
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
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hey") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 5) Nothing
    -- no notifications should follow
    noNotification apnsQ
  disconnectAgentClient alice
  disconnectAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testChangeToken :: APNSMockServer -> IO ()
testChangeToken APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aliceId, bobId) <- runRight $ do
    -- establish connection
    (bobId, qInfo) <- createConnection alice 1 True SCMInvitation Nothing SMSubscribe
    aliceId <- joinConnection bob 1 True qInfo "bob's connInfo" SMSubscribe
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
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId (baseId + 1) Nothing
    pure (aliceId, bobId)
  disconnectAgentClient alice

  alice1 <- getSMPAgentClient' agentCfg initAgentServers testDB
  runRight_ $ do
    subscribeConnection alice1 bobId
    -- change notification token
    void $ registerTestToken alice1 "bcde" NMInstant apnsQ
    -- send message, receive notification
    liftIO $ threadDelay 500000
    2 <- msgId <$> sendMessage bob aliceId (SMP.MsgFlags True) "hello there"
    get bob ##> ("", aliceId, SENT $ baseId + 2)
    void $ messageNotification apnsQ
    get alice1 =##> \case ("", c, Msg "hello there") -> c == bobId; _ -> False
    ackMessage alice1 bobId (baseId + 2) Nothing
    -- no notifications should follow
    noNotification apnsQ
  disconnectAgentClient alice1
  disconnectAgentClient bob
  where
    baseId = 3
    msgId = subtract baseId

testNotificationsStoreLog :: ATransport -> APNSMockServer -> IO ()
testNotificationsStoreLog t APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withNtfServerStoreLog t $ \threadId -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    4 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT 4)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId 4 Nothing
    liftIO $ killThread threadId
    pure (aliceId, bobId)

  liftIO $ threadDelay 250000

  withNtfServerStoreLog t $ \threadId -> runRight_ $ do
    liftIO $ threadDelay 250000
    5 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT 5)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    liftIO $ killThread threadId
  disconnectAgentClient alice
  disconnectAgentClient bob

testNotificationsSMPRestart :: ATransport -> APNSMockServer -> IO ()
testNotificationsSMPRestart t APNSMockServer {apnsQ} = do
  alice <- getSMPAgentClient' agentCfg initAgentServers testDB
  bob <- getSMPAgentClient' agentCfg initAgentServers testDB2
  (aliceId, bobId) <- withSmpServerStoreLogOn t testPort $ \threadId -> runRight $ do
    (aliceId, bobId) <- makeConnection alice bob
    _ <- registerTestToken alice "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    4 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello"
    get bob ##> ("", aliceId, SENT 4)
    void $ messageNotification apnsQ
    get alice =##> \case ("", c, Msg "hello") -> c == bobId; _ -> False
    ackMessage alice bobId 4 Nothing
    liftIO $ killThread threadId
    pure (aliceId, bobId)

  runRight_ @AgentErrorType $ do
    nGet alice =##> \case ("", "", DOWN _ [c]) -> c == bobId; _ -> False
    nGet bob =##> \case ("", "", DOWN _ [c]) -> c == aliceId; _ -> False

  withSmpServerStoreLogOn t testPort $ \threadId -> runRight_ $ do
    nGet alice =##> \case ("", "", UP _ [c]) -> c == bobId; _ -> False
    nGet bob =##> \case ("", "", UP _ [c]) -> c == aliceId; _ -> False
    liftIO $ threadDelay 1000000
    5 <- sendMessage bob aliceId (SMP.MsgFlags True) "hello again"
    get bob ##> ("", aliceId, SENT 5)
    _ <- messageNotificationData alice apnsQ
    get alice =##> \case ("", c, Msg "hello again") -> c == bobId; _ -> False
    liftIO $ killThread threadId
  disconnectAgentClient alice
  disconnectAgentClient bob

testNotificationsSMPRestartBatch :: Int -> ATransport -> APNSMockServer -> IO ()
testNotificationsSMPRestartBatch n t APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient' agentCfg initAgentServers2 testDB
  b <- getSMPAgentClient' agentCfg initAgentServers2 testDB2
  conns <- runServers $ do
    conns <- replicateM (n :: Int) $ makeConnection a b
    _ <- registerTestToken a "abcd" NMInstant apnsQ
    liftIO $ threadDelay 1500000
    forM_ conns $ \(aliceId, bobId) -> do
      msgId <- sendMessage b aliceId (SMP.MsgFlags True) "hello"
      get b ##> ("", aliceId, SENT msgId)
      void $ messageNotification apnsQ
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
  disconnectAgentClient a
  disconnectAgentClient b
  where
    runServers :: ExceptT AgentErrorType IO a -> IO a
    runServers a = do
      withSmpServerStoreLogOn t testPort $ \t1 -> do
        res <- withSmpServerConfigOn t cfg {storeLogFile = Just testStoreLogFile2} testPort2 $ \t2 ->
          runRight a `finally` killThread t2
        killThread t1
        pure res

testSwitchNotifications :: InitialAgentServers -> APNSMockServer -> IO ()
testSwitchNotifications servers APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient' agentCfg servers testDB
  b <- getSMPAgentClient' agentCfg {initialClientId = 1} servers testDB2
  runRight_ $ do
    (aId, bId) <- makeConnection a b
    exchangeGreetingsMsgId 4 a bId b aId
    _ <- registerTestToken a "abcd" NMInstant apnsQ
    liftIO $ threadDelay 250000
    let testMessage msg = do
          msgId <- sendMessage b aId (SMP.MsgFlags True) msg
          get b ##> ("", aId, SENT msgId)
          void $ messageNotification apnsQ
          get a =##> \case ("", c, Msg msg') -> c == bId && msg == msg'; _ -> False
          ackMessage a bId msgId Nothing
    testMessage "hello"
    _ <- switchConnectionAsync a "" bId
    switchComplete a bId b aId
    liftIO $ threadDelay 500000
    testMessage "hello again"
  disconnectAgentClient a
  disconnectAgentClient b

messageNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO (C.CbNonce, ByteString)
messageNotification apnsQ = do
  750000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> error "no notification"
    Just APNSMockRequest {notification = APNSNotification {aps = APNSMutableContent {}, notificationData = Just ntfData}, sendApnsResponse} -> do
      nonce <- C.cbNonce <$> ntfData .-> "nonce"
      message <- ntfData .-> "message"
      liftIO $ sendApnsResponse APNSRespOk
      pure (nonce, message)
    _ -> error "bad notification"

messageNotificationData :: AgentClient -> TBQueue APNSMockRequest -> ExceptT AgentErrorType IO PNMessageData
messageNotificationData c apnsQ = do
  (nonce, message) <- messageNotification apnsQ
  NtfToken {ntfDhSecret = Just dhSecret} <- getNtfTokenData c
  Right pnMsgData <- liftEither . first INTERNAL $ Right . strDecode =<< first show (C.cbDecrypt dhSecret nonce message)
  pure pnMsgData

noNotification :: TBQueue APNSMockRequest -> ExceptT AgentErrorType IO ()
noNotification apnsQ = do
  500000 `timeout` atomically (readTBQueue apnsQ) >>= \case
    Nothing -> pure ()
    _ -> error "unexpected notification"
