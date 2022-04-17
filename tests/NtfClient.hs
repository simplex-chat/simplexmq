{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module NtfClient where

import Control.Monad
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.HTTP.Types (Status)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket
import Simplex.Messaging.Client.Agent (defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Server (runNtfServerBlocking)
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.HTTP2 (http2TLSParams)
import Simplex.Messaging.Transport.HTTP2.Client
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Transport.KeepAlive
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM
import UnliftIO.Timeout (timeout)

testHost :: HostName
testHost = "localhost"

ntfTestPort :: ServiceName
ntfTestPort = "6001"

apnsTestPort :: ServiceName
apnsTestPort = "7001"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

testNtfClient :: (Transport c, MonadUnliftIO m) => (THandle c -> m a) -> m a
testNtfClient client =
  runTransportClient testHost ntfTestPort (Just testKeyHash) (Just defaultKeepAliveOpts) $ \h ->
    liftIO (runExceptT $ ntfClientHandshake h testKeyHash) >>= \case
      Right th -> client th
      Left e -> error $ show e

ntfServerCfg :: NtfServerConfig
ntfServerCfg =
  NtfServerConfig
    { transports = undefined,
      subIdBytes = 24,
      regCodeBytes = 32,
      clientQSize = 1,
      subQSize = 1,
      pushQSize = 1,
      smpAgentCfg = defaultSMPClientAgentConfig,
      apnsConfig =
        defaultAPNSPushClientConfig
          { apnsHost = "localhost",
            apnsPort = apnsTestPort,
            http2cfg = defaultHTTP2ClientConfig {caStoreFile = "tests/fixtures/ca.crt"}
          },
      -- CA certificate private key is not needed for initialization
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withNtfServerThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> (ThreadId -> m a) -> m a
withNtfServerThreadOn t port' =
  serverBracket
    (\started -> runNtfServerBlocking started ntfServerCfg {transports = [(port', t)]})
    (pure ())

serverBracket :: MonadUnliftIO m => (TMVar Bool -> m ()) -> m () -> (ThreadId -> m a) -> m a
serverBracket process afterProcess f = do
  started <- newEmptyTMVarIO
  E.bracket
    (forkIOWithUnmask ($ process started))
    (\t -> killThread t >> afterProcess >> waitFor started "stop")
    (\t -> waitFor started "start" >> f t)
  where
    waitFor started s =
      5_000_000 `timeout` atomically (takeTMVar started) >>= \case
        Nothing -> error $ "server did not " <> s
        _ -> pure ()

withNtfServerOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> ServiceName -> m a -> m a
withNtfServerOn t port' = withNtfServerThreadOn t port' . const

withNtfServer :: (MonadUnliftIO m, MonadRandom m) => ATransport -> m a -> m a
withNtfServer t = withNtfServerOn t ntfTestPort

runNtfTest :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => (THandle c -> m a) -> m a
runNtfTest test = withNtfServer (transport @c) $ testNtfClient test

ntfServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe C.ASignature, ByteString, ByteString, smp) ->
  IO (Maybe C.ASignature, ByteString, ByteString, BrokerMsg)
ntfServerTest _ t = runNtfTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' h (sig, corrId, queueId, smp) = do
      let t' = smpEncode (sessionId (h :: THandle c), corrId, queueId, smp)
      Right () <- tPut h (sig, t')
      pure ()
    tGet' h = do
      (Nothing, _, (CorrId corrId, qId, Right cmd)) <- tGet h
      pure (Nothing, corrId, qId, cmd)

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
      serverSupported = http2TLSParams,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withAPNSMockServer :: (APNSMockServer -> IO ()) -> IO ()
withAPNSMockServer = E.bracket (getAPNSMockServer apnsMockServerConfig) closeAPNSMockServer

deriving instance Generic APNSAlertBody

deriving instance FromJSON APNSAlertBody

deriving instance FromJSON APNSNotificationBody

deriving instance FromJSON APNSNotification

deriving instance ToJSON APNSErrorResponse

getAPNSMockServer :: HTTP2ServerConfig -> IO APNSMockServer
getAPNSMockServer config@HTTP2ServerConfig {qSize} = do
  http2Server <- getHTTP2Server config
  apnsQ <- newTBQueueIO qSize
  action <- async $ runAPNSMockServer apnsQ http2Server
  pure APNSMockServer {action, apnsQ, http2Server}
  where
    runAPNSMockServer apnsQ HTTP2Server {reqQ} = forever $ do
      HTTP2Request {reqBody, sendResponse} <- atomically $ readTBQueue reqQ
      let sendApnsResponse = \case
            APNSRespOk -> sendResponse $ H.responseNoBody N.ok200 []
            APNSRespError status reason ->
              sendResponse . H.responseBuilder status [] . lazyByteString $ J.encode APNSErrorResponse {reason}
      case J.decodeStrict' reqBody of
        Just notification -> atomically $ writeTBQueue apnsQ APNSMockRequest {notification, sendApnsResponse}
        _ -> sendApnsResponse $ APNSRespError N.badRequest400 "bad_request_body"

closeAPNSMockServer :: APNSMockServer -> IO ()
closeAPNSMockServer APNSMockServer {action, http2Server} = do
  closeHTTP2Server http2Server
  uninterruptibleCancel action
