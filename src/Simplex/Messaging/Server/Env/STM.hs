{-# LANGUAGE CPP #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
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
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
#if __GLASGOW_HASKELL__ == 810
{-# LANGUAGE UndecidableInstances #-}
#endif
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Messaging.Server.Env.STM
  ( ServerConfig (..),
    ServerStoreCfg (..),
    -- AServerStoreCfg (..),
    SupportedStore,
    StorePaths (..),
    StartOptions (..),
    Env (..),
    Server (..),
    ServerSubscribers (..),
    SubscribedClients,
    ProxyAgent (..),
    Client (..),
    ClientId,
    ClientSub (..),
    Sub (..),
    ServerSub (..),
    SubscriptionThread (..),
    MsgStoreType,
    MsgStore (..),
    AStoreType (..),
    newEnv,
    mkJournalStoreConfig,
    msgStore,
    fromMsgStore,
    newClient,
    getServerClients,
    getServerClient,
    insertServerClient,
    deleteServerClient,
    getSubscribedClients,
    getSubscribedClient,
    upsertSubscribedClient,
    lookupSubscribedClient,
    lookupDeleteSubscribedClient,
    deleteSubcribedClient,
    sameClientId,
    sameClient,
    newSubscription,
    newProhibitedSub,
    defaultMsgQueueQuota,
    defMsgExpirationDays,
    defNtfExpirationHours,
    defaultMessageExpiration,
    defaultNtfExpiration,
    defaultInactiveClientExpiration,
    defaultProxyClientConcurrency,
    defaultMaxJournalMsgCount,
    defaultMaxJournalStateLines,
    defaultIdleQueueInterval,
    journalMsgStoreDepth,
    readWriteQueueStore,
    noPostgresExit,
  )
where

import Control.Concurrent (ThreadId)
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.PubKey.RSA as RSA
import Crypto.Random
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Kind (Constraint)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime, nominalDay)
import Data.Time.Clock.System (SystemTime)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..))
import GHC.TypeLits (TypeError)
import qualified GHC.TypeLits as TE
import Network.Socket (ServiceName)
import qualified Network.TLS as T
import Numeric.Natural
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
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
import Simplex.Messaging.Server.QueueStore.Postgres.Config
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore, setStoreLog)
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.Stats
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Server.StoreLog.ReadWrite
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (ASrvTransport, SMPVersion, THPeerClientService, THandleParams, TransportPeer (..), VersionRangeSMP)
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util (ifM, whenM, ($>>=))
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data ServerConfig s = ServerConfig
  { transports :: [(ServiceName, ASrvTransport, AddHTTP)],
    smpHandshakeTimeout :: Int,
    tbqSize :: Natural,
    msgQueueQuota :: Int,
    maxJournalMsgCount :: Int,
    maxJournalStateLines :: Int,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    serverStoreCfg :: ServerStoreCfg s,
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
    information :: Maybe ServerPublicInfo,
    startOptions :: StartOptions
  }

data StartOptions = StartOptions
  { maintenance :: Bool,
    compactLog :: Bool,
    logLevel :: LogLevel,
    skipWarnings :: Bool,
    confirmMigrations :: MigrationConfirmation
  }

defMsgExpirationDays :: Int64
defMsgExpirationDays = 21

defaultMessageExpiration :: ExpirationConfig
defaultMessageExpiration =
  ExpirationConfig
    { ttl = defMsgExpirationDays * 86400, -- seconds
      checkInterval = 7200 -- seconds, 2 hours
    }

defaultIdleQueueInterval :: Int64
defaultIdleQueueInterval = 14400 -- seconds, 4 hours

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

data Env s = Env
  { config :: ServerConfig s,
    serverActive :: TVar Bool,
    serverInfo :: ServerInformation,
    server :: Server s,
    serverIdentity :: KeyHash,
    msgStore_ :: MsgStore s,
    ntfStore :: NtfStore,
    random :: TVar ChaChaDRG,
    tlsServerCreds :: T.Credential,
    httpServerCreds :: Maybe T.Credential,
    serverStats :: ServerStats,
    sockets :: TVar [(ServiceName, SocketState)],
    clientSeq :: TVar ClientId,
    proxyAgent :: ProxyAgent -- senders served on this proxy
  }

msgStore :: Env s -> s
msgStore = fromMsgStore . msgStore_
{-# INLINE msgStore #-}

fromMsgStore :: MsgStore s -> s
fromMsgStore = \case
  StoreMemory s -> s
  StoreJournal s -> s
{-# INLINE fromMsgStore #-}

type family SupportedStore (qs :: QSType) (ms :: MSType) :: Constraint where
  SupportedStore 'QSMemory 'MSMemory = ()
  SupportedStore 'QSMemory 'MSJournal = ()
  SupportedStore 'QSPostgres 'MSJournal = ()
  SupportedStore 'QSPostgres 'MSMemory =
    (Int ~ Bool, TypeError ('TE.Text "Storing messages in memory with Postgres DB is not supported"))

data AStoreType =
  forall qs ms. (SupportedStore qs ms, MsgStoreClass (MsgStoreType qs ms)) =>
  ASType (SQSType qs) (SMSType ms)

data ServerStoreCfg s where
  SSCMemory :: Maybe StorePaths -> ServerStoreCfg STMMsgStore
  SSCMemoryJournal :: {storeLogFile :: FilePath, storeMsgsPath :: FilePath} -> ServerStoreCfg (JournalMsgStore 'QSMemory)
  SSCDatabaseJournal :: {storeCfg :: PostgresStoreCfg, storeMsgsPath' :: FilePath} -> ServerStoreCfg (JournalMsgStore 'QSPostgres)

data StorePaths = StorePaths {storeLogFile :: FilePath, storeMsgsFile :: Maybe FilePath}

type family MsgStoreType (qs :: QSType) (ms :: MSType) where
  MsgStoreType 'QSMemory 'MSMemory = STMMsgStore
  MsgStoreType qs 'MSJournal = JournalMsgStore qs

data MsgStore s where
  StoreMemory :: STMMsgStore -> MsgStore STMMsgStore
  StoreJournal :: JournalMsgStore qs -> MsgStore (JournalMsgStore qs)

data Server s = Server
  { clients :: ServerClients s,
    subscribers :: ServerSubscribers s,
    ntfSubscribers :: ServerSubscribers s,
    savingLock :: Lock
  }

-- not exported, to prevent concurrent IntMap lookups inside STM transactions.
newtype ServerClients s = ServerClients {serverClients :: TVar (IntMap (Client s))}

data ServerSubscribers s = ServerSubscribers
  { subQ :: TQueue (ClientSub, ClientId),
    queueSubscribers :: SubscribedClients s,
    serviceSubscribers :: SubscribedClients s, -- service clients with long-term certificates that have subscriptions
    totalServiceSubs :: TVar Int64,
    subClients :: TVar IntSet, -- clients with individual or service subscriptions
    pendingEvents :: TVar (IntMap (NonEmpty (EntityId, BrokerMsg)))
  }

-- not exported, to prevent accidental concurrent Map lookups inside STM transactions.
-- Map stores TVars with pointers to the clients rather than client ID to allow reading the same TVar
-- inside transactions to ensure that transaction is re-evaluated in case subscriber changes.
-- Storing Maybe allows to have continuity of subscription when the same user client disconnects and re-connects -
-- any STM transaction that reads subscribed client will re-evaluate in this case.
-- The subscriptions that were made at any point are not removed -
-- this is a better trade-off with intermittently connected mobile clients.
data SubscribedClients s = SubscribedClients (TMap EntityId (TVar (Maybe (Client s))))

getSubscribedClients :: SubscribedClients s -> IO (Map EntityId (TVar (Maybe (Client s))))
getSubscribedClients (SubscribedClients cs) = readTVarIO cs

getSubscribedClient :: EntityId -> SubscribedClients s -> IO (Maybe (TVar (Maybe (Client s))))
getSubscribedClient entId (SubscribedClients cs) = TM.lookupIO entId cs
{-# INLINE getSubscribedClient #-}

-- insert subscribed and current client, return previously subscribed client if it is different
upsertSubscribedClient :: EntityId -> Client s -> SubscribedClients s -> STM (Maybe (Client s))
upsertSubscribedClient entId c (SubscribedClients cs) =
  TM.lookup entId cs >>= \case
    Nothing -> Nothing <$ TM.insertM entId (newTVar (Just c)) cs
    Just cv ->
      readTVar cv >>= \case
        Just c' | sameClientId c c' -> pure Nothing
        c_ -> c_ <$ writeTVar cv (Just c)

lookupSubscribedClient :: EntityId -> SubscribedClients s -> STM (Maybe (Client s))
lookupSubscribedClient entId (SubscribedClients cs) = TM.lookup entId cs $>>= readTVar
{-# INLINE lookupSubscribedClient #-}

-- lookup and delete currently subscribed client
lookupDeleteSubscribedClient :: EntityId -> SubscribedClients s -> STM (Maybe (Client s))
lookupDeleteSubscribedClient entId (SubscribedClients cs) =
  TM.lookupDelete entId cs $>>= (`swapTVar` Nothing)
{-# INLINE lookupDeleteSubscribedClient #-}

deleteSubcribedClient :: EntityId -> Client s -> SubscribedClients s -> IO ()
deleteSubcribedClient entId c (SubscribedClients cs) =
  -- lookup of the subscribed client TVar can be in separate transaction,
  -- as long as the client is read in the same transaction -
  -- it prevents removing the next subscribed client and also avoids STM contention for the Map.
  TM.lookupIO entId cs >>= mapM_ (\cv -> atomically $ whenM (sameClient c cv) $ delete cv)
  where
    delete cv = do
      writeTVar cv Nothing
      TM.delete entId cs

sameClientId :: Client s -> (Client s) -> Bool
sameClientId c c' = clientId c == clientId c'
{-# INLINE sameClientId #-}

sameClient :: Client s -> TVar (Maybe (Client s)) -> STM Bool
sameClient c cv = maybe False (sameClientId c) <$> readTVar cv
{-# INLINE sameClient #-}

data ClientSub
  = CSClient QueueId (Maybe ServiceId) (Maybe ServiceId) -- includes previous and new associated service IDs
  | CSDeleted QueueId (Maybe ServiceId) -- includes previously associated service IDs
  | CSService ServiceId -- only send END to idividual client subs on message delivery, not of SSUB/NSSUB

newtype ProxyAgent = ProxyAgent
  { smpAgent :: SMPClientAgent 'Sender
  }

type ClientId = Int

data Client s = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId Sub,
    ntfSubscriptions :: TMap NotifierId (),
    serviceSubsCount :: TVar Int64, -- only one service can be subscribed, based on its certificate, this is subscription count
    ntfServiceSubsCount :: TVar Int64, -- only one service can be subscribed, based on its certificate, this is subscription count
    rcvQ :: TBQueue (Maybe THPeerClientService, NonEmpty (Maybe (StoreQueue s, QueueRec), Transmission Cmd)),
    sndQ :: TBQueue (NonEmpty (Transmission BrokerMsg)),
    msgQ :: TBQueue (NonEmpty (Transmission BrokerMsg)),
    procThreads :: TVar Int,
    endThreads :: TVar (IntMap (Weak ThreadId)),
    endThreadSeq :: TVar Int,
    clientTHParams :: THandleParams SMPVersion 'TServer,
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

newServer :: IO (Server s)
newServer = do
  clients <- ServerClients <$> newTVarIO mempty
  subscribers <- newServerSubscribers
  ntfSubscribers <- newServerSubscribers
  savingLock <- createLockIO
  return Server {clients, subscribers, ntfSubscribers, savingLock}

getServerClients :: Server s -> IO (IntMap (Client s))
getServerClients = readTVarIO . serverClients . clients
{-# INLINE getServerClients #-}

getServerClient :: ClientId -> Server s -> IO (Maybe (Client s))
getServerClient cId s = IM.lookup cId <$> getServerClients s
{-# INLINE getServerClient #-}

insertServerClient :: Client s -> Server s -> IO Bool
insertServerClient c@Client {clientId, connected} Server {clients} =
  atomically $
    ifM
      (readTVar connected)
      (True <$ modifyTVar' (serverClients clients) (IM.insert clientId c))
      (pure False)
{-# INLINE insertServerClient #-}

deleteServerClient :: ClientId -> Server s -> IO ()
deleteServerClient cId Server {clients} = atomically $ modifyTVar' (serverClients clients) $ IM.delete cId
{-# INLINE deleteServerClient #-}

newServerSubscribers :: IO (ServerSubscribers s)
newServerSubscribers = do
  subQ <- newTQueueIO
  queueSubscribers <- SubscribedClients <$> TM.emptyIO
  serviceSubscribers <- SubscribedClients <$> TM.emptyIO
  totalServiceSubs <- newTVarIO 0
  subClients <- newTVarIO IS.empty
  pendingEvents <- newTVarIO IM.empty
  pure ServerSubscribers {subQ, queueSubscribers, serviceSubscribers, totalServiceSubs, subClients, pendingEvents}

newClient :: ClientId -> Natural -> THandleParams SMPVersion 'TServer -> SystemTime -> IO (Client s)
newClient clientId qSize clientTHParams createdAt = do
  subscriptions <- TM.emptyIO
  ntfSubscriptions <- TM.emptyIO
  serviceSubsCount <- newTVarIO 0
  ntfServiceSubsCount <- newTVarIO 0
  rcvQ <- newTBQueueIO qSize
  sndQ <- newTBQueueIO qSize
  msgQ <- newTBQueueIO qSize
  procThreads <- newTVarIO 0
  endThreads <- newTVarIO IM.empty
  endThreadSeq <- newTVarIO 0
  connected <- newTVarIO True
  rcvActiveAt <- newTVarIO createdAt
  sndActiveAt <- newTVarIO createdAt
  return
    Client
      { clientId,
        subscriptions,
        ntfSubscriptions,
        serviceSubsCount,
        ntfServiceSubsCount,
        rcvQ,
        sndQ,
        msgQ,
        procThreads,
        endThreads,
        endThreadSeq,
        clientTHParams,
        connected,
        createdAt,
        rcvActiveAt,
        sndActiveAt
      }

newSubscription :: SubscriptionThread -> STM Sub
newSubscription st = do
  delivered <- newEmptyTMVar
  subThread <- ServerSub <$> newTVar st
  return Sub {subThread, delivered}

newProhibitedSub :: STM Sub
newProhibitedSub = do
  delivered <- newEmptyTMVar
  return Sub {subThread = ProhibitSub, delivered}

newEnv :: ServerConfig s -> IO (Env s)
newEnv config@ServerConfig {smpCredentials, httpCredentials, serverStoreCfg, smpAgentCfg, information, messageExpiration, idleQueueInterval, msgQueueQuota, maxJournalMsgCount, maxJournalStateLines} = do
  serverActive <- newTVarIO True
  server <- newServer
  msgStore_ <- case serverStoreCfg of
    SSCMemory storePaths_ -> do
      let storePath = storeMsgsFile =<< storePaths_
      ms <- newMsgStore STMStoreConfig {storePath, quota = msgQueueQuota}
      forM_ storePaths_ $ \StorePaths {storeLogFile = f} -> loadStoreLog (mkQueue ms True) f $ queueStore ms
      pure $ StoreMemory ms
    SSCMemoryJournal {storeLogFile, storeMsgsPath} -> do
      let qsCfg = MQStoreCfg
          cfg = mkJournalStoreConfig qsCfg storeMsgsPath msgQueueQuota maxJournalMsgCount maxJournalStateLines idleQueueInterval
      ms <- newMsgStore cfg
      loadStoreLog (mkQueue ms True) storeLogFile $ stmQueueStore ms
      pure $ StoreJournal ms
#if defined(dbServerPostgres)
    SSCDatabaseJournal {storeCfg, storeMsgsPath'} -> do
      let StartOptions {compactLog, confirmMigrations} = startOptions config
          qsCfg = PQStoreCfg (storeCfg {confirmMigrations} :: PostgresStoreCfg)
          cfg = mkJournalStoreConfig qsCfg storeMsgsPath' msgQueueQuota maxJournalMsgCount maxJournalStateLines idleQueueInterval
      when compactLog $ compactDbStoreLog $ dbStoreLogPath storeCfg
      ms <- newMsgStore cfg
      pure $ StoreJournal ms
#else
    SSCDatabaseJournal {} -> noPostgresExit
#endif
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
  proxyAgent <- newSMPProxyAgent smpAgentCfg random
  pure
    Env
      { serverActive,
        config,
        serverInfo,
        server,
        serverIdentity,
        msgStore_,
        ntfStore,
        random,
        tlsServerCreds,
        httpServerCreds,
        serverStats,
        sockets,
        clientSeq,
        proxyAgent
      }
  where
    loadStoreLog :: StoreQueueClass q => (RecipientId -> QueueRec -> IO q) -> FilePath -> STMQueueStore q -> IO ()
    loadStoreLog mkQ f st = do
      logNote $ "restoring queues from file " <> T.pack f
      sl <- readWriteQueueStore False mkQ f st
      setStoreLog st sl
#if defined(dbServerPostgres)
    compactDbStoreLog = \case
      Just f -> do
        logNote $ "compacting queues in file " <> T.pack f
        st <- newMsgStore STMStoreConfig {storePath = Nothing, quota = msgQueueQuota}
        -- we don't need to have locks in the map
        sl <- readWriteQueueStore False (mkQueue st False) f (queueStore st)
        setStoreLog (queueStore st) sl
        closeMsgStore st
      Nothing -> do
        logError "Error: `--compact-log` used without `db_store_log` INI option"
        exitFailure
#endif
    getCredentials protocol creds = do
      files <- missingCreds
      unless (null files) $ do
        putStrLn $ "----------\nError: no " <> protocol <> " credentials: " <> intercalate ", " files
        when (protocol == "HTTPS") $ do
          putStrLn "Server should serve static pages to show connection links in the browser."
          putStrLn letsEncrypt
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
    letsEncrypt = "Use Let's Encrypt to generate: certbot certonly --standalone -d yourdomainname --key-type rsa --rsa-key-size 4096\n----------"
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
        persistence = case serverStoreCfg of
          SSCMemory sp_ -> case sp_ of
            Nothing -> SPMMemoryOnly
            Just StorePaths {storeMsgsFile = Just _} -> SPMMessages
            _ -> SPMQueues
          _ -> SPMMessages

noPostgresExit :: IO a
noPostgresExit = do
  putStrLn "Error: server binary is compiled without support for PostgreSQL database."
  putStrLn "Please download `smp-server-postgres` or re-compile with `cabal build -fserver_postgres`."
  exitFailure

mkJournalStoreConfig :: QStoreCfg s -> FilePath -> Int -> Int -> Int -> Int64 -> JournalStoreConfig s
mkJournalStoreConfig queueStoreCfg storePath msgQueueQuota maxJournalMsgCount maxJournalStateLines idleQueueInterval =
  JournalStoreConfig
    { storePath,
      quota = msgQueueQuota,
      pathParts = journalMsgStoreDepth,
      queueStoreCfg,
      maxMsgCount = maxJournalMsgCount,
      maxStateLines = maxJournalStateLines,
      stateTailSize = defaultStateTailSize,
      idleInterval = idleQueueInterval,
      expireBackupsAfter = 14 * nominalDay,
      keepMinBackups = 2
    }

newSMPProxyAgent :: SMPClientAgentConfig -> TVar ChaChaDRG -> IO ProxyAgent
newSMPProxyAgent smpAgentCfg random = do
  smpAgent <- newSMPClientAgent SSender smpAgentCfg random
  pure ProxyAgent {smpAgent}

readWriteQueueStore :: forall q s. QueueStoreClass q s => Bool -> (RecipientId -> QueueRec -> IO q) -> FilePath -> s -> IO (StoreLog 'WriteMode)
readWriteQueueStore tty mkQ = readWriteStoreLog (readQueueStore tty mkQ) (writeQueueStore @q)
