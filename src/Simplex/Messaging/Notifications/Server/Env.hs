{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Env where

import Control.Concurrent (ThreadId)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import qualified Data.X509.Validation as XV
import Network.Socket
import qualified Network.TLS as TLS
import Numeric.Natural
import Simplex.Messaging.Client (ProtocolClientError (..), SMPClientError)
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store.Postgres
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Transport (NTFVersion, VersionRangeNTF)
import Simplex.Messaging.Protocol (BasicAuth, CorrId, Party (..), SMPServer, SParty (..), ServiceId, Transmission)
import Simplex.Messaging.Server.Env.STM (StartOptions (..))
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Session
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ASrvTransport, SMPServiceRole (..), ServiceCredentials (..), THandleParams, TransportPeer (..))
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials, TransportServerConfig, loadFingerprint, loadServerCredential)
import Simplex.Messaging.Util (liftEitherWith)
import System.Mem.Weak (Weak)
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
newNtfServerEnv config@NtfServerConfig {pushQSize, smpAgentCfg, apnsConfig, dbStoreConfig, ntfCredentials, useServiceCreds} = do
  random <- C.newRandom
  store <- newNtfDbStore dbStoreConfig
  tlsServerCreds <- loadServerCredential ntfCredentials
  XV.Fingerprint fp <- loadFingerprint ntfCredentials
  let dbService = if useServiceCreds then Just $ mkDbService random store else Nothing
  subscriber <- newNtfSubscriber smpAgentCfg dbService random
  pushServer <- newNtfPushServer pushQSize apnsConfig
  serverStats <- newNtfServerStats =<< getCurrentTime
  pure NtfEnv {config, subscriber, pushServer, store, random, tlsServerCreds, serverIdentity = C.KeyHash fp, serverStats}
  where
    mkDbService g st = DBService {getCredentials, updateServiceId}
      where
        getCredentials :: SMPServer -> IO (Either SMPClientError ServiceCredentials)
        getCredentials srv = runExceptT $ do
          ExceptT (withClientDB "" st $ \db -> getNtfServiceCredentials db srv >>= mapM (mkServiceCreds db)) >>= \case
            Just (C.KeyHash kh, serviceCreds) -> do
              serviceSignKey <- liftEitherWith PCEIOError $ C.x509ToPrivate' $ snd serviceCreds
              pure ServiceCredentials {serviceRole = SRNotifier, serviceCreds, serviceCertHash = XV.Fingerprint kh, serviceSignKey}
            Nothing -> throwE PCEServiceUnavailable -- this error cannot happen, as clients never connect to unknown servers
        mkServiceCreds db = \case
          (_, Just tlsCreds) -> pure tlsCreds
          (srvId, Nothing) -> do
            cred <- genCredentials g Nothing (25, 24 * 999999) "simplex"
            let tlsCreds = tlsCredentials [cred]
            setNtfServiceCredentials db srvId tlsCreds
            pure tlsCreds
        updateServiceId :: SMPServer -> Maybe ServiceId -> IO (Either SMPClientError ())
        updateServiceId srv serviceId_ = withClientDB "" st $ \db -> updateNtfServiceId db srv serviceId_

data NtfSubscriber = NtfSubscriber
  { smpSubscribers :: TMap SMPServer SMPSubscriberVar,
    subscriberSeq :: TVar Int,
    smpAgent :: SMPClientAgent 'NotifierService
  }

type SMPSubscriberVar = SessionVar SMPSubscriber

newNtfSubscriber :: SMPClientAgentConfig -> Maybe DBService -> TVar ChaChaDRG -> IO NtfSubscriber
newNtfSubscriber smpAgentCfg dbService random = do
  smpSubscribers <- TM.emptyIO
  subscriberSeq <- newTVarIO 0
  smpAgent <- newSMPClientAgent SNotifierService smpAgentCfg dbService random
  pure NtfSubscriber {smpSubscribers, subscriberSeq, smpAgent}

data SMPSubscriber = SMPSubscriber
  { smpServer :: SMPServer,
    smpServerId :: Int64,
    subscriberSubQ :: TQueue ServerNtfSub,
    subThreadId :: Weak ThreadId
  }

data NtfPushServer = NtfPushServer
  { pushQ :: TBQueue (Maybe T.Text, NtfTknRec, PushNotification), -- Maybe Text is a hostname of "own" server
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
