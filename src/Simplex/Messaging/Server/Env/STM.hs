{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeFamilies #-}

module Simplex.Messaging.Server.Env.STM where

import Control.Concurrent (ThreadId)
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.PubKey.RSA as RSA
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.System (SystemTime)
import qualified Data.X509 as X
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
import Simplex.Messaging.Server.MsgStore.Journal
import Simplex.Messaging.Server.MsgStore.STM
import Simplex.Messaging.Server.MsgStore.Types
import Simplex.Messaging.Server.NtfStore
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Server.StoreLog.ReadWrite
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ATransport, VersionRangeSMP, VersionSMP)
import Simplex.Messaging.Transport.Server
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data ServerConfig = ServerConfig
  { transports :: [(ServiceName, ATransport, AddHTTP)],
    smpHandshakeTimeout :: Int,
    tbqSize :: Natural,
    msgStoreType :: AStoreType,
    msgQueueQuota :: Int,
    maxJournalMsgCount :: Int,
    maxJournalStateLines :: Int,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    storeLogFile :: Maybe FilePath,
    storeMsgsFile :: Maybe FilePath,
    storeNtfsFile :: Maybe FilePath,
    -- | set to False to prohibit creating new queues
    allowNewQueues :: Bool,
    -- | simple password that the clients need to pass in handshake to be able to create new queues
    newQueueBasicAuth :: Maybe BasicAuth,
    -- | control port passwords,
    controlPortUserAuth :: Maybe BasicAuth,
    controlPortAdminAuth :: Maybe BasicAuth,
    -- | time after which the messages can be removed from the queues and check interval, seconds
    messageExpiration :: Maybe ExpirationConfig,
    expireMessagesOnStart :: Bool,
    -- | interval of inactivity after which journal queue is closed
    idleQueueInterval :: Int64,
    -- | notification expiration interval (seconds)
    notificationExpiration :: ExpirationConfig,
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
    -- | interval and file to save prometheus metrics
    prometheusInterval :: Maybe Int,
    prometheusMetricsFile :: FilePath,
    -- | notification delivery interval
    ntfDeliveryInterval :: Int,
    -- | interval between sending pending END events to unsubscribed clients, seconds
    pendingENDInterval :: Int,
    smpCredentials :: ServerCredentials,
    httpCredentials :: Maybe ServerCredentials,
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
      checkInterval = 14400 -- seconds, 4 hours
    }

defaultIdleQueueInterval :: Int64
defaultIdleQueueInterval = 28800 -- seconds, 8 hours

defNtfExpirationHours :: Int64
defNtfExpirationHours = 24

defaultNtfExpiration :: ExpirationConfig
defaultNtfExpiration =
  ExpirationConfig
    { ttl = defNtfExpirationHours * 3600, -- seconds
      checkInterval = 3600 -- seconds, 1 hour
    }

defaultInactiveClientExpiration :: ExpirationConfig
defaultInactiveClientExpiration =
  ExpirationConfig
    { ttl = 21600, -- seconds, 6 hours
      checkInterval = 3600 -- seconds, 1 hours
    }

defaultProxyClientConcurrency :: Int
defaultProxyClientConcurrency = 32

journalMsgStoreDepth :: Int
journalMsgStoreDepth = 5

defaultMaxJournalStateLines :: Int
defaultMaxJournalStateLines = 16

defaultMaxJournalMsgCount :: Int
defaultMaxJournalMsgCount = 256

defaultMsgQueueQuota :: Int
defaultMsgQueueQuota = 128

defaultStateTailSize :: Int
defaultStateTailSize = 512

data Env = Env
  { config :: ServerConfig,
    serverActive :: TVar Bool,
    serverInfo :: ServerInformation,
    server :: Server,
    serverIdentity :: KeyHash,
    msgStore :: AMsgStore,
    ntfStore :: NtfStore,
    random :: TVar ChaChaDRG,
    tlsServerCreds :: T.Credential,
    httpServerCreds :: Maybe T.Credential,
    serverStats :: ServerStats,
    sockets :: TVar [(ServiceName, SocketState)],
    clientSeq :: TVar ClientId,
    clients :: TVar (IntMap (Maybe AClient)),
    proxyAgent :: ProxyAgent -- senders served on this proxy
  }

data StoreType = STMemory | STJournalMemory

data SStoreType (s :: StoreType) where
  SSTMemory :: SStoreType 'STMemory
  SSTJournalMemory :: SStoreType 'STJournalMemory

data AStoreType = forall s. ASType (SStoreType s)

type family MsgStore s where
  MsgStore 'STMemory = STMMsgStore
  MsgStore 'STJournalMemory = JournalMsgStore 'QSMemory

data AMsgStore = forall s. MsgStoreClass (MsgStore s) => AMS (SStoreType s) (MsgStore s)

type Subscribed = Bool

data Server = Server
  { subscribedQ :: TQueue (RecipientId, ClientId, Subscribed),
    subscribers :: TMap RecipientId (TVar AClient),
    ntfSubscribedQ :: TQueue (NotifierId, ClientId, Subscribed),
    notifiers :: TMap NotifierId (TVar AClient),
    subClients :: TVar (IntMap AClient), -- clients with SMP subscriptions
    ntfSubClients :: TVar (IntMap AClient), -- clients with Ntf subscriptions
    pendingSubEvents :: TVar (IntMap (NonEmpty (RecipientId, Subscribed))),
    pendingNtfSubEvents :: TVar (IntMap (NonEmpty (NotifierId, Subscribed))),
    savingLock :: Lock
  }

newtype ProxyAgent = ProxyAgent
  { smpAgent :: SMPClientAgent
  }

type ClientId = Int

data AClient = forall s. MsgStoreClass (MsgStore s) => AClient (SStoreType s) (Client (MsgStore s))

clientId' :: AClient -> ClientId
clientId' (AClient _ Client {clientId}) = clientId

data Client s = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId Sub,
    ntfSubscriptions :: TMap NotifierId (),
    rcvQ :: TBQueue (NonEmpty (Maybe (StoreQueue s, QueueRec), Transmission Cmd)),
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
  subClients <- newTVarIO IM.empty
  ntfSubClients <- newTVarIO IM.empty
  pendingSubEvents <- newTVarIO IM.empty
  pendingNtfSubEvents <- newTVarIO IM.empty
  savingLock <- createLockIO
  return Server {subscribedQ, subscribers, ntfSubscribedQ, notifiers, subClients, ntfSubClients, pendingSubEvents, pendingNtfSubEvents, savingLock}

newClient :: SStoreType s -> ClientId -> Natural -> VersionSMP -> ByteString -> SystemTime -> IO (Client (MsgStore s))
newClient _msType clientId qSize thVersion sessionId createdAt = do
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
newEnv config@ServerConfig {smpCredentials, httpCredentials, storeLogFile, msgStoreType, storeMsgsFile, smpAgentCfg, information, messageExpiration, idleQueueInterval, msgQueueQuota, maxJournalMsgCount, maxJournalStateLines} = do
  serverActive <- newTVarIO True
  server <- newServer
  msgStore <- case msgStoreType of
    ASType SSTMemory -> do
      st <- newMsgStore STMStoreConfig {storePath = storeMsgsFile, quota = msgQueueQuota}
      loadStoreLog st $> AMS SSTMemory st
    ASType SSTJournalMemory -> case storeMsgsFile of
      Just storePath -> do
        let cfg = JournalStoreConfig {storePath, quota = msgQueueQuota, pathParts = journalMsgStoreDepth, queueStoreType = SQSMemory, maxMsgCount = maxJournalMsgCount, maxStateLines = maxJournalStateLines, stateTailSize = defaultStateTailSize, idleInterval = idleQueueInterval}
        st <- newMsgStore cfg
        loadStoreLog st $> AMS SSTJournalMemory st
      Nothing -> putStrLn "Error: journal msg store requires that restore_messages is enabled in [STORE_LOG]" >> exitFailure
  ntfStore <- NtfStore <$> TM.emptyIO
  random <- C.newRandom
  tlsServerCreds <- getCredentials "SMP" smpCredentials
  httpServerCreds <- mapM (getCredentials "HTTPS") httpCredentials
  mapM_ checkHTTPSCredentials httpServerCreds
  Fingerprint fp <- loadFingerprint smpCredentials
  let serverIdentity = KeyHash fp
  serverStats <- newServerStats =<< getCurrentTime
  sockets <- newTVarIO []
  clientSeq <- newTVarIO 0
  clients <- newTVarIO mempty
  proxyAgent <- newSMPProxyAgent smpAgentCfg random
  pure Env {serverActive, config, serverInfo, server, serverIdentity, msgStore, ntfStore, random, tlsServerCreds, httpServerCreds, serverStats, sockets, clientSeq, clients, proxyAgent}
  where
    -- createMsgStore = case (msgStoreType, storeMsgsFile) of
    --   (AMSType SSTMemory, _) -> do
    --     st <- newMsgStore STMStoreConfig {storePath = storeLogFile, quota = msgQueueQuota}
    --     loadStoreLog st $> AMS SSTMemory st
    --   (AMSType SSTJournalMemory, Just storePath) -> do
    --     st <- newMsgStore $ storeCfg SQSMemory storePath
    --     loadStoreLog st $> AMS SSTJournalMemory st
    --   (_, Nothing) -> putStrLn "Error: journal msg store requires that restore_messages is enabled in [STORE_LOG]" >> exitFailure
    --   where
    --     storeCfg :: SQSType s -> FilePath -> JournalStoreConfig s
    --     storeCfg queueStoreType storePath =
    --       JournalStoreConfig {storePath, quota = msgQueueQuota, pathParts = journalMsgStoreDepth, queueStoreType, maxMsgCount = maxJournalMsgCount, maxStateLines = maxJournalStateLines, stateTailSize = defaultStateTailSize, idleInterval = idleQueueInterval}
    loadStoreLog :: MsgStoreClass s => s -> IO ()
    loadStoreLog st = forM_ storeLogFile $ \f -> do
      logInfo $ "restoring queues from file " <> T.pack f
      sl <- readWriteQueueStore f st
      setStoreLog st sl
    getCredentials protocol creds = do
      files <- missingCreds
      unless (null files) $ do
        putStrLn $ "Error: no " <> protocol <> " credentials: " <> intercalate ", " files
        when (protocol == "HTTPS") $ putStrLn letsEncrypt
        exitFailure
      loadServerCredential creds
      where
        missingfile f = (\y -> [f | not y]) <$> doesFileExist f
        missingCreds = do
          let files = maybe id (:) (caCertificateFile creds) [certificateFile creds, privateKeyFile creds]
           in concat <$> mapM missingfile files
    checkHTTPSCredentials (X.CertificateChain cc, _k) =
      -- LetsEncrypt provides ECDSA with insecure curve p256 (https://safecurves.cr.yp.to)
      case map (X.signedObject . X.getSigned) cc of
        X.Certificate {X.certPubKey = X.PubKeyRSA rsa} : _ca | RSA.public_size rsa >= 512 -> pure ()
        _ -> do
          putStrLn $ "Error: unsupported HTTPS credentials, required 4096-bit RSA\n" <> letsEncrypt
          exitFailure
    letsEncrypt = "Use Let's Encrypt to generate: certbot certonly --standalone -d yourdomainname --key-type rsa --rsa-key-size 4096"
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
          | isJust storeMsgsFile = SPMMessages
          | otherwise = SPMQueues

newSMPProxyAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> IO ProxyAgent
newSMPProxyAgent smpAgentCfg random = do
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure ProxyAgent {smpAgent}

readWriteQueueStore :: MsgStoreClass s => FilePath -> s -> IO (StoreLog 'WriteMode)
readWriteQueueStore = readWriteStoreLog readQueueStore writeQueueStore
