{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module NtfClient where

import Control.Monad
import Control.Monad.Except (runExceptT)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:))
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.HTTP.Types (Status)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket
import SMPClient (serverBracket)
import Simplex.Messaging.Client (ProtocolClientConfig (..), chooseTransportHost, defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Protocol (NtfResponse)
import Simplex.Messaging.Notifications.Server (runNtfServerBlocking)
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Push.APNS.Internal
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..), http2TLSParams)
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Version (mkVersionRange)
import Test.Hspec
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM
import Simplex.Messaging.Util (atomically')

testHost :: NonEmpty TransportHost
testHost = "localhost"

ntfTestPort :: ServiceName
ntfTestPort = "6001"

ntfTestPort2 :: ServiceName
ntfTestPort2 = "6002"

apnsTestPort :: ServiceName
apnsTestPort = "6010"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

ntfTestStoreLogFile :: FilePath
ntfTestStoreLogFile = "tests/tmp/ntf-server-store.log"

testNtfClient :: Transport c => (THandleNTF c -> IO a) -> IO a
testNtfClient client = do
  Right host <- pure $ chooseTransportHost defaultNetworkConfig testHost
  runTransportClient defaultTransportClientConfig Nothing host ntfTestPort (Just testKeyHash) $ \h -> do
    g <- C.newRandom
    ks <- atomically $ C.generateKeyPair g
    runExceptT (ntfClientHandshake h ks testKeyHash supportedClientNTFVRange) >>= \case
      Right th -> client th
      Left e -> error $ show e

ntfServerCfg :: NtfServerConfig
ntfServerCfg =
  NtfServerConfig
    { transports = [],
      subIdBytes = 24,
      regCodeBytes = 32,
      clientQSize = 1,
      subQSize = 1,
      pushQSize = 1,
      smpAgentCfg = defaultSMPClientAgentConfig,
      apnsConfig =
        defaultAPNSPushClientConfig
          { apnsPort = apnsTestPort,
            caStoreFile = "tests/fixtures/ca.crt"
          },
      subsBatchSize = 900,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      storeLogFile = Nothing,
      -- CA certificate private key is not needed for initialization
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt",
      -- stats config
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/ntf-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      ntfServerVRange = supportedServerNTFVRange,
      transportConfig = defaultTransportServerConfig
    }

ntfServerCfgV2 :: NtfServerConfig
ntfServerCfgV2 =
  ntfServerCfg
    { ntfServerVRange = mkVersionRange initialNTFVersion authBatchCmdsNTFVersion,
      smpAgentCfg = defaultSMPClientAgentConfig {smpCfg = (smpCfg defaultSMPClientAgentConfig) {serverVRange = mkVersionRange batchCmdsSMPVersion authCmdsSMPVersion}}
    }

withNtfServerStoreLog :: ATransport -> (ThreadId -> IO a) -> IO a
withNtfServerStoreLog t = withNtfServerCfg ntfServerCfg {storeLogFile = Just ntfTestStoreLogFile, transports = [(ntfTestPort, t)]}

withNtfServerThreadOn :: ATransport -> ServiceName -> (ThreadId -> IO a) -> IO a
withNtfServerThreadOn t port' = withNtfServerCfg ntfServerCfg {transports = [(port', t)]}

withNtfServerCfg :: HasCallStack => NtfServerConfig -> (ThreadId -> IO a) -> IO a
withNtfServerCfg cfg@NtfServerConfig {transports} =
  case transports of
    [] -> error "no transports configured"
    _ ->
      serverBracket
        (\started -> runNtfServerBlocking started cfg)
        (pure ())

withNtfServerOn :: ATransport -> ServiceName -> IO a -> IO a
withNtfServerOn t port' = withNtfServerThreadOn t port' . const

withNtfServer :: ATransport -> IO a -> IO a
withNtfServer t = withNtfServerOn t ntfTestPort

runNtfTest :: forall c a. Transport c => (THandleNTF c -> IO a) -> IO a
runNtfTest test = withNtfServer (transport @c) $ testNtfClient test

ntfServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe TransmissionAuth, ByteString, ByteString, smp) ->
  IO (Maybe TransmissionAuth, ByteString, ByteString, NtfResponse)
ntfServerTest _ t = runNtfTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' :: THandleNTF c -> (Maybe TransmissionAuth, ByteString, ByteString, smp) -> IO ()
    tPut' h@THandle {params = THandleParams {sessionId, implySessId}} (sig, corrId, queueId, smp) = do
      let t' = if implySessId then smpEncode (corrId, queueId, smp) else smpEncode (sessionId, corrId, queueId, smp)
      [Right ()] <- tPut h [Right (sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

ntfTest :: Transport c => TProxy c -> (THandleNTF c -> IO ()) -> Expectation
ntfTest _ test' = runNtfTest test' `shouldReturn` ()

data APNSMockRequest = APNSMockRequest
  { notification :: APNSNotification,
    sendApnsResponse :: APNSMockResponse -> IO ()
  }

data APNSMockResponse = APNSRespOk | APNSRespError Status Text

data APNSMockServer = APNSMockServer
  { action :: Async (),
    apnsQ :: TBQueue APNSMockRequest,
    http2Server :: HTTP2Server
  }

apnsMockServerConfig :: HTTP2ServerConfig
apnsMockServerConfig =
  HTTP2ServerConfig
    { qSize = 1,
      http2Port = apnsTestPort,
      bufferSize = 16384,
      bodyHeadSize = 16384,
      serverSupported = http2TLSParams,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt",
      transportConfig = defaultTransportServerConfig
    }

withAPNSMockServer :: (APNSMockServer -> IO ()) -> IO ()
withAPNSMockServer = E.bracket (getAPNSMockServer apnsMockServerConfig) closeAPNSMockServer

deriving instance Generic APNSAlertBody

instance FromJSON APNSAlertBody where
  parseJSON (J.Object v) = do
    title <- v .: "title"
    subtitle <- v .: "subtitle"
    body <- v .: "body"
    pure APNSAlertObject {title, subtitle, body}
  parseJSON (J.String v) = pure $ APNSAlertText v
  parseJSON invalid = JT.prependFailure "parsing Coord failed, " (JT.typeMismatch "Object" invalid)

deriving instance Generic APNSNotificationBody

instance FromJSON APNSNotificationBody where parseJSON = J.genericParseJSON apnsJSONOptions {J.rejectUnknownFields = True}

deriving instance Generic APNSNotification

deriving instance FromJSON APNSNotification

deriving instance Generic APNSErrorResponse

deriving instance ToJSON APNSErrorResponse

getAPNSMockServer :: HTTP2ServerConfig -> IO APNSMockServer
getAPNSMockServer config@HTTP2ServerConfig {qSize} = do
  http2Server <- getHTTP2Server config
  apnsQ <- newTBQueueIO qSize
  action <- async $ runAPNSMockServer apnsQ http2Server
  pure APNSMockServer {action, apnsQ, http2Server}
  where
    runAPNSMockServer apnsQ HTTP2Server {reqQ} = forever $ do
      HTTP2Request {reqBody = HTTP2Body {bodyHead}, sendResponse} <- atomically' $ readTBQueue reqQ
      let sendApnsResponse = \case
            APNSRespOk -> sendResponse $ H.responseNoBody N.ok200 []
            APNSRespError status reason ->
              sendResponse . H.responseBuilder status [] . lazyByteString $ J.encode APNSErrorResponse {reason}
      case J.decodeStrict' bodyHead of
        Just notification ->
          atomically $ writeTBQueue apnsQ APNSMockRequest {notification, sendApnsResponse}
        _ -> do
          putStrLn $ "runAPNSMockServer J.decodeStrict' error, reqBody: " <> show bodyHead
          sendApnsResponse $ APNSRespError N.badRequest400 "bad_request_body"

closeAPNSMockServer :: APNSMockServer -> IO ()
closeAPNSMockServer APNSMockServer {action, http2Server} = do
  closeHTTP2Server http2Server
  uninterruptibleCancel action
