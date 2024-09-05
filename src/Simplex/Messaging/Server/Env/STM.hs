{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Logger.Simple
import Control.Monad
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (ServiceName)
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Client.Agent (SMPClientAgent, SMPClientAgentConfig, newSMPClientAgent)
import Simplex.Messaging.Crypto (KeyHash (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.DataLog
import Simplex.Messaging.Server.DataStore
import Simplex.Messaging.Server.Expiration
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.QueueStore (NtfCreds (..), QueueRec (..))
import Simplex.Messaging.Server.QueueStore.STM
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport, VersionRangeSMP, VersionSMP)
import Simplex.Messaging.Transport.Server (SocketState, TransportServerConfig, alpn, loadFingerprint, loadTLSServerParams, newSocketState)
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data ServerConfig = ServerConfig
  { transports :: [(ServiceName, ATransport)],
    smpHandshakeTimeout :: Int,
    tbqSize :: Natural,
    msgQueueQuota :: Int,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    storeLogFile :: Maybe FilePath,
    dataLogFile :: Maybe FilePath,
    storeMsgsFile :: Maybe FilePath,
    -- | set to False to prohibit creating new queues
    allowNewQueues :: Bool,
    -- | simple password that the clients need to pass in handshake to be able to create new queues
    newQueueBasicAuth :: Maybe BasicAuth,
    -- | control port passwords,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
    -- | time after which the messages can be removed from the queues and check interval, seconds
    messageExpiration :: Maybe ExpirationConfig,
    -- | time after which the socket with inactive client can be disconnected (without any messages or commands, incl. PING),
    -- and check interval, seconds
    inactiveClientExpiration :: Maybe ExpirationConfig,
    -- | log SMP server usage statistics, only aggregates are logged, seconds
    logStatsInterval :: Maybe Int64,
    -- | time of the day when the stats are logged first, to log at consistent times,
    -- irrespective of when the server is started (seconds from 00:00 UTC)
    logStatsStartTime :: Int64,
    -- | file to log stats
    serverStatsLogFile :: FilePath,
    -- | file to save and restore stats
    serverStatsBackupFile :: Maybe FilePath,
    -- | interval between sending pending END events to unsubscribed clients, seconds
    pendingENDInterval :: Int,
    -- | CA certificate private key is not needed for initialization
    caCertificateFile :: FilePath,
    privateKeyFile :: FilePath,
    certificateFile :: FilePath,
    -- | SMP client-server protocol version range
    smpServerVRange :: VersionRangeSMP,
    -- | TCP transport config
    transportConfig :: TransportServerConfig,
    -- | run listener on control port
    controlPort :: Maybe ServiceName,
    -- | SMP proxy config
    smpAgentCfg :: SMPClientAgentConfig,
    allowSMPProxy :: Bool, -- auth is the same with `newQueueBasicAuth`
    serverClientConcurrency :: Int,
    -- | server public information
    information :: Maybe ServerPublicInfo
  }

defMsgExpirationDays :: Int64
defMsgExpirationDays = 21

defaultMessageExpiration :: ExpirationConfig
defaultMessageExpiration =
  ExpirationConfig
    { ttl = defMsgExpirationDays * 86400, -- seconds
      checkInterval = 43200 -- seconds, 12 hours
    }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 21600, -- seconds, 6 hours
      checkInterval = 3600 -- seconds, 1 hours
    }

defaultProxyClientConcurrency :: Int
defaultProxyClientConcurrency = 32

data Env = Env
  { config :: ServerConfig,
    serverInfo :: ServerInformation,
    server :: Server,
    serverIdentity :: KeyHash,
    queueStore :: QueueStore,
    msgStore :: STMMsgStore,
    dataStore :: TMap BlobId DataRec,
    random :: TVar ChaChaDRG,
    storeLog :: Maybe (StoreLog 'WriteMode),
    dataLog :: Maybe (StoreLog 'WriteMode),
    tlsServerParams :: T.ServerParams,
    serverStats :: ServerStats,
    sockets :: SocketState,
    clientSeq :: TVar ClientId,
    clients :: TVar (IntMap (Maybe Client)),
    proxyAgent :: ProxyAgent -- senders served on this proxy
  }

type Subscribed = Bool

data Server = Server
  { subscribedQ :: TQueue (RecipientId, ClientId, Subscribed),
    subscribers :: TMap RecipientId (TVar Client),
    ntfSubscribedQ :: TQueue (NotifierId, ClientId, Subscribed),
    notifiers :: TMap NotifierId (TVar Client),
    pendingENDs :: TVar (IntMap (NonEmpty RecipientId)),
    pendingNtfENDs :: TVar (IntMap (NonEmpty NotifierId)),
    savingLock :: Lock
  }

newtype ProxyAgent = ProxyAgent
  { smpAgent :: SMPClientAgent
  }

type ClientId = Int

data VerificationResult = VRVerified (Maybe QueueRec) | VRVerifiedData (Maybe DataRec) | VRFailed

data Client = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId Sub,
    ntfSubscriptions :: TMap NotifierId (),
    rcvQ :: TBQueue (NonEmpty (VerificationResult, Transmission Cmd)),
    sndQ :: TBQueue (NonEmpty (Transmission BrokerMsg)),
    msgQ :: TBQueue (NonEmpty (Transmission BrokerMsg)),
    procThreads :: TVar Int,
    endThreads :: TVar (IntMap (Weak ThreadId)),
    endThreadSeq :: TVar Int,
    thVersion :: VersionSMP,
    sessionId :: ByteString,
    connected :: TVar Bool,
    createdAt :: SystemTime,
    rcvActiveAt :: TVar SystemTime,
    sndActiveAt :: TVar SystemTime
  }

data ServerSub = ServerSub (TVar SubscriptionThread) | ProhibitSub

data SubscriptionThread = NoSub | SubPending | SubThread (Weak ThreadId)

data Sub = Sub
  { subThread :: ServerSub, -- Nothing value indicates that sub
    delivered :: TMVar MsgId
  }

newServer :: IO Server
newServer = do
  subscribedQ <- newTQueueIO
  subscribers <- TM.emptyIO
  ntfSubscribedQ <- newTQueueIO
  notifiers <- TM.emptyIO
  pendingENDs <- newTVarIO IM.empty
  pendingNtfENDs <- newTVarIO IM.empty
  savingLock <- atomically createLock
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers, pendingENDs, pendingNtfENDs, savingLock}

newClient :: ClientId -> Natural -> VersionSMP -> ByteString -> SystemTime -> IO Client
newClient clientId qSize thVersion sessionId createdAt = do
  subscriptions <- TM.emptyIO
  ntfSubscriptions <- TM.emptyIO
  rcvQ <- newTBQueueIO qSize
  sndQ <- newTBQueueIO qSize
  msgQ <- newTBQueueIO qSize
  procThreads <- newTVarIO 0
  endThreads <- newTVarIO IM.empty
  endThreadSeq <- newTVarIO 0
  connected <- newTVarIO True
  rcvActiveAt <- newTVarIO createdAt
  sndActiveAt <- newTVarIO createdAt
  return Client {clientId, subscriptions, ntfSubscriptions, rcvQ, sndQ, msgQ, procThreads, endThreads, endThreadSeq, thVersion, sessionId, connected, createdAt, rcvActiveAt, sndActiveAt}

newSubscription :: SubscriptionThread -> STM Sub
newSubscription st = do
  delivered <- newEmptyTMVar
  subThread <- ServerSub <$> newTVar st
  return Sub {subThread, delivered}

newProhibitedSub :: STM Sub
newProhibitedSub = do
  delivered <- newEmptyTMVar
  return Sub {subThread = ProhibitSub, delivered}

newEnv :: ServerConfig -> IO Env
newEnv config@ServerConfig {caCertificateFile, certificateFile, privateKeyFile, storeLogFile, dataLogFile, smpAgentCfg, transportConfig, information, messageExpiration} = do
  server <- newServer
  queueStore <- newQueueStore
  msgStore <- newMsgStore
  dataStore <- TM.emptyIO
  random <- C.newRandom
  storeLog <-
    forM storeLogFile $ \f -> do
      logInfo $ "restoring queues from file " <> T.pack f
      restoreQueues queueStore f
  dataLog <-
    forM dataLogFile $ \f -> do
      logInfo $ "restoring data blobs from file " <> T.pack f
      restoreDataBlobs dataStore f
  tlsServerParams <- loadTLSServerParams caCertificateFile certificateFile privateKeyFile (alpn transportConfig)
  Fingerprint fp <- loadFingerprint caCertificateFile
  let serverIdentity = KeyHash fp
  serverStats <- newServerStats =<< getCurrentTime
  sockets <- newSocketState
  clientSeq <- newTVarIO 0
  clients <- newTVarIO mempty
  proxyAgent <- newSMPProxyAgent smpAgentCfg random
  pure Env {config, serverInfo, server, serverIdentity, queueStore, msgStore, dataStore, random, storeLog, dataLog, tlsServerParams, serverStats, sockets, clientSeq, clients, proxyAgent}
  where
    restoreQueues :: QueueStore -> FilePath -> IO (StoreLog 'WriteMode)
    restoreQueues QueueStore {queues, senders, notifiers} f = do
      (qs, s) <- readWriteStoreLog f
      atomically . writeTVar queues =<< mapM newTVarIO qs
      atomically $ writeTVar senders $! M.foldr' addSender M.empty qs
      atomically $ writeTVar notifiers $! M.foldr' addNotifier M.empty qs
      pure s
    restoreDataBlobs :: TMap BlobId DataRec -> FilePath -> IO (StoreLog 'WriteMode)
    restoreDataBlobs dataStore f = do
      (ds, s) <- readWriteDataLog f
      atomically $ writeTVar dataStore ds
      pure s
    addSender :: QueueRec -> Map SenderId RecipientId -> Map SenderId RecipientId
    addSender q = M.insert (senderId q) (recipientId q)
    addNotifier :: QueueRec -> Map NotifierId RecipientId -> Map NotifierId RecipientId
    addNotifier q = case notifier q of
      Nothing -> id
      Just NtfCreds {notifierId} -> M.insert notifierId (recipientId q)
    serverInfo =
      ServerInformation
        { information,
          config =
            ServerPublicConfig
              { persistence,
                messageExpiration = ttl <$> messageExpiration,
                statsEnabled = isJust $ logStatsInterval config,
                newQueuesAllowed = allowNewQueues config,
                basicAuthEnabled = isJust $ newQueueBasicAuth config
              }
        }
      where
        persistence
          | isNothing storeLogFile = SPMMemoryOnly
          | isJust (storeMsgsFile config) = SPMMessages
          | otherwise = SPMQueues

newSMPProxyAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> IO ProxyAgent
newSMPProxyAgent smpAgentCfg random = do
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure ProxyAgent {smpAgent}
