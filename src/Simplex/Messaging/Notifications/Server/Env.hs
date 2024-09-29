{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Env where

import Control.Concurrent (ThreadId)
import Control.Concurrent.Async (Async)
import Control.Logger.Simple
import Crypto.Random
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import Data.Word (Word16)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Client.Agent
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS
import Simplex.Messaging.Notifications.Server.Stats
import Simplex.Messaging.Notifications.Server.Store
import Simplex.Messaging.Notifications.Server.StoreLog
import Simplex.Messaging.Notifications.Transport (NTFVersion, VersionRangeNTF)
import Simplex.Messaging.Protocol (CorrId, SMPServer, Transmission)
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport, THandleParams, TransportPeer (..))
import Simplex.Messaging.Transport.Server (AddHTTP, ServerCredentials, TransportServerConfig, loadFingerprint, loadServerCredential)
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data NtfServerConfig = NtfServerConfig
  { transports :: [(ServiceName, ATransport, AddHTTP)],
    subIdBytes :: Int,
    regCodeBytes :: Int,
    clientQSize :: Natural,
    subQSize :: Natural,
    pushQSize :: Natural,
    smpAgentCfg :: SMPClientAgentConfig,
    apnsConfig :: APNSPushClientConfig,
    subsBatchSize :: Int,
    inactiveClientExpiration :: Maybe ExpirationConfig,
    storeLogFile :: Maybe FilePath,
    ntfCredentials :: ServerCredentials,
    -- stats config - see SMP server config
    logStatsInterval :: Maybe Int64,
    logStatsStartTime :: Int64,
    serverStatsLogFile :: FilePath,
    serverStatsBackupFile :: Maybe FilePath,
    ntfServerVRange :: VersionRangeNTF,
    transportConfig :: TransportServerConfig
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
    store :: NtfStore,
    storeLog :: Maybe (StoreLog 'WriteMode),
    random :: TVar ChaChaDRG,
    tlsServerCreds :: T.Credential,
    serverIdentity :: C.KeyHash,
    serverStats :: NtfServerStats
  }

newNtfServerEnv :: NtfServerConfig -> IO NtfEnv
newNtfServerEnv config@NtfServerConfig {subQSize, pushQSize, smpAgentCfg, apnsConfig, storeLogFile, ntfCredentials} = do
  random <- C.newRandom
  store <- newNtfStore
  logInfo "restoring subscriptions..."
  storeLog <- mapM (`readWriteNtfStore` store) storeLogFile
  logInfo "restored subscriptions"
  subscriber <- newNtfSubscriber subQSize smpAgentCfg random
  pushServer <- newNtfPushServer pushQSize apnsConfig
  tlsServerCreds <- loadServerCredential ntfCredentials
  Fingerprint fp <- loadFingerprint ntfCredentials
  serverStats <- newNtfServerStats =<< getCurrentTime
  pure NtfEnv {config, subscriber, pushServer, store, storeLog, random, tlsServerCreds, serverIdentity = C.KeyHash fp, serverStats}

data NtfSubscriber = NtfSubscriber
  { smpSubscribers :: TMap SMPServer SMPSubscriber,
    newSubQ :: TBQueue [NtfEntityRec 'Subscription],
    smpAgent :: SMPClientAgent
  }

newNtfSubscriber :: Natural -> SMPClientAgentConfig -> TVar ChaChaDRG -> IO NtfSubscriber
newNtfSubscriber qSize smpAgentCfg random = do
  smpSubscribers <- TM.emptyIO
  newSubQ <- newTBQueueIO qSize
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure NtfSubscriber {smpSubscribers, newSubQ, smpAgent}

data SMPSubscriber = SMPSubscriber
  { newSubQ :: TQueue (NonEmpty (NtfEntityRec 'Subscription)),
    subThreadId :: TVar (Maybe (Weak ThreadId))
  }

newSMPSubscriber :: IO SMPSubscriber
newSMPSubscriber = do
  newSubQ <- newTQueueIO
  subThreadId <- newTVarIO Nothing
  pure SMPSubscriber {newSubQ, subThreadId}

data NtfPushServer = NtfPushServer
  { pushQ :: TBQueue (NtfTknData, PushNotification),
    pushClients :: TMap PushProvider PushProviderClient,
    intervalNotifiers :: TMap NtfTokenId IntervalNotifier,
    apnsConfig :: APNSPushClientConfig
  }

data IntervalNotifier = IntervalNotifier
  { action :: Async (),
    token :: NtfTknData,
    interval :: Word16
  }

newNtfPushServer :: Natural -> APNSPushClientConfig -> IO NtfPushServer
newNtfPushServer qSize apnsConfig = do
  pushQ <- newTBQueueIO qSize
  pushClients <- TM.emptyIO
  intervalNotifiers <- TM.emptyIO
  pure NtfPushServer {pushQ, pushClients, intervalNotifiers, apnsConfig}

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
  { rcvQ :: TBQueue NtfRequest,
    sndQ :: TBQueue (Transmission NtfResponse),
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
