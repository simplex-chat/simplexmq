{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.NotificationTests where

import Control.Monad.Except
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import Data.Text.Encoding (encodeUtf8)
import NtfClient
import SMPAgentClient (agentCfg, initAgentServers)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Transport (ATransport)
import Test.Hspec
import UnliftIO.STM

notificationTests :: ATransport -> Spec
notificationTests t = do
  describe "Managing notification tokens" $
    it "should register and verify notification token" $
      withAPNSMockServer $ \apns -> withNtfServer t $ testNotificationToken apns

testNotificationToken :: APNSMockServer -> IO ()
testNotificationToken APNSMockServer {apnsQ} = do
  a <- getSMPAgentClient agentCfg initAgentServers
  Right () <- runExceptT $ do
    let tkn = DeviceToken PPApns "abcd"
    registerNtfToken a tkn
    APNSMockRequest {notification = APNSNotification {aps = APNSBackground _, notificationData = Just ntfData}, sendApnsResponse} <-
      atomically $ readTBQueue apnsQ
    verification <- B64.decodeLenient <$> ntfData .-> "verification"
    nonce <- C.cbNonce . U.decodeLenient <$> ntfData .-> "nonce"
    liftIO $ sendApnsResponse APNSRespOk
    verifyNtfToken a tkn verification nonce
    enableNtfCron a tkn 30
    pure ()
  pure ()
  where
    (.->) :: J.Value -> J.Key -> ExceptT AgentErrorType IO ByteString
    v .-> key = do
      J.Object o <- pure v
      liftEither . bimap INTERNAL encodeUtf8 $ JT.parseEither (J..: key) o
