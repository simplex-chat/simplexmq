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
    AServerStoreCfg (..),
    StorePaths (..),
    StartOptions (..),
    Env (..),
    Server (..),
    ServerSubscribers (..),
    SubscribedClients,
    ProxyAgent (..),
    Client (..),
    AClient (..),
    ClientId,
    Subscribed,
    Sub (..),
    ServerSub (..),
    SubscriptionThread (..),
    MsgStore,
    AMsgStore (..),
    AStoreType (..),
    newEnv,
    mkJournalStoreConfig,
    newClient,
    getServerClients,
    getServerClient,
    insertServerClient,
    deleteServerClient,
    getSubscribedClients,
    getSubscribedClient,
    upsertSubscribedClient,
    lookupDeleteSubscribedClient,
    deleteSubcribedClient,
    sameClientId,
    clientId',
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
import Data.ByteString.Char8 (ByteString)
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
import Simplex.Messaging.Transport (ATransport, VersionRangeSMP, VersionSMP)
import Simplex.Messaging.Transport.Server
import Simplex.Messaging.Util (ifM, whenM, ($>>=))
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (IOMode (..))
import System.Mem.Weak (Weak)
import UnliftIO.STM

data ServerConfig = ServerConfig
  { transports :: [(ServiceName, ATransport, AddHTTP)],
    smpHandshakeTimeout :: Int,
    tbqSize :: Natural,
    msgQueueQuota :: Int,
    maxJournalMsgCount :: Int,
    maxJournalStateLines :: Int,
    queueIdBytes :: Int,
    msgIdBytes :: Int,
    serverStoreCfg :: AServerStoreCfg,
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
    proxyAgent :: ProxyAgent -- senders served on this proxy
  }

type family SupportedStore (qs :: QSType) (ms :: MSType) :: Constraint where
  SupportedStore 'QSMemory 'MSMemory = ()
  SupportedStore 'QSMemory 'MSJournal = ()
  SupportedStore 'QSPostgres 'MSJournal = ()
  SupportedStore 'QSPostgres 'MSMemory =
    (Int ~ Bool, TypeError ('TE.Text "Storing messages in memory with Postgres DB is not supported"))

data AStoreType = forall qs ms. SupportedStore qs ms => ASType (SQSType qs) (SMSType ms)

data ServerStoreCfg qs ms where
  SSCMemory :: Maybe StorePaths -> ServerStoreCfg 'QSMemory 'MSMemory
  SSCMemoryJournal :: {storeLogFile :: FilePath, storeMsgsPath :: FilePath} -> ServerStoreCfg 'QSMemory 'MSJournal
  SSCDatabaseJournal :: {storeCfg :: PostgresStoreCfg, storeMsgsPath' :: FilePath} -> ServerStoreCfg 'QSPostgres 'MSJournal

data StorePaths = StorePaths {storeLogFile :: FilePath, storeMsgsFile :: Maybe FilePath}

data AServerStoreCfg = forall qs ms. SupportedStore qs ms => ASSCfg (SQSType qs) (SMSType ms) (ServerStoreCfg qs ms)

type family MsgStore (qs :: QSType) (ms :: MSType) where
  MsgStore 'QSMemory 'MSMemory = STMMsgStore
  MsgStore qs 'MSJournal = JournalMsgStore qs

data AMsgStore =
  forall qs ms. (SupportedStore qs ms, MsgStoreClass (MsgStore qs ms)) =>
  AMS (SQSType qs) (SMSType ms) (MsgStore qs ms)

type Subscribed = Bool

data Server = Server
  { clients :: ServerClients,
    subscribers :: ServerSubscribers,
    ntfSubscribers :: ServerSubscribers,
    savingLock :: Lock
  }

-- not exported, to prevent concurrent IntMap lookups inside STM transactions.
newtype ServerClients = ServerClients {serverClients :: TVar (IntMap AClient)}

data ServerSubscribers = ServerSubscribers
  { subQ :: TQueue (QueueId, ClientId, Subscribed),
    queueSubscribers :: SubscribedClients,
    subClients :: TVar IntSet,
    pendingEvents :: TVar (IntMap (NonEmpty (EntityId, BrokerMsg)))
  }

-- not exported, to prevent accidental concurrent Map lookups inside STM transactions.
-- Map stores TVars with pointers to the clients rather than client ID to allow reading the same TVar
-- inside transactions to ensure that transaction is re-evaluated in case subscriber changes.
-- Storing Maybe allows to have continuity of subscription when the same user client disconnects and re-connects -
-- any STM transaction that reads subscribed client will re-evaluate in this case.
-- The subscriptions that were made at any point are not removed -
-- this is a better trade-off with intermittently connected mobile clients.
newtype SubscribedClients = SubscribedClients (TMap EntityId (TVar (Maybe AClient)))

getSubscribedClients :: SubscribedClients -> IO (Map EntityId (TVar (Maybe AClient)))
getSubscribedClients (SubscribedClients cs) = readTVarIO cs
{-# INLINE getSubscribedClients #-}

getSubscribedClient :: EntityId -> SubscribedClients -> IO (Maybe (TVar (Maybe AClient)))
getSubscribedClient entId (SubscribedClients cs) = TM.lookupIO entId cs
{-# INLINE getSubscribedClient #-}

-- insert subscribed and current client, return previously subscribed client if it is different
upsertSubscribedClient :: EntityId -> AClient -> SubscribedClients -> STM (Maybe AClient)
upsertSubscribedClient entId ac@(AClient _ _ c) (SubscribedClients cs) =
  TM.lookup entId cs >>= \case
    Nothing -> Nothing <$ TM.insertM entId (newTVar $ Just ac) cs
    Just cv ->
      readTVar cv >>= \case
        Just c' | sameClientId c c' -> pure Nothing
        c_ -> c_ <$ writeTVar cv (Just ac)

-- insert delete subscribed client
lookupDeleteSubscribedClient :: EntityId -> SubscribedClients -> STM (Maybe AClient)
lookupDeleteSubscribedClient entId (SubscribedClients cs) = TM.lookupDelete entId cs $>>= readTVar
{-# INLINE lookupDeleteSubscribedClient #-}

deleteSubcribedClient :: EntityId -> Client s -> SubscribedClients -> IO ()
deleteSubcribedClient entId c (SubscribedClients cs) =
  -- lookup of the subscribed client TVar can be in separate transaction,
  -- as long as the client is read in the same transaction -
  -- it prevents removing the next subscribed client and also avoids STM contention for the Map.
  TM.lookupIO entId cs >>=
    mapM_ (\c' -> atomically $ whenM (maybe False (sameClientId c) <$> readTVar c') $ writeTVar c' Nothing)

sameClientId :: Client s -> AClient -> Bool
sameClientId Client {clientId} ac = clientId == clientId' ac
{-# INLINE sameClientId #-}

newtype ProxyAgent = ProxyAgent
  { smpAgent :: SMPClientAgent
  }

type ClientId = Int

data AClient = forall qs ms. MsgStoreClass (MsgStore qs ms) => AClient (SQSType qs) (SMSType ms) (Client (MsgStore qs ms))

clientId' :: AClient -> ClientId
clientId' (AClient _ _ Client {clientId}) = clientId
{-# INLINE clientId' #-}

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
  clients <- ServerClients <$> newTVarIO mempty
  subscribers <- newServerSubscribers
  ntfSubscribers <- newServerSubscribers
  savingLock <- createLockIO
  return Server {clients, subscribers, ntfSubscribers, savingLock}

getServerClients :: Server -> IO (IntMap AClient)
getServerClients = readTVarIO . serverClients . clients
{-# INLINE getServerClients #-}

getServerClient :: ClientId -> Server -> IO (Maybe AClient)
getServerClient cId s = IM.lookup cId <$> getServerClients s
{-# INLINE getServerClient #-}

insertServerClient :: AClient -> Server -> IO Bool
insertServerClient ac@(AClient _ _ Client {clientId, connected}) Server {clients} =
  atomically $
    ifM
      (readTVar connected)
      (True <$ modifyTVar' (serverClients clients) (IM.insert clientId ac))
      (pure False)
{-# INLINE insertServerClient #-}

deleteServerClient :: ClientId -> Server -> IO ()
deleteServerClient cId Server {clients} = atomically $ modifyTVar' (serverClients clients) $ IM.delete cId
{-# INLINE deleteServerClient #-}

newServerSubscribers :: IO ServerSubscribers
newServerSubscribers = do
  subQ <- newTQueueIO
  queueSubscribers <- SubscribedClients <$> TM.emptyIO
  subClients <- newTVarIO IS.empty
  pendingEvents <- newTVarIO IM.empty
  pure ServerSubscribers {subQ, queueSubscribers, subClients, pendingEvents}

newClient :: SQSType qs -> SMSType ms -> ClientId -> Natural -> VersionSMP -> ByteString -> SystemTime -> IO (Client (MsgStore qs ms))
newClient _ _ clientId qSize thVersion sessionId createdAt = do
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
  return
    Client
      { clientId,
        subscriptions,
        ntfSubscriptions,
        rcvQ,
        sndQ,
        msgQ,
        procThreads,
        endThreads,
        endThreadSeq,
        thVersion,
        sessionId,
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

newEnv :: ServerConfig -> IO Env
newEnv config@ServerConfig {smpCredentials, httpCredentials, serverStoreCfg, smpAgentCfg, information, messageExpiration, idleQueueInterval, msgQueueQuota, maxJournalMsgCount, maxJournalStateLines} = do
  serverActive <- newTVarIO True
  server <- newServer
  msgStore <- case serverStoreCfg of
    ASSCfg qt mt (SSCMemory storePaths_) -> do
      let storePath = storeMsgsFile =<< storePaths_
      ms <- newMsgStore STMStoreConfig {storePath, quota = msgQueueQuota}
      forM_ storePaths_ $ \StorePaths {storeLogFile = f} -> loadStoreLog (mkQueue ms True) f $ queueStore ms
      pure $ AMS qt mt ms
    ASSCfg qt mt SSCMemoryJournal {storeLogFile, storeMsgsPath} -> do
      let qsCfg = MQStoreCfg
          cfg = mkJournalStoreConfig qsCfg storeMsgsPath msgQueueQuota maxJournalMsgCount maxJournalStateLines idleQueueInterval
      ms <- newMsgStore cfg
      loadStoreLog (mkQueue ms True) storeLogFile $ stmQueueStore ms
      pure $ AMS qt mt ms
#if defined(dbServerPostgres)
    ASSCfg qt mt SSCDatabaseJournal {storeCfg, storeMsgsPath'} -> do
      let StartOptions {compactLog, confirmMigrations} = startOptions config
          qsCfg = PQStoreCfg (storeCfg {confirmMigrations} :: PostgresStoreCfg)
          cfg = mkJournalStoreConfig qsCfg storeMsgsPath' msgQueueQuota maxJournalMsgCount maxJournalStateLines idleQueueInterval
      when compactLog $ compactDbStoreLog $ dbStoreLogPath storeCfg
      ms <- newMsgStore cfg
      pure $ AMS qt mt ms
#else
    ASSCfg _ _ SSCDatabaseJournal {} -> noPostgresExit
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
        msgStore,
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
          ASSCfg _ _ (SSCMemory sp_) -> case sp_ of
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
  smpAgent <- newSMPClientAgent smpAgentCfg random
  pure ProxyAgent {smpAgent}

readWriteQueueStore :: forall q s. QueueStoreClass q s => Bool -> (RecipientId -> QueueRec -> IO q) -> FilePath -> s -> IO (StoreLog 'WriteMode)
readWriteQueueStore tty mkQ = readWriteStoreLog (readQueueStore tty mkQ) (writeQueueStore @q)
