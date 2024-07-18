{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Monad.IO.Unlift
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
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
    { ttl = 43200, -- seconds, 12 hours
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
    random :: TVar ChaChaDRG,
    storeLog :: Maybe (StoreLog 'WriteMode),
    tlsServerParams :: T.ServerParams,
    serverStats :: ServerStats,
    sockets :: SocketState,
    clientSeq :: TVar ClientId,
    clients :: TVar (IntMap Client),
    proxyAgent :: ProxyAgent -- senders served on this proxy
  }

type Subscribed = Bool

data Server = Server
  { subscribedQ :: TQueue (RecipientId, Client, Subscribed),
    subscribers :: TMap RecipientId Client,
    ntfSubscribedQ :: TQueue (NotifierId, Client, Subscribed),
    notifiers :: TMap NotifierId Client,
    savingLock :: Lock
  }

newtype ProxyAgent = ProxyAgent
  { smpAgent :: SMPClientAgent
  }

type ClientId = Int

data Client = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId Sub,
    ntfSubscriptions :: TMap NotifierId (),
    rcvQ :: TBQueue (NonEmpty (Maybe QueueRec, Transmission Cmd)),
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

data SubscriptionThread = NoSub | SubPending | SubThread (Weak ThreadId) | ProhibitSub

data Sub = Sub
  { subThread :: TVar SubscriptionThread,
    delivered :: TMVar MsgId
  }

newServer :: STM Server
newServer = do
  subscribedQ <- newTQueue
  subscribers <- TM.empty
  ntfSubscribedQ <- newTQueue
  notifiers <- TM.empty
  savingLock <- createLock
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers, savingLock}

newClient :: TVar ClientId -> Natural -> VersionSMP -> ByteString -> SystemTime -> STM Client
newClient nextClientId qSize thVersion sessionId createdAt = do
  clientId <- stateTVar nextClientId $ \next -> (next, next + 1)
  subscriptions <- TM.empty
  ntfSubscriptions <- TM.empty
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  procThreads <- newTVar 0
  endThreads <- newTVar IM.empty
  endThreadSeq <- newTVar 0
  connected <- newTVar True
  rcvActiveAt <- newTVar createdAt
  sndActiveAt <- newTVar createdAt
  return Client {clientId, subscriptions, ntfSubscriptions, rcvQ, sndQ, msgQ, procThreads, endThreads, endThreadSeq, thVersion, sessionId, connected, createdAt, rcvActiveAt, sndActiveAt}

newSubscription :: SubscriptionThread -> STM Sub
newSubscription st = do
  delivered <- newEmptyTMVar
  subThread <- newTVar st
  return Sub {subThread, delivered}

newEnv :: ServerConfig -> IO Env
newEnv config@ServerConfig {caCertificateFile, certificateFile, privateKeyFile, storeLogFile, smpAgentCfg, transportConfig, information, messageExpiration} = do
  server <- atomically newServer
  queueStore <- atomically newQueueStore
  msgStore <- atomically newMsgStore
  random <- liftIO C.newRandom
  storeLog <- restoreQueues queueStore `mapM` storeLogFile
  tlsServerParams <- loadTLSServerParams caCertificateFile certificateFile privateKeyFile (alpn transportConfig)
  Fingerprint fp <- loadFingerprint caCertificateFile
  let serverIdentity = KeyHash fp
  serverStats <- atomically . newServerStats =<< getCurrentTime
  sockets <- atomically newSocketState
  clientSeq <- newTVarIO 0
  clients <- newTVarIO mempty
  proxyAgent <- atomically $ newSMPProxyAgent smpAgentCfg random
  pure Env {config, serverInfo, server, serverIdentity, queueStore, msgStore, random, storeLog, tlsServerParams, serverStats, sockets, clientSeq, clients, proxyAgent}
  where
    restoreQueues :: QueueStore -> FilePath -> IO (StoreLog 'WriteMode)
    restoreQueues QueueStore {queues, senders, notifiers} f = do
      (qs, s) <- readWriteStoreLog f
      atomically $ do
        writeTVar queues =<< mapM newTVar qs
        writeTVar senders $! M.foldr' addSender M.empty qs
        writeTVar notifiers $! M.foldr' addNotifier M.empty qs
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

newSMPProxyAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> STM ProxyAgent
newSMPProxyAgent smpAgentCfg random = do
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure ProxyAgent {smpAgent}
