{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.NotificationTests where

import Control.Monad.Except
import NtfClient
import SMPAgentClient (agentCfg, initAgentServers)
import Simplex.Messaging.Agent
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Transport (ATransport)
import Test.Hspec
import UnliftIO.STM

notificationTests :: ATransport -> Spec
notificationTests t = do
  fdescribe "Managing notification tokens" $
    it "should register and verify notification token" $
      withNtfServer t $ withAPNSMockServer testNotificationToken

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    registerNtfToken a $ DeviceToken PPApns "abcd"
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData}, sendApnsResponse} <- atomically $ readTBQueue apnsQ
    pure ()
  pure ()