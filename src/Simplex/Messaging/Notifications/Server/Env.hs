{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Env where

import Control.Concurrent (ThreadId)
import Control.Logger.Simple
import Control.Monad
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as TLS
import Numeric.Natural
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store (newNtfSTMStore)
import Simplex.Messaging.Notifications.Server.Store.Postgres
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Server.StoreLog (readWriteNtfSTMStore)
import Simplex.Messaging.Notifications.Transport (NTFVersion, VersionRangeNTF)
import Simplex.Messaging.Protocol (BasicAuth, CorrId, SMPServer, Transmission)
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Server.StoreLog (closeStoreLog)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport, THandleParams, TransportPeer (..))
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials, TransportServerConfig, loadFingerprint, loadServerCredential)
import System.Exit (exitFailure)
import System.Mem.Weak (Weak)
import UnliftIO.STM

data NtfServerConfig = NtfServerConfig
  { transports :: [(ServiceName, ATransport, AddHTTP)],
    controlPort :: Maybe ServiceName,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
    subIdBytes :: Int,
    regCodeBytes :: Int,
    clientQSize :: Natural,
    subQSize :: Natural,
    pushQSize :: Natural,
    smpAgentCfg :: SMPClientAgentConfig,
    apnsConfig :: APNSPushClientConfig,
    subsBatchSize :: Int,
    inactiveClientExpiration :: Maybe ExpirationConfig,
    dbStoreConfig :: PostgresStoreCfg,
    ntfCredentials :: ServerCredentials,
    periodicNtfsInterval :: Int, -- seconds
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int64,
    logStatsStartTime :: Int64,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    -- | interval and file to save prometheus metrics
    prometheusInterval :: Maybe Int,
    prometheusMetricsFile :: FilePath,
    ntfServerVRange :: VersionRangeNTF,
    transportConfig :: TransportServerConfig,
    startOptions :: StartOptions
  }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 43200, -- seconds, 12 hours
      checkInterval = 3600 -- seconds, 1 hours
    }

data NtfEnv = NtfEnv
  { config :: NtfServerConfig,
    subscriber :: NtfSubscriber,
    pushServer :: NtfPushServer,
    store :: NtfPostgresStore,
    random :: TVar ChaChaDRG,
    tlsServerCreds :: TLS.Credential,
    serverIdentity :: C.KeyHash,
    serverStats :: NtfServerStats
  }

newNtfServerEnv :: NtfServerConfig -> IO NtfEnv
newNtfServerEnv config@NtfServerConfig {subQSize, pushQSize, smpAgentCfg, apnsConfig, dbStoreConfig, ntfCredentials, startOptions} = do
  when (compactLog startOptions) $ compactDbStoreLog $ dbStoreLogPath dbStoreConfig
  random <- C.newRandom
  store <- newNtfDbStore dbStoreConfig
  subscriber <- newNtfSubscriber subQSize smpAgentCfg random
  pushServer <- newNtfPushServer pushQSize apnsConfig
  tlsServerCreds <- loadServerCredential ntfCredentials
  Fingerprint fp <- loadFingerprint ntfCredentials
  serverStats <- newNtfServerStats =<< getCurrentTime
  pure NtfEnv {config, subscriber, pushServer, store, random, tlsServerCreds, serverIdentity = C.KeyHash fp, serverStats}
  where
    compactDbStoreLog = \case
      Just f -> do
        logNote $ "compacting store log " <> T.pack f
        newNtfSTMStore >>= readWriteNtfSTMStore False f >>= closeStoreLog
      Nothing -> do
        logError "Error: `--compact-log` used without `enable: on` option in STORE_LOG section of INI file"
        exitFailure

data NtfSubscriber = NtfSubscriber
  { smpSubscribers :: TMap SMPServer SMPSubscriber,
    newSubQ :: TBQueue (SMPServer, NonEmpty ServerNtfSub),
    smpAgent :: SMPClientAgent
  }

newNtfSubscriber :: Natural -> SMPClientAgentConfig -> TVar ChaChaDRG -> IO NtfSubscriber
newNtfSubscriber qSize smpAgentCfg random = do
  smpSubscribers <- TM.emptyIO
  newSubQ <- newTBQueueIO qSize
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure NtfSubscriber {smpSubscribers, newSubQ, smpAgent}

data SMPSubscriber = SMPSubscriber
  { smpServer :: SMPServer,
    subscriberSubQ :: TQueue (NonEmpty ServerNtfSub),
    subThreadId :: TVar (Maybe (Weak ThreadId))
  }

newSMPSubscriber :: SMPServer -> IO SMPSubscriber
newSMPSubscriber smpServer = do
  subscriberSubQ <- newTQueueIO
  subThreadId <- newTVarIO Nothing
  pure SMPSubscriber {smpServer, subscriberSubQ, subThreadId}

data NtfPushServer = NtfPushServer
  { pushQ :: TBQueue (NtfTknRec, PushNotification),
    pushClients :: TMap PushProvider PushProviderClient,
    apnsConfig :: APNSPushClientConfig
  }

newNtfPushServer :: Natural -> APNSPushClientConfig -> IO NtfPushServer
newNtfPushServer qSize apnsConfig = do
  pushQ <- newTBQueueIO qSize
  pushClients <- TM.emptyIO
  pure NtfPushServer {pushQ, pushClients, apnsConfig}

newPushClient :: NtfPushServer -> PushProvider -> IO PushProviderClient
newPushClient NtfPushServer {apnsConfig, pushClients} pp = do
  c <- case apnsProviderHost pp of
    Nothing -> pure $ \_ _ -> pure ()
    Just host -> apnsPushProviderClient <$> createAPNSPushClient host apnsConfig
  atomically $ TM.insert pp c pushClients
  pure c

getPushClient :: NtfPushServer -> PushProvider -> IO PushProviderClient
getPushClient s@NtfPushServer {pushClients} pp =
  TM.lookupIO pp pushClients >>= maybe (newPushClient s pp) pure

data NtfRequest
  = NtfReqNew CorrId ANewNtfEntity
  | forall e. NtfEntityI e => NtfReqCmd (SNtfEntity e) (NtfEntityRec e) (Transmission (NtfCommand e))
  | NtfReqPing CorrId NtfEntityId

data NtfServerClient = NtfServerClient
  { rcvQ :: TBQueue (NonEmpty NtfRequest),
    sndQ :: TBQueue (NonEmpty (Transmission NtfResponse)),
    ntfThParams :: THandleParams NTFVersion 'TServer,
    connected :: TVar Bool,
    rcvActiveAt :: TVar SystemTime,
    sndActiveAt :: TVar SystemTime
  }

newNtfServerClient :: Natural -> THandleParams NTFVersion 'TServer -> SystemTime -> IO NtfServerClient
newNtfServerClient qSize ntfThParams ts = do
  rcvQ <- newTBQueueIO qSize
  sndQ <- newTBQueueIO qSize
  connected <- newTVarIO True
  rcvActiveAt <- newTVarIO ts
  sndActiveAt <- newTVarIO ts
  return NtfServerClient {rcvQ, sndQ, ntfThParams, connected, rcvActiveAt, sndActiveAt}
