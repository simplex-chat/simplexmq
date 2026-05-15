{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Env
  ( NtfServerConfig (..),
    NtfEnv (..),
    NtfSubscriber (..),
    SMPSubscriberVar,
    SMPSubscriber (..),
    NtfPushServer (..),
    PushClientVar,
    NtfRequest (..),
    NtfServerClient (..),
    defaultInactiveClientExpiration,
    newNtfServerEnv,
    newNtfSubscriber,
    newNtfPushServer,
    getPushClient,
    getDeliveryLock,
    newNtfServerClient,
  ) where

import Control.Concurrent (ThreadId)
import qualified Control.Exception as E
import Control.Logger.Simple
import Control.Monad
import Crypto.Random
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import qualified Data.X509.Validation as XV
import Network.Socket
import qualified Network.TLS as TLS
import Numeric.Natural
import Simplex.Messaging.Client (ProtocolClientConfig (..))
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
import Simplex.Messaging.Protocol (BasicAuth, CorrId, Party (..), SMPServer, SParty (..), Transmission)
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Server.StoreLog (closeStoreLog)
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ASrvTransport, SMPServiceRole (..), ServiceCredentials (..), THandleParams, TransportPeer (..))
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials, TransportServerConfig, loadFingerprint, loadServerCredential)
import System.Exit (exitFailure)
import System.Mem.Weak (Weak)
import UnliftIO.MVar
import UnliftIO.STM

data NtfServerConfig = NtfServerConfig
  { transports :: [(ServiceName, ASrvTransport, AddHTTP)],
    controlPort :: Maybe ServiceName,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
    subIdBytes :: Int,
    regCodeBytes :: Int,
    clientQSize :: Natural,
    pushQSize :: Natural,
    smpAgentCfg :: SMPClientAgentConfig,
    apnsConfig :: APNSPushClientConfig,
    subsBatchSize :: Int,
    inactiveClientExpiration :: Maybe ExpirationConfig,
    dbStoreConfig :: PostgresStoreCfg,
    ntfCredentials :: ServerCredentials,
    -- send service credentials and use service subscriptions when SMP server supports them
    useServiceCreds :: Bool,
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
newNtfServerEnv config@NtfServerConfig {pushQSize, smpAgentCfg, apnsConfig, dbStoreConfig, ntfCredentials, useServiceCreds, startOptions} = do
  when (compactLog startOptions) $ compactDbStoreLog $ dbStoreLogPath dbStoreConfig
  random <- C.newRandom
  store <- newNtfDbStore dbStoreConfig
  tlsServerCreds <- loadServerCredential ntfCredentials
  serviceCertHash@(XV.Fingerprint fp) <- loadFingerprint ntfCredentials
  smpAgentCfg' <-
    if useServiceCreds
      then do
        serviceSignKey <- case C.x509ToPrivate' $ snd tlsServerCreds of
          Right pk -> pure pk
          Left e -> putStrLn ("Server has no valid key: " <> show e) >> exitFailure
        let service = ServiceCredentials {serviceRole = SRNotifier, serviceCreds = tlsServerCreds, serviceCertHash, serviceSignKey}
        pure smpAgentCfg {smpCfg = (smpCfg smpAgentCfg) {serviceCredentials = Just service}}
      else pure smpAgentCfg
  subscriber <- newNtfSubscriber smpAgentCfg' random
  pushServer <- newNtfPushServer pushQSize apnsConfig
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
  { smpSubscribers :: TMap SMPServer SMPSubscriberVar,
    subscriberSeq :: TVar Int,
    smpAgent :: SMPClientAgent 'NotifierService
  }

type SMPSubscriberVar = SessionVar SMPSubscriber

newNtfSubscriber :: SMPClientAgentConfig -> TVar ChaChaDRG -> IO NtfSubscriber
newNtfSubscriber smpAgentCfg random = do
  smpSubscribers <- TM.emptyIO
  subscriberSeq <- newTVarIO 0
  smpAgent <- newSMPClientAgent SNotifierService smpAgentCfg random
  pure NtfSubscriber {smpSubscribers, subscriberSeq, smpAgent}

data SMPSubscriber = SMPSubscriber
  { smpServer :: SMPServer,
    smpServerId :: Int64,
    subscriberSubQ :: TQueue ServerNtfSub,
    subThreadId :: Weak ThreadId
  }

data NtfPushServer = NtfPushServer
  { pushQ :: TBQueue (Maybe T.Text, NtfTknRec, PushNotification), -- Maybe Text is a hostname of "own" server
    pushClients :: TMap PushProvider PushClientVar,
    pushClientSeq :: TVar Int,
    -- one lock per srvHost_ serializes per-server delivery while different servers proceed in parallel
    srvDeliveryLocks :: TMap (Maybe T.Text) (MVar ()),
    apnsConfig :: APNSPushClientConfig
  }

-- The Either communicates client-creation failure from the winner to the waiters.
type PushClientVar = SessionVar (Either E.SomeException PushProviderClient)

newNtfPushServer :: Natural -> APNSPushClientConfig -> IO NtfPushServer
newNtfPushServer qSize apnsConfig = do
  pushQ <- newTBQueueIO qSize
  pushClients <- TM.emptyIO
  pushClientSeq <- newTVarIO 0
  srvDeliveryLocks <- TM.emptyIO
  pure NtfPushServer {pushQ, pushClients, pushClientSeq, srvDeliveryLocks, apnsConfig}

getDeliveryLock :: TMap (Maybe T.Text) (MVar ()) -> Maybe T.Text -> IO (MVar ())
getDeliveryLock locks k = do
  newLock <- newMVar ()
  atomically $ TM.lookup k locks >>= maybe (TM.insert k newLock locks $> newLock) pure

-- | Single-flight access to the per-provider push client.
-- take (getSessVar) → create (newPushClient) or wait (waitForPushClient).
-- The returned PushClientVar is the handle retryDeliver passes to removeSessVar to evict
-- this specific instance before re-fetching.
getPushClient :: NtfPushServer -> PushProvider -> IO (PushProviderClient, PushClientVar)
getPushClient s pp = do
  ts <- getCurrentTime
  atomically (getSessVar (pushClientSeq s) pp (pushClients s) ts) >>= either (newPushClient s pp) waitForPushClient

newPushClient :: NtfPushServer -> PushProvider -> PushClientVar -> IO (PushProviderClient, PushClientVar)
newPushClient NtfPushServer {pushClients, apnsConfig} pp v = do
  r <- E.try $ case apnsProviderHost pp of
    Nothing -> pure $ \_ _ -> pure ()
    Just host -> apnsPushProviderClient <$> createAPNSPushClient host apnsConfig
  atomically $ do
    putTMVar (sessionVar v) r
    case r of
      Left _ -> removeSessVar v pp pushClients
      Right _ -> pure ()
  either E.throwIO (\c -> pure (c, v)) r

waitForPushClient :: PushClientVar -> IO (PushProviderClient, PushClientVar)
waitForPushClient v =
  atomically (readTMVar $ sessionVar v) >>= either E.throwIO (\c -> pure (c, v))

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
