{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module NtfClient where

import Control.Concurrent.STM (retry)
import Control.Monad
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Class
import Data.Aeson (FromJSON (..), ToJSON (..), (.:))
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
import GHC.Generics (Generic)
import Network.HTTP.Types (Status)
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Server as H
import Network.Socket
import SMPClient (defaultStartOptions, ntfTestPort, prevRange, serverBracket)
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Client (ProtocolClientConfig (..), chooseTransportHost, defaultNetworkConfig)
import Simplex.Messaging.Client.Agent (SMPClientAgentConfig (..), defaultSMPClientAgentConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfResponse)
import Simplex.Messaging.Notifications.Server (runNtfServerBlocking)
import Simplex.Messaging.Notifications.Server.Env
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Push.APNS.Internal
import Simplex.Messaging.Notifications.Transport
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..), http2TLSParams)
import Simplex.Messaging.Transport.HTTP2.Server
import Simplex.Messaging.Transport.Server
import Test.Hspec hiding (fit, it)
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

testHost :: NonEmpty TransportHost
testHost = "localhost"

apnsTestPort :: ServiceName
apnsTestPort = "6010"

testKeyHash :: C.KeyHash
testKeyHash = "LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI="

ntfTestStoreLogFile :: FilePath
ntfTestStoreLogFile = "tests/tmp/ntf-server-store.log"

ntfTestStoreLogFile2 :: FilePath
ntfTestStoreLogFile2 = "tests/tmp/ntf-server-store.log.2"

ntfTestStoreLastNtfsFile :: FilePath
ntfTestStoreLastNtfsFile = "tests/tmp/ntf-server-last-notifications.log"

ntfTestPrometheusMetricsFile :: FilePath
ntfTestPrometheusMetricsFile = "tests/tmp/ntf-server-metrics.txt"

ntfTestStoreDBOpts :: DBOpts
ntfTestStoreDBOpts =
  DBOpts
    { connstr = ntfTestServerDBConnstr,
      schema = "ntf_server",
      poolSize = 3,
      createSchema = True
    }

ntfTestStoreDBOpts2 :: DBOpts
ntfTestStoreDBOpts2 = ntfTestStoreDBOpts {schema = "smp_server2"}

ntfTestServerDBConnstr :: ByteString
ntfTestServerDBConnstr = "postgresql://ntf_test_server_user@/ntf_test_server_db"

ntfTestServerDBConnectInfo :: ConnectInfo
ntfTestServerDBConnectInfo =
  defaultConnectInfo
    { connectUser = "ntf_test_server_user",
      connectDatabase = "ntf_test_server_db"
    }

ntfTestDBCfg :: PostgresStoreCfg
ntfTestDBCfg =
  PostgresStoreCfg
    { dbOpts = ntfTestStoreDBOpts,
      dbStoreLogPath = Just ntfTestStoreLogFile,
      confirmMigrations = MCYesUp,
      deletedTTL = 86400
    }

ntfTestDBCfg2 :: PostgresStoreCfg
ntfTestDBCfg2 = ntfTestDBCfg {dbOpts = ntfTestStoreDBOpts2, dbStoreLogPath = Just ntfTestStoreLogFile2}

testNtfClient :: Transport c => (THandleNTF c 'TClient -> IO a) -> IO a
testNtfClient client = do
  Right host <- pure $ chooseTransportHost defaultNetworkConfig testHost
  runTransportClient defaultTransportClientConfig Nothing host ntfTestPort (Just testKeyHash) $ \h ->
    runExceptT (ntfClientHandshake h testKeyHash supportedClientNTFVRange False) >>= \case
      Right th -> client th
      Left e -> error $ show e

ntfServerCfg :: NtfServerConfig
ntfServerCfg =
  NtfServerConfig
    { transports = [],
      controlPort = Nothing,
      controlPortUserAuth = Nothing,
      controlPortAdminAuth = Nothing,
      subIdBytes = 24,
      regCodeBytes = 32,
      clientQSize = 2,
      pushQSize = 2,
      smpAgentCfg = defaultSMPClientAgentConfig {persistErrorInterval = 0},
      apnsConfig =
        defaultAPNSPushClientConfig
          { apnsPort = apnsTestPort,
            caStoreFile = "tests/fixtures/ca.crt"
          },
      subsBatchSize = 900,
      inactiveClientExpiration = Just defaultInactiveClientExpiration,
      dbStoreConfig = ntfTestDBCfg,
      ntfCredentials =
        ServerCredentials
          { caCertificateFile = Just "tests/fixtures/ca.crt",
            privateKeyFile = "tests/fixtures/server.key",
            certificateFile = "tests/fixtures/server.crt"
          },
      periodicNtfsInterval = 1,
      -- stats config
      logStatsInterval = Nothing,
      logStatsStartTime = 0,
      serverStatsLogFile = "tests/ntf-server-stats.daily.log",
      serverStatsBackupFile = Nothing,
      prometheusInterval = Nothing,
      prometheusMetricsFile = ntfTestPrometheusMetricsFile,
      ntfServerVRange = supportedServerNTFVRange,
      transportConfig = defaultTransportServerConfig,
      startOptions = defaultStartOptions
    }

ntfServerCfgVPrev :: NtfServerConfig
ntfServerCfgVPrev =
  ntfServerCfg
    { ntfServerVRange = prevRange $ ntfServerVRange ntfServerCfg,
      smpAgentCfg = smpAgentCfg' {smpCfg = smpCfg' {serverVRange = prevRange serverVRange'}}
    }
  where
    smpAgentCfg' = smpAgentCfg ntfServerCfg
    smpCfg' = smpCfg smpAgentCfg'
    serverVRange' = serverVRange smpCfg'

withNtfServerThreadOn :: HasCallStack => ATransport -> ServiceName -> PostgresStoreCfg -> (HasCallStack => ThreadId -> IO a) -> IO a
withNtfServerThreadOn t port' dbStoreConfig =
  withNtfServerCfg ntfServerCfg {transports = [(port', t, False)], dbStoreConfig}

withNtfServerCfg :: HasCallStack => NtfServerConfig -> (ThreadId -> IO a) -> IO a
withNtfServerCfg cfg@NtfServerConfig {transports} =
  case transports of
    [] -> error "no transports configured"
    _ ->
      serverBracket
        (\started -> runNtfServerBlocking started cfg)
        (pure ())

withNtfServerOn :: HasCallStack => ATransport -> ServiceName -> PostgresStoreCfg -> (HasCallStack => IO a) -> IO a
withNtfServerOn t port' dbStoreConfig = withNtfServerThreadOn t port' dbStoreConfig . const

withNtfServer :: HasCallStack => ATransport -> (HasCallStack => IO a) -> IO a
withNtfServer t = withNtfServerOn t ntfTestPort ntfTestDBCfg

runNtfTest :: forall c a. Transport c => (THandleNTF c 'TClient -> IO a) -> IO a
runNtfTest test = withNtfServer (transport @c) $ testNtfClient test

ntfServerTest ::
  forall c smp.
  (Transport c, Encoding smp) =>
  TProxy c ->
  (Maybe TransmissionAuth, ByteString, ByteString, smp) ->
  IO (Maybe TransmissionAuth, ByteString, ByteString, NtfResponse)
ntfServerTest _ t = runNtfTest $ \h -> tPut' h t >> tGet' h
  where
    tPut' :: THandleNTF c 'TClient -> (Maybe TransmissionAuth, ByteString, ByteString, smp) -> IO ()
    tPut' h@THandle {params = THandleParams {sessionId, implySessId}} (sig, corrId, queueId, smp) = do
      let t' = if implySessId then smpEncode (corrId, queueId, smp) else smpEncode (sessionId, corrId, queueId, smp)
      [Right ()] <- tPut h [Right (sig, t')]
      pure ()
    tGet' h = do
      [(Nothing, _, (CorrId corrId, EntityId qId, Right cmd))] <- tGet h
      pure (Nothing, corrId, qId, cmd)

ntfTest :: Transport c => TProxy c -> (THandleNTF c 'TClient -> IO ()) -> Expectation
ntfTest _ test' = runNtfTest test' `shouldReturn` ()

data APNSMockRequest = APNSMockRequest
  { notification :: APNSNotification
  }

data APNSMockResponse = APNSRespOk | APNSRespError Status Text

data APNSMockServer = APNSMockServer
  { action :: Async (),
    notifications :: TM.TMap ByteString (TBQueue APNSMockRequest),
    http2Server :: HTTP2Server
  }

apnsMockServerConfig :: HTTP2ServerConfig
apnsMockServerConfig =
  HTTP2ServerConfig
    { qSize = 2,
      http2Port = apnsTestPort,
      bufferSize = 16384,
      bodyHeadSize = 16384,
      serverSupported = http2TLSParams,
      https2Credentials =
        ServerCredentials
          { caCertificateFile = Just "tests/fixtures/ca.crt",
            privateKeyFile = "tests/fixtures/server.key",
            certificateFile = "tests/fixtures/server.crt"
          },
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
  http2Server <- getHTTP2Server config Nothing
  notifications <- TM.emptyIO
  action <- async $ runAPNSMockServer notifications http2Server
  pure APNSMockServer {action, notifications, http2Server}
  where
    runAPNSMockServer notifications HTTP2Server {reqQ} = forever $ do
      HTTP2Request {request, reqBody = HTTP2Body {bodyHead}, sendResponse} <- atomically $ readTBQueue reqQ
      let sendApnsResponse = \case
            APNSRespOk -> sendResponse $ H.responseNoBody N.ok200 []
            APNSRespError status reason ->
              sendResponse . H.responseBuilder status [] . lazyByteString $ J.encode APNSErrorResponse {reason}
      case J.decodeStrict' bodyHead of
        Just notification -> do
          Just token <- pure $ B.stripPrefix "/3/device/" =<< H.requestPath request
          q <- atomically $ TM.lookup token notifications >>= maybe (newTokenQueue token) pure
          atomically $ writeTBQueue q APNSMockRequest {notification}
          sendApnsResponse APNSRespOk
          where
            newTokenQueue token = newTBQueue qSize >>= \q -> TM.insert token q notifications >> pure q
        _ -> do
          putStrLn $ "runAPNSMockServer J.decodeStrict' error, reqBody: " <> show bodyHead
          sendApnsResponse $ APNSRespError N.badRequest400 "bad_request_body"

getMockNotification :: MonadIO m => APNSMockServer -> DeviceToken -> m APNSMockRequest
getMockNotification APNSMockServer {notifications} (DeviceToken _ token) = do
  atomically $ TM.lookup token notifications >>= maybe retry readTBQueue

getAnyMockNotification :: MonadIO m => APNSMockServer -> m APNSMockRequest
getAnyMockNotification APNSMockServer {notifications} = do
  atomically $ readTVar notifications >>= mapM readTBQueue . M.elems >>= \case [] -> retry; ntf : _ -> pure ntf

closeAPNSMockServer :: APNSMockServer -> IO ()
closeAPNSMockServer APNSMockServer {action, http2Server} = do
  closeHTTP2Server http2Server
  uninterruptibleCancel action
